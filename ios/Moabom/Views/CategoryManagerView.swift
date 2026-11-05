import SwiftUI

/// 분류 관리: axis names, add / rename / merge / delete / reorder, default for new downloads.
/// Every change also renames or moves the folders on the NAS.
struct CategoryManagerView: View {
    @EnvironmentObject var store: Store
    @State private var axis = 1
    @State private var newName = ""
    @State private var renaming: CategoryItem?
    @State private var renameText = ""
    @State private var merging: CategoryItem?
    @State private var deleting: CategoryItem?
    @State private var editingAxisName = false
    @State private var axisNameText = ""
    @State private var busy = false

    private var cats: [CategoryItem] { store.cats(axis: axis) }

    var body: some View {
        List {
            Section {
                Picker("단계", selection: $axis) {
                    ForEach(1...3, id: \.self) { a in Text(store.axes[safe: a - 1] ?? "분류 \(a)").tag(a) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                ForEach(cats) { c in
                    HStack {
                        Text(c.name)
                        if store.defaults["c\(axis)"] == c.id {
                            Text("기본").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.25), in: Capsule())
                        }
                        Spacer()
                        Text("\(store.count(category: c.id))").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .contextMenu { menu(c) }
                    .swipeActions(edge: .trailing) {
                        Button("삭제", role: .destructive) { deleting = c }
                        Button("이름") { renameText = c.name; renaming = c }.tint(.blue)
                    }
                    .swipeActions(edge: .leading) {
                        Button("합치기") { merging = c }.tint(.orange)
                    }
                }
                .onMove(perform: move)
                HStack {
                    TextField("새 분류 이름", text: $newName).onSubmit { add() }
                    Button("추가") { add() }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                HStack {
                    Text(store.axes[safe: axis - 1] ?? "")
                    Spacer()
                    Button("단계 이름 바꾸기") { axisNameText = store.axes[safe: axis - 1] ?? ""; editingAxisName = true }
                        .font(.caption).textCase(nil)
                }
            } footer: {
                Text("이름을 바꾸거나 합치면 NAS의 폴더와 파일도 함께 옮겨져요. 길게 누르면 메뉴가 나오고, 오른쪽 위 편집으로 순서를 바꿀 수 있어요.")
            }
        }
        .navigationTitle("분류 관리")
        .toolbar { EditButton() }
        .overlay { if busy { ProgressView("NAS 폴더 정리 중…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .refreshable { try? await store.refreshCategories() }
        .alert("이름 바꾸기", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("이름", text: $renameText)
            Button("취소", role: .cancel) {}
            Button("바꾸기") { if let c = renaming { rename(c, renameText) } }
        }
        .alert("단계 이름", isPresented: $editingAxisName) {
            TextField("이름", text: $axisNameText)
            Button("취소", role: .cancel) {}
            Button("저장") { saveAxisName() }
        }
        .confirmationDialog(merging.map { "‘\($0.name)’을(를) 어디로 합칠까요?" } ?? "", isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } }), titleVisibility: .visible) {
            if let src = merging {
                ForEach(cats.filter { $0.id != src.id }) { dst in
                    Button(dst.name) { merge(src, into: dst) }
                }
            }
        }
        .confirmationDialog(deleting.map { "‘\($0.name)’ 분류를 지울까요? 파일은 지우지 않고 미분류로 옮겨요." } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("분류 삭제", role: .destructive) { if let c = deleting { remove(c) } }
        }
    }

    @ViewBuilder
    private func menu(_ c: CategoryItem) -> some View {
        Button { renameText = c.name; renaming = c } label: { Label("이름 바꾸기", systemImage: "pencil") }
        Button { merging = c } label: { Label("다른 분류와 합치기", systemImage: "arrow.triangle.merge") }
        Button { setDefault(c) } label: {
            Label(store.defaults["c\(axis)"] == c.id ? "기본값 해제" : "새로 받을 때 기본값", systemImage: "checkmark.circle")
        }
        Button(role: .destructive) { deleting = c } label: { Label("삭제", systemImage: "trash") }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
                try await store.refreshCategories()
                await store.sync()
            } catch { Toast.shared.show(error.localizedDescription) }
        }
    }

