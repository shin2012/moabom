import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var store: Store
    @State private var filter = LibraryFilter()
    @AppStorage("gridColumns") private var columns = 3
    @State private var pinchBase = 3
    @State private var selecting = false
    @State private var selected: Set<Int> = []
    @State private var viewer: ViewerTarget?
    @State private var classifyIDs: IDList?
    @State private var confirmDelete = false
    @State private var showTriage = false
    @Environment(\.horizontalSizeClass) private var hSize

    private var items: [MediaItem] { store.items(filter) }
    private var columnCount: Int { hSize == .regular ? max(columns + 2, 4) : columns }

    var body: some View {
        NavigationStack {
            let list = items
            ScrollView {
                if !filter.isDefault { activeFilters }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount), spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, m in
                        cell(m)
                            .onTapGesture {
                                if selecting { toggle(m.id) } else { viewer = ViewerTarget(ids: list.map(\.id), index: i) }
                            }
                            .onLongPressGesture(minimumDuration: 0.35) {
                                if !selecting { selecting = true }
                                toggle(m.id)
                            }
                    }
                }
                Text(list.isEmpty ? (store.syncing ? "불러오는 중…" : "항목이 없어요") : "\(list.count)개")
                    .font(.footnote).foregroundStyle(.secondary).padding(24)
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        let next = min(7, max(2, Int((Double(pinchBase) / v.magnification).rounded())))
                        if next != columns { withAnimation(.snappy) { columns = next } }
                    }
                    .onEnded { _ in pinchBase = columns }
            )
            .refreshable { await Task { await store.sync() }.value }
            .navigationTitle(selecting ? "\(selected.count)개 선택" : "보관함")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar(list) }
            .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
            .sheet(item: $classifyIDs) { l in
                ClassifySheet(ids: l.ids) { endSelection() }.environmentObject(store)
            }
            .fullScreenCover(item: $viewer) { v in MediaViewer(ids: v.ids, index: v.index).environmentObject(store) }
            .fullScreenCover(isPresented: $showTriage) { TriageView().environmentObject(store) }
            .confirmationDialog("\(selected.count)개를 NAS에서 완전히 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("삭제", role: .destructive) {
                    let ids = Array(selected)
                    Task { if await store.delete(ids) { endSelection() } }
                }
            }
            .onAppear { pinchBase = columns }
            .task(id: store.sortedNewest.count) { debugPresent() }
        }
    }

    private func cell(_ m: MediaItem) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { ThumbView(id: m.id, width: columnCount >= 5 ? 240 : 480) }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if m.isVideo {
                    Text(Fmt.duration(m.duration).isEmpty ? "▶" : Fmt.duration(m.duration))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if m.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).padding(5) }
            }
            .overlay {
                if selecting && selected.contains(m.id) {
                    ZStack(alignment: .topTrailing) {
                        Color.accentColor.opacity(0.28)
                        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, Color.accentColor).padding(6)
                    }
                }
            }
            .contentShape(Rectangle())
    }

    private var activeFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    if filter.cats[i] != .any {
                        removable(catFilterName(filter.cats[i], axis: i + 1)) { filter.cats[i] = .any }
                    }
                }
                if let s = filter.source { removable(sourceName(s)) { filter.source = nil } }
                if let k = filter.kind { removable(k == "video" ? "영상" : "사진") { filter.kind = nil } }
                if filter.favoritesOnly { removable("즐겨찾기") { filter.favoritesOnly = false } }
                if let a = filter.account { removable("@\(a)") { filter.account = nil } }
                Button("모두 해제") { filter = LibraryFilter(sort: filter.sort) }.font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func removable(_ title: String, _ remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 4) { Text(title); Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func catFilterName(_ f: CatFilter, axis: Int) -> String {
        switch f {
        case .any: return ""
        case .unsorted: return "\(store.axes[safe: axis - 1] ?? "") 미분류"
        case .id(let id): return store.catName(id) ?? "?"
        }
    }

    private func sourceName(_ s: String) -> String { ["manual": "직접 받음", "watch": "감시", "likes": "좋아요"][s] ?? s }

    @ToolbarContentBuilder
    private func toolbar(_ list: [MediaItem]) -> some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(selected.count == list.count ? "선택 해제" : "전체 선택") {
                    selected = selected.count == list.count ? [] : Set(list.map(\.id))
                }
            }
            ToolbarItem(placement: .topBarTrailing) { Button("완료") { endSelection() } }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button { showTriage = true } label: { Label("정리", systemImage: "rectangle.stack.badge.plus") }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                filterMenu
                Button("선택") { selecting = true }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            ForEach(1...3, id: \.self) { axis in
                Picker(store.axes[safe: axis - 1] ?? "분류 \(axis)", selection: $filter.cats[axis - 1]) {
                    Text("전체").tag(CatFilter.any)
                    Text("미분류").tag(CatFilter.unsorted)
                    ForEach(store.cats(axis: axis)) { c in Text(c.name).tag(CatFilter.id(c.id)) }
                }
                .pickerStyle(.menu)
            }
            Picker("출처", selection: $filter.source) {
                Text("전체").tag(String?.none)
                Text("직접 받음").tag(String?.some("manual"))
                Text("감시").tag(String?.some("watch"))
                Text("좋아요").tag(String?.some("likes"))
            }
            .pickerStyle(.menu)
            Picker("종류", selection: $filter.kind) {
                Text("사진·영상").tag(String?.none)
                Text("영상").tag(String?.some("video"))
                Text("사진").tag(String?.some("image"))
            }
            .pickerStyle(.menu)
            Menu("계정") {
                Button("전체") { filter.account = nil }
                ForEach(store.accounts.prefix(60), id: \.name) { a in
                    Button("@\(a.name) (\(a.count))") { filter.account = a.name }
                }
            }
            Toggle("즐겨찾기만", isOn: $filter.favoritesOnly)
            Divider()
            Picker("정렬", selection: $filter.sort) {
                ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
            }
            if filter.sort == .random {
                Button("다시 섞기") { filter.seed = UInt64.random(in: 1...UInt64.max - 1) }
            }
        } label: {
            Image(systemName: filter.isDefault ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 0) {
            selButton("tag", "분류") { classifyIDs = IDList(ids: Array(selected)) }
            selButton("star", "즐겨찾기") {
                let ids = Array(selected)
                Task { for id in ids where store.media[id]?.isFavorite == false { await store.toggleFavorite(id) }; endSelection() }
            }
            selButton("trash", "삭제", role: .destructive) { confirmDelete = true }
        }
        .disabled(selected.isEmpty)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func selButton(_ icon: String, _ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) { Image(systemName: icon).font(.title3); Text(title).font(.caption2) }
                .frame(maxWidth: .infinity)
        }
    }

    private func toggle(_ id: Int) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    @State private var debugDone = false
    private func debugPresent() {
        guard !debugDone, let s = DebugRoute.screen, !store.sortedNewest.isEmpty else { return }
        debugDone = true
        let ids = store.sortedNewest.map(\.id)
        switch s {
        case "viewer": viewer = ViewerTarget(ids: ids, index: 1)
        case "viewer-video":
            if let i = store.sortedNewest.firstIndex(where: \.isVideo) { viewer = ViewerTarget(ids: ids, index: i) }
        case "classify": classifyIDs = IDList(ids: [ids[0]])
        case "triage": showTriage = true
        case "select": selecting = true; selected = Set(ids.prefix(4))
        case "filtered": filter.cats[0] = store.cats(axis: 1).first.map { .id($0.id) } ?? .any
        default: break
        }
    }

    private func endSelection() {
        selecting = false
        selected = []
    }
}
