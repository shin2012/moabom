import SwiftUI

/// Vertical, full-screen paging feed — the default "just watch" screen.
struct FeedView: View {
    @EnvironmentObject var store: Store
    @AppStorage("feedMode") private var mode = "random"
    @AppStorage("feedMuted") private var muted = true
    @State private var feedAxis1: Int? = nil
    @State private var seed = UInt64.random(in: 1...UInt64.max - 1)
    /// Feed rows. `uid` is unique per row so the same item may come back in a later batch.
    @State private var entries: [FeedEntry] = []
    @State private var current: Int?          // uid of the visible row
    /// Full ordered list for the current mode; rows are appended from it in batches.
    @State private var pool: [Int] = []
    @State private var cursor = 0
    @State private var nextUID = 0
    @State private var loadingMore = false
    private static let batch = 40
    @State private var classifyIDs: IDList?
    @State private var viewer: ViewerTarget?

    private static let modes: [(String, String, String)] = [
        ("random", "무작위", "shuffle"), ("newest", "최신", "clock"),
        ("favorites", "즐겨찾기", "star"), ("unsorted", "미분류", "tray"),
    ]

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.stack").font(.largeTitle).foregroundStyle(.secondary)
                    Text(store.media.isEmpty ? (store.syncing ? "불러오는 중…" : "아직 받은 항목이 없어요") : "조건에 맞는 항목이 없어요")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { e in
                            if let m = store.media[e.mediaID] {
                                FeedPage(item: m, active: current == e.uid, muted: $muted,
                                         onClassify: { classifyIDs = IDList(ids: [e.mediaID]) },
                                         onExpand: { openViewer(at: e) },
                                         onDelete: { delete(e) })
                                    .containerRelativeFrame([.horizontal, .vertical])
                                    .id(e.uid)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $current)
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
            }
            header
        }
        .onAppear { if entries.isEmpty { rebuild() } }
        .onChange(of: store.sortedNewest.count) { old, new in if entries.isEmpty || old == 0 { rebuild() } }
        .onChange(of: current) { _, c in prefetch(after: c); loadMoreIfNeeded() }
        .sheet(item: $classifyIDs) { l in ClassifySheet(ids: l.ids).environmentObject(store) }
        .fullScreenCover(item: $viewer) { v in MediaViewer(ids: v.ids, index: v.index).environmentObject(store) }
    }

    private var header: some View {
        HStack {
            Menu {
                Picker("보기", selection: $mode) {
                    ForEach(Self.modes, id: \.0) { m in Label(m.1, systemImage: m.2).tag(m.0) }
                }
                Menu(store.axes.first ?? "분류 1") {
                    Button { feedAxis1 = nil; rebuild() } label: { Label("전체", systemImage: feedAxis1 == nil ? "checkmark" : "") }
                    ForEach(store.cats(axis: 1)) { c in
                        Button { feedAxis1 = c.id; rebuild() } label: { Label(c.name, systemImage: feedAxis1 == c.id ? "checkmark" : "") }
                    }
                }
                Divider()
                Button { seed = UInt64.random(in: 1...UInt64.max - 1); rebuild() } label: { Label("새로 섞기", systemImage: "arrow.triangle.2.circlepath") }
            } label: {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .onChange(of: mode) { _, _ in rebuild() }
    }

    private var title: String {
        let m = Self.modes.first { $0.0 == mode }?.1 ?? "무작위"
        if let c = store.catName(feedAxis1) { return "\(m) · \(c)" }
        return m
    }

    private var filter: LibraryFilter {
        var f = LibraryFilter()
        f.sort = mode == "random" ? .random : .newest
        f.seed = seed
        f.favoritesOnly = mode == "favorites"
        if mode == "unsorted" { f.cats = [.unsorted, .unsorted, .unsorted] }
        if let a = feedAxis1 { f.cats[0] = .id(a) }
        return f
    }

    private func rebuild() {
        pool = store.items(filter).map(\.id)
        cursor = 0
        entries = []
        appendBatch()
        current = entries.first?.uid
    }

    private func appendBatch() {
        let slice = pool[min(cursor, pool.count)..<min(cursor + Self.batch, pool.count)]
        cursor += slice.count
        entries += slice.map { id in
            nextUID += 1
            return FeedEntry(uid: nextUID, mediaID: id)
        }
    }

    /// Near the end of the loaded rows, add the next batch. When the whole list has been shown,
    /// fetch new items from the server and start the next round (random mode reshuffles).
    private func loadMoreIfNeeded() {
        guard let c = current, let i = entries.firstIndex(where: { $0.uid == c }), i >= entries.count - 5,
              !loadingMore else { return }
        if cursor < pool.count { appendBatch(); return }
        loadingMore = true
        Task {
            defer { loadingMore = false }
            await store.sync()
            if mode == "random" { seed = UInt64.random(in: 1...UInt64.max - 1) }
            let recent = Set(entries.suffix(Self.batch).map(\.mediaID))
            var next = store.items(filter).map(\.id)
            // Don't repeat what was just on screen right at the seam.
            let fresh = next.filter { !recent.contains($0) }
            if !fresh.isEmpty { next = fresh + next.filter { recent.contains($0) } }
            guard !next.isEmpty else { return }
            pool = next
            cursor = 0
            appendBatch()
        }
    }

    private func openViewer(at e: FeedEntry) {
        // Viewer needs unique ids: the loaded rows without repeats, in feed order.
        var seen = Set<Int>()
        let list = entries.map(\.mediaID).filter { seen.insert($0).inserted }
        viewer = ViewerTarget(ids: list, index: list.firstIndex(of: e.mediaID) ?? 0)
    }

    private func delete(_ e: FeedEntry) {
        Task {
            guard await store.delete([e.mediaID]) else { return }
            // Move to the following row, then drop every row of that item.
            if let i = entries.firstIndex(where: { $0.uid == e.uid }) {
                let after = entries[(i + 1)...].first { $0.mediaID != e.mediaID }
                    ?? entries[..<i].last { $0.mediaID != e.mediaID }
                entries.removeAll { $0.mediaID == e.mediaID }
                pool.removeAll { $0 == e.mediaID }
                cursor = min(cursor, pool.count)
                current = after?.uid
                loadMoreIfNeeded()
            }
        }
    }

    private func prefetch(after uid: Int?) {
        guard let uid, let i = entries.firstIndex(where: { $0.uid == uid }) else { return }
        for j in [i + 1, i + 2] {
            guard let nid = entries[safe: j]?.mediaID, let m = store.media[nid], m.isVideo else { continue }
            let ext = (m.path as NSString).pathExtension.lowercased()
            Task.detached(priority: .utility) { await MediaCache.shared.fetchOriginal(id: nid, ext: ext) }
        }
    }
}

struct FeedEntry: Identifiable, Hashable {
    let uid: Int
    let mediaID: Int
    var id: Int { uid }
}

struct ViewerTarget: Identifiable {
    let ids: [Int]
    let index: Int
    var id: String { "\(index)-\(ids.count)" }
}

private struct FeedPage: View {
    let item: MediaItem
    let active: Bool
    @Binding var muted: Bool
    let onClassify: () -> Void
    let onExpand: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject var store: Store
    @StateObject private var player = LoopingPlayer()
    @State private var paused = false
    // scrubbing
    @State private var scrubbing = false
    @State private var scrubStart: Double = 0
    @State private var wasPlaying = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if item.isVideo {
                GeometryReader { geo in
                    ZStack {
                        ThumbView(id: item.id, width: 960, contentMode: .fit)
                        if player.ready { PlayerLayerView(player: player.player) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        paused.toggle()
                        paused ? player.pause() : player.play()
                    }
                    // Drag sideways anywhere on the video to skim back and forth (vertical drags still page the feed).
                    .gesture(
                        DirectionalPan(direction: .horizontal,
                                       onBegan: { beginScrub(at: player.currentSeconds) },
                                       onChanged: { t in
                                           guard player.ready else { return }
                                           let d = player.knownDuration
                                           // Whole clip across one screen width (capped at 3 minutes per width for long videos).
                                           let secondsPerPoint = min(d, 180) / max(1, geo.size.width)
                                           player.scrub(to: scrubStart + Double(t.width) * secondsPerPoint)
                                       },
                                       onEnded: { _ in endScrub() })
                    )
                    .overlay {
                        if paused && !scrubbing {
                            Image(systemName: "play.fill").font(.system(size: 54)).foregroundStyle(.white.opacity(0.85))
                                .allowsHitTesting(false)
                        }
                    }
                }
            } else {
                ZoomableImage(item: item)
            }
            if item.isVideo && scrubbing {
                VStack {
                    Text("\(Fmt.duration(max(0.001, player.progress * player.knownDuration))) / \(Fmt.duration(player.knownDuration))")
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(.top, 120)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    if let a = item.account { Text("@\(a)").font(.subheadline.weight(.semibold)) }
                    Text(store.label(for: item)).font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                .shadow(radius: 4)
                Spacer()
                VStack(spacing: 18) {
                    sideButton(item.isFavorite ? "star.fill" : "star", tint: item.isFavorite ? .yellow : .white) {
                        Task { await store.toggleFavorite(item.id) }
                    }
                    sideButton("tag") { onClassify() }
                    if item.isVideo {
                        sideButton(muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { muted.toggle() }
                    }
                    sideButton("arrow.up.left.and.arrow.down.right") { onExpand() }
                    ConfirmDeleteCircle(resetKey: item.id) { onDelete() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, item.isVideo ? 124 : 100)
            .opacity(scrubbing ? 0 : 1)
            if item.isVideo && player.ready { timeline }
        }
        .task(id: active) {
            guard item.isVideo else { return }
            if active {
                await player.load(item, resume: false)
                player.observeProgress()
                player.player.isMuted = muted
                paused = false
                player.play()
            } else {
                player.pause()
            }
        }
        .onChange(of: muted) { _, m in player.player.isMuted = m }
        .onDisappear { player.stop() }
    }

    /// Thin timeline above the tab bar; drag on it to jump to an exact spot (absolute skimming).
    private var timeline: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: max(0, geo.size.width * player.progress))
            }
            .frame(height: scrubbing ? 6 : 3)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !scrubbing { beginScrub(at: player.currentSeconds) }
                        let f = min(1, max(0, v.location.x / max(1, geo.size.width)))
                        player.scrub(to: f * player.knownDuration)
                    }
                    .onEnded { _ in endScrub() }
            )
        }
        .frame(height: 28)
        .padding(.horizontal, 12)
        .padding(.bottom, 86)
        .animation(.easeOut(duration: 0.15), value: scrubbing)
    }

    private func beginScrub(at seconds: Double) {
        wasPlaying = !paused
        scrubStart = seconds
        player.pause()
        withAnimation(.easeOut(duration: 0.15)) { scrubbing = true }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func endScrub() {
        withAnimation(.easeOut(duration: 0.2)) { scrubbing = false }
        if wasPlaying { player.play() }
    }

    private func sideButton(_ icon: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