    private func add() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        run { try await API.send("POST", "/api/categories", body: ["axis": axis, "name": n]); newName = "" }
    }

    private func rename(_ c: CategoryItem, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != c.name else { return }
        run { try await API.send("PATCH", "/api/categories/\(c.id)", body: ["name": n]); Toast.shared.show("이름을 바꿨어요") }
    }

    private func merge(_ src: CategoryItem, into dst: CategoryItem) {
        run { try await API.send("POST", "/api/categories/\(src.id)/merge", body: ["into": dst.id]); Toast.shared.show("‘\(dst.name)’(으)로 합쳤어요") }
    }

    private func remove(_ c: CategoryItem) {
        run { try await API.send("DELETE", "/api/categories/\(c.id)"); Toast.shared.show("분류를 지웠어요") }
    }

    private func move(from: IndexSet, to: Int) {
        var list = cats
        list.move(fromOffsets: from, toOffset: to)
        let ids = list.map(\.id)
        run { try await API.send("POST", "/api/categories/reorder", body: ["axis": axis, "ids": ids]) }
    }

    private func setDefault(_ c: CategoryItem) {
        var d: [String: Any] = [:]
        for a in 1...3 { d["c\(a)"] = (store.defaults["c\(a)"] ?? nil).map { $0 as Any } ?? NSNull() }
        d["c\(axis)"] = store.defaults["c\(axis)"] == c.id ? NSNull() : c.id
        run { try await API.send("PUT", "/api/categories/defaults", body: d) }
    }

    private func saveAxisName() {
        var names = store.axes
        while names.count < 3 { names.append("") }
        names[axis - 1] = axisNameText.trimmingCharacters(in: .whitespaces)
        run { try await API.send("PUT", "/api/categories/axes", body: ["names": names]) }
    }
}

struct StatsView: View {
    @State private var stats: StatsResponse?
    @State private var error: String?

    var body: some View {
        List {
            if let s = stats {
                Section {
                    LabeledContent("전체", value: "\(s.totalFiles)개")
                    LabeledContent("용량", value: Fmt.bytes(s.totalSizeBytes))
                    LabeledContent("영상 / 사진", value: "\(s.videos) / \(s.images)")
                    if let d = s.disk { LabeledContent("NAS 남은 공간", value: Fmt.bytes(d.free)) }
                }
                ForEach(Array(s.byAxis.enumerated()), id: \.offset) { i, rows in
                    Section(s.axes[safe: i] ?? "") { bars(rows.map { ($0.name ?? "미분류", $0.count, $0.sizeBytes) }) }
                }
                Section("출처") {
                    bars(s.bySource.map { (["manual": "직접 받음", "watch": "감시", "likes": "좋아요"][$0.source ?? ""] ?? ($0.source ?? ""), $0.count, $0.sizeBytes) })
                }
                Section("감시 계정") { bars(s.byWatch.prefix(30).map { ("@" + ($0.name ?? ""), $0.count, $0.sizeBytes) }) }
            } else if let error {
                Text(error).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("통계")
        .task {
            do { stats = try await API.get("/api/stats") } catch { self.error = error.localizedDescription }
        }
    }

    private func bars(_ rows: [(String, Int, Int)]) -> some View {
        let maxV = max(1, rows.map(\.2).max() ?? 1)
        return ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(r.0).lineLimit(1)
                    Spacer()
                    Text("\(r.1)개 · \(Fmt.bytes(r.2))").font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader { g in
                    Capsule().fill(Color.accentColor.opacity(0.8))
                        .frame(width: max(4, g.size.width * CGFloat(r.2) / CGFloat(maxV)))
                }
                .frame(height: 5)
            }
        }
    }
}
