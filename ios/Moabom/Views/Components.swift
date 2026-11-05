import AVKit
import SwiftUI

/// Cached thumbnail.
struct ThumbView: View {
    let id: Int
    var width = 480
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(white: 0.12)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            }
        }
        .task(id: id) {
            let key = "\(id)-\(width)"
            if let m = ImageMemory.shared.get(key) { image = m; return }
            image = nil
            if let img = await MediaCache.shared.thumbnail(id: id, width: width) {
                ImageMemory.shared.set(key, img)
                image = img
            }
        }
    }
}

/// Full-size image from cache or server, with pinch zoom.
struct ZoomableImage: View {
    let item: MediaItem
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            ThumbView(id: item.id, width: 960, contentMode: .fit)
                .opacity(image == nil ? 1 : 0)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .scaleEffect(scale)
        .offset(offset)
        .gesture(
            MagnifyGesture()
                .onChanged { v in scale = max(1, min(6, lastScale * v.magnification)) }
                .onEnded { _ in
                    lastScale = scale
                    if scale <= 1.01 { withAnimation { offset = .zero; lastOffset = .zero; scale = 1; lastScale = 1 } }
                }
        )
        // Pan only while zoomed in, so it never steals swipes from the surrounding pager/feed.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height)
                }
                .onEnded { _ in lastOffset = offset },
            isEnabled: scale > 1
        )
        .onTapGesture(count: 2) {
            withAnimation(.spring) {
                if scale > 1 { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5; lastScale = 2.5 }
            }
        }
        .task(id: item.id) {
            let ext = (item.path as NSString).pathExtension.lowercased()
            if let f = await MediaCache.shared.fetchOriginal(id: item.id, ext: ext), let img = UIImage(contentsOfFile: f.path) {
                image = img
            }
        }
    }
}

/// Source URL for playback: local cached file if present, otherwise stream (and cache in background).
func playbackURL(for item: MediaItem) async -> URL? {
    let ext = (item.path as NSString).pathExtension.lowercased()
    if let local = await MediaCache.shared.localFile(id: item.id, ext: ext) { return local }
    Task.detached(priority: .utility) { await MediaCache.shared.fetchOriginal(id: item.id, ext: ext) }
    return API.fileURL(item.id)
}

/// Lightweight looping player layer for the feed.
final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ v: PlayerUIView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = gravity
    }
}

/// System player (scrubbing, PiP, AirPlay) for the detail viewer.
struct SystemPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.videoGravity = .resizeAspect
        vc.view.backgroundColor = .black
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}

/// Owns an AVPlayer for one media item, loops, and remembers the position.
@MainActor
final class LoopingPlayer: ObservableObject {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var itemID: Int?
    private var duration: Double = 0
    @Published var ready = false

    func load(_ item: MediaItem, resume: Bool) async {
        guard itemID != item.id else { return }
        itemID = item.id
        ready = false
        duration = item.duration ?? 0
        guard let url = await playbackURL(for: item), itemID == item.id else { return }
        let pi = AVPlayerItem(url: url)
        pi.preferredForwardBufferDuration = 4
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: pi)
        if resume {
            let pos = PlaybackMemory.position(item.id)
            if pos > 0 { await player.seek(to: CMTime(seconds: pos, preferredTimescale: 600)) }
        }
        ready = true
    }

    func play() { player.play() }

    // MARK: scrubbing (Final Cut–style skimming: drag distance maps to time)
    @Published var progress: Double = 0          // 0...1, updated while playing
    private var timeObserver: Any?
    private var seekInFlight = false
    private var pendingSeek: Double?

    var knownDuration: Double {
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite && d > 0 ? d : duration
    }

    var currentSeconds: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    func observeProgress() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.pendingSeek == nil, !self.seekInFlight else { return }
                let d = self.knownDuration
                if d > 0 { self.progress = min(1, max(0, t.seconds / d)) }
            }
        }
    }

    /// Frame-accurate seek that never queues more than one request (chase-seek), so dragging stays smooth.
    func scrub(to seconds: Double) {
        let d = knownDuration
        let target = d > 0 ? min(max(0, seconds), d - 0.05) : max(0, seconds)
        if d > 0 { progress = target / d }
        pendingSeek = target
        guard !seekInFlight else { return }
        runPendingSeek()
    }

    private func runPendingSeek() {
        guard let s = pendingSeek else { return }
        pendingSeek = nil
        seekInFlight = true
        player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                if self.pendingSeek != nil { self.runPendingSeek() }
            }
        }
    }

    func pause() {
        player.pause()
        if let id = itemID {
            PlaybackMemory.save(id, player.currentTime().seconds, duration: duration)
        }
    }

    func stop() {
        pause()
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        player.removeAllItems()
        looper = nil
        itemID = nil
        progress = 0
    }
}
