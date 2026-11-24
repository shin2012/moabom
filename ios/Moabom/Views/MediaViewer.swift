import Photos
import SwiftUI

/// Full-screen viewer: swipe left/right between items, swipe down to close, swipe up to classify.
struct MediaViewer: View {
    let ids: [Int]
    @State var index: Int
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var chrome = true
    @State private var classifyIDs: [Int]?
    @State private var dragY: CGFloat = 0

    private var current: MediaItem? { ids[safe: index].flatMap { store.media[$0] } }
    @State private var currentID: Int?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .opacity(1 - min(0.6, abs(dragY) / 600))
            // Lazy horizontal pager: only visible pages are built (a page TabView builds every page up front,
            // which froze/crashed the app with thousands of items).
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(ids, id: \.self) { id in
                            Group {
                                if let m = store.media[id] {
                                    ViewerPage(item: m, active: id == currentID, chrome: chrome, onTap: toggleChrome)
                                } else {
                                    Text("삭제된 항목").foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .contentShape(Rectangle())
                                        .onTapGesture(perform: toggleChrome)
                                }
                            }
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentID)
                .scrollIndicators(.hidden)
                .onAppear {
                    let start = ids[safe: index]
                    currentID = start
                    if let start { proxy.scrollTo(start, anchor: .leading) }
                }
            }
            .ignoresSafeArea()
            .offset(y: max(0, dragY))
            .gesture(
                DirectionalPan(direction: .vertical,
                               onChanged: { t in dragY = t.height },
                               onEnded: { t in
                                   if t.height > 120 { dismiss() } else if t.height < -90, let m = current { classifyIDs = [m.id] }
                                   withAnimation(.spring(duration: 0.25)) { dragY = 0 }
                               })
            )

            if chrome, let m = current {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar(m)
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(!chrome)
        .persistentSystemOverlays(chrome ? .automatic : .hidden)
        .sheet(item: Binding(get: { classifyIDs.map { IDList(ids: $0) } }, set: { classifyIDs = $0?.ids })) { l in
            ClassifySheet(ids: l.ids).environmentObject(store)
        }
        .onChange(of: currentID) { _, id in
            if let id, let i = ids.firstIndex(of: id) { index = i; prefetch(around: i) }
        }
        .onAppear { prefetch(around: index) }
    }

    /// One tap anywhere on the media shows/hides every control (pages handle the tap themselves,
    /// because the image's double-tap zoom would otherwise swallow it).
    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            Text("\(index + 1) / \(ids.count)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func bottomBar(_ m: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let a = m.account { Text("@\(a)").font(.subheadline.weight(.semibold)) }
                Text(store.label(for: m)).font(.caption).foregroundStyle(.secondary)
                if let t = m.title, !t.isEmpty { Text(t).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
            }
            HStack(spacing: 0) {
                barButton("tag", "분류") { classifyIDs = [m.id] }
                barButton(m.isFavorite ? "star.fill" : "star", "즐겨찾기") { Task { await store.toggleFavorite(m.id) } }
                barButton("square.and.arrow.down", "사진에 저장") { saveToPhotos(m) }
                if let s = m.sourceUrl, let u = URL(string: s) {
                    barButton("safari", "원본") { UIApplication.shared.open(u) }
                }
                ConfirmDeleteButton(idleColor: .white, resetKey: m.id) { deleteCurrent() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private func barButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(label).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(icon == "star.fill" ? .yellow : .white)
        }
        .buttonStyle(.plain)
    }

    private func prefetch(around i: Int) {
        for j in [i + 1, i + 2] {
            guard let id = ids[safe: j], let m = store.media[id] else { continue }
            let ext = (m.path as NSString).pathExtension.lowercased()
            Task.detached(priority: .utility) { await MediaCache.shared.fetchOriginal(id: id, ext: ext) }
        }
    }

    private func deleteCurrent() {
        guard let m = current else { return }
        Task {
            if await store.delete([m.id]), store.media.isEmpty || ids.allSatisfy({ store.media[$0] == nil }) { dismiss() }
        }
    }

    private func saveToPhotos(_ m: MediaItem) {
        Task {
            let ext = (m.path as NSString).pathExtension.lowercased()
            guard let f = await MediaCache.shared.fetchOriginal(id: m.id, ext: ext) else {
                Toast.shared.show("파일을 받지 못했어요"); return
            }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { Toast.shared.show("사진 접근 권한이 필요해요"); return }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    if m.isVideo { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: f) }
                    else { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: f) }
                }
                Toast.shared.show("사진에 저장했어요")
            } catch {
                Toast.shared.show("저장하지 못했어요")
            }
        }
    }
}

struct IDList: Identifiable {
    let ids: [Int]
    var id: String { ids.map(String.init).joined(separator: ",") }
}

private struct ViewerPage: View {
    let item: MediaItem
    let active: Bool
    let chrome: Bool
    let onTap: () -> Void
    @StateObject private var player = LoopingPlayer()
    @AppStorage("viewerMuted") private var muted = false
    @State private var paused = false
    @State private var scrubbing = false
    @State private var wasPlaying = false

    var body: some View {
        Group {
            if item.isVideo {
                ZStack {
                    ThumbView(id: item.id, width: 960, contentMode: .fit)
                    // Plain layer (not AVPlayerViewController, which eats taps) so one tap toggles the UI.
                    if player.ready { PlayerLayerView(player: player.player) }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                .overlay(alignment: .bottom) {
                    if chrome && player.ready { controls.transition(.opacity) }
                }
            } else {
                ZoomableImage(item: item, onSingleTap: onTap)
            }
        }
        .task(id: active) {
            guard item.isVideo else { return }
            if active {
                await player.load(item, resume: true)
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

    /// Play/pause, timeline (drag to seek), time and mute — shown with the rest of the UI.
    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                paused.toggle()
                paused ? player.pause() : player.play()
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill").font(.title3).frame(width: 36, height: 36)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white).frame(width: max(0, geo.size.width * player.progress))
                }
                .frame(height: scrubbing ? 6 : 4)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !scrubbing { wasPlaying = !paused; player.pause(); scrubbing = true }
                            let f = min(1, max(0, v.location.x / max(1, geo.size.width)))
                            player.scrub(to: f * player.knownDuration)
                        }
                        .onEnded { _ in
                            scrubbing = false
                            if wasPlaying { player.play() }
                        }
                )
            }
            .frame(height: 32)
            Text("\(Fmt.duration(max(0.001, player.progress * player.knownDuration))) / \(Fmt.duration(player.knownDuration))")
                .font(.caption.monospacedDigit())
                .fixedSize()
            Button { muted.toggle() } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.body).frame(width: 36, height: 36)
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(.black.opacity(0.35), in: Capsule())
        .padding(.horizontal, 12)
        .padding(.bottom, 190)
    }
}
