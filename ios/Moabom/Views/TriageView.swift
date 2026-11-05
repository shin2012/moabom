import SwiftUI

/// "정리 모드": unclassified items one at a time; pick chips, then 다음.
struct TriageView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var queue: [Int] = []
    @State private var position = 0
    @State private var picks: [Int: Int] = [:]
    @State private var busy = false
    @State private var done = 0
    @StateObject private var player = LoopingPlayer()

    private var current: MediaItem? { queue[safe: position].flatMap { store.media[$0] } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let m = current {
                    ZStack {
                        Color.black
                        if m.isVideo {
                            ThumbView(id: m.id, width: 960, contentMode: .fit)
                            if player.ready { PlayerLayerView(player: player.player) }
                        } else {
                            ZoomableImage(item: m)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        if let a = m.account {
                            Text("@\(a)").font(.caption.weight(.semibold)).padding(8)
                                .background(.black.opacity(0.4), in: Capsule()).padding(10)
                        }
                    }
                    .id(m.id)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(1...3, id: \.self) { axis in
                                AxisChips(title: store.axes[safe: axis - 1] ?? "분류 \(axis)",
                                          options: store.cats(axis: axis).map { (id: $0.id, name: $0.name) },
                                          selected: picks[axis], showsUnsorted: false) { pick in
                                    if let pick { picks[axis] = picks[axis] == pick ? nil : pick }
                                }
                            }
                        }
                        .padding(16)
                    }
                    .frame(maxHeight: 280)

                    HStack(spacing: 12) {
                        Button { advance() } label: {
                            Text("건너뛰기").frame(maxWidth: .infinity).padding(.vertical, 14)
                        }
                        .buttonStyle(.bordered)
                        Button { apply(m) } label: {
                            Text("적용하고 다음").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(picks.isEmpty || busy)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle").font(.system(size: 56)).foregroundStyle(.green)
                        Text(queue.isEmpty ? "정리할 항목이 없어요" : "\(done)개 정리했어요").font(.title3.weight(.semibold))
                        Button("닫기") { dismiss() }.buttonStyle(.borderedProminent).padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(queue.isEmpty ? "정리" : "정리 \(min(position + 1, queue.count)) / \(queue.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("닫기") { dismiss() } } }
        }
        .onAppear {
            var f = LibraryFilter()
            f.cats = [.unsorted, .unsorted, .unsorted]
            queue = store.items(f).map(\.id)
        }
        .task(id: current?.id) {
            player.stop()
            guard let m = current, m.isVideo else { return }
            await player.load(m, resume: false)
            player.player.isMuted = UserDefaults.standard.object(forKey: "feedMuted") as? Bool ?? true
            player.play()
        }
        .onDisappear { player.stop() }
    }

    private func advance() {
        picks = [:]
        position += 1
        if let next = queue[safe: position + 1], let m = store.media[next], m.isVideo {
            let ext = (m.path as NSString).pathExtension.lowercased()
            Task.detached(priority: .utility) { await MediaCache.shared.fetchOriginal(id: next, ext: ext) }
        }
    }

    private func apply(_ m: MediaItem) {
        var change: [String: Int?] = [:]
        for (axis, id) in picks { change["c\(axis)"] = id }
        busy = true
        Task {
            await store.classify([m.id], axes: change)
            busy = false
            done += 1
            advance()
        }
    }
}
