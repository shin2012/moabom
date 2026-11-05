import SwiftUI

/// Bottom sheet with one chip row per axis. Tapping a chip applies immediately (files move on the NAS),
/// with an undo toast. For several items, axes start as "유지" (unchanged).
struct ClassifySheet: View {
    let ids: [Int]
    var onDone: (() -> Void)? = nil
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var applied: [Int: Int?] = [:]   // multi-select: what was applied per axis

    private var single: MediaItem? { ids.count == 1 ? store.media[ids[0]] : nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let m = single {
                        HStack(spacing: 12) {
                            ThumbView(id: m.id, width: 240)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(m.account.map { "@\($0)" } ?? "출처 없음").font(.subheadline.weight(.semibold))
                                Text(store.label(for: m)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(1...3, id: \.self) { axis in
                        axisRow(axis)
                    }
                    if store.categories.isEmpty {
                        Text("설정 → 분류 관리에서 분류를 먼저 만들어 주세요").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle(ids.count == 1 ? "분류" : "\(ids.count)개 분류")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss(); onDone?() }
                }
            }
            .overlay { if busy { ProgressView().controlSize(.large) } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func axisRow(_ axis: Int) -> some View {
        let key = "c\(axis)"
        let options = store.cats(axis: axis).map { (id: $0.id, name: $0.name) }
        if let m = single {
            AxisChips(title: store.axes[safe: axis - 1] ?? "분류 \(axis)", options: options, selected: m.category(axis: axis)) { pick in
                guard pick != m.category(axis: axis) else { return }
                apply([key: pick])
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.axes[safe: axis - 1] ?? "분류 \(axis)").font(.caption).foregroundStyle(.secondary)
                FlowLayout {
                    Chip(title: "미분류", selected: applied[axis] == .some(nil), dimmed: true) {
                        applied[axis] = .some(nil); apply([key: nil])
                    }
                    ForEach(options, id: \.id) { o in
                        Chip(title: o.name, selected: applied[axis] == .some(o.id)) {
                            applied[axis] = .some(o.id); apply([key: o.id])
                        }
                    }
                }
            }
        }
    }

    private func apply(_ change: [String: Int?]) {
        busy = true
        Task {
            await store.classify(ids, axes: change)
            busy = false
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
