import SwiftUI

/// Vertical, full-screen paging feed — the default "just watch" screen.
struct FeedView: View {
    @EnvironmentObject var store: Store
    @AppStorage("feedMode") private var mode = "random"
    @AppStorage("feedMuted") private var muted = true
    @State private var feedAxis1: Int? = nil
    @State private var seed = UInt64.random(in: 1...UInt64.max - 1)
    @State private var ids: [Int] = []
    @State private var current: Int?
    @State private var classifyIDs: IDList?
    @State private var viewer: ViewerTarget?

    private static let modes: [(String, String, String)] = [
        ("random", "무작위", "shuffle"), ("newest", "최신", "clock"),
        ("favorites", "즐겨찾기", "star"), ("unsorted", "미분류", "tray"),
    ]

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if ids.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.stack").font(.largeTitle).foregroundStyle(.secondary)
                    Text(store.media.isEmpty ? (store.syncing ? "불러오는 중…" : "아직 받은 항목이 없어요") : "조건에 맞는 항목이 없어요")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(ids, id: \.self) { id in
                            if let m = store.media[id] {
                                FeedPage(item: m, active: current == id, muted: $muted,
                                         onClassify: { classifyIDs = IDList(ids: [id]) },
                                         onExpand: { viewer = ViewerTarget(ids: ids, index: ids.firstIndex(of: id) ?? 0) })
                                    .containerRelativeFrame([.horizontal, .vertical])
                                    .id(id)
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
        .onAppear { if ids.isEmpty { rebuild() } }
        .onChange(of: store.sortedNewest.count) { old, new in if ids.isEmpty || old == 0 { rebuild() } }
        .onChange(of: current) { _, c in prefetch(after: c) }
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

    private func rebuild() {
        var f = LibraryFilter()
        f.sort = mode == "random" ? .random : .newest
        f.seed = seed
        f.favoritesOnly = mode == "favorites"
        if mode == "unsorted" { f.cats = [.unsorted, .unsorted, .unsorted] }
        if let a = feedAxis1 { f.cats[0] = .id(a) }
        ids = store.items(f).map(\.id)
        current = ids.first
    }

    private func prefetch(after id: Int?) {
        guard let id, let i = ids.firstIndex(of: id) else { return }
        for j in [i + 1, i + 2] {
            guard let nid = ids[safe: j], let m = store.media[nid], m.isVideo else { continue }
            let ext = (m.path as NSString).pathExtension.lowercased()
            Task.detached(priority: .utility) { await MediaCache.shared.fetchOriginal(id: nid, ext: ext) }
        }
    }
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
