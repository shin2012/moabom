import Foundation
import SwiftUI

enum CatFilter: Hashable {
    case any, unsorted, id(Int)
    func matches(_ v: Int?) -> Bool {
        switch self {
        case .any: return true
        case .unsorted: return v == nil
        case .id(let i): return v == i
        }
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case newest, oldest, random
    var id: String { rawValue }
    var label: String { ["newest": "최신순", "oldest": "오래된순", "random": "무작위"][rawValue] ?? rawValue }
}

struct LibraryFilter: Hashable {
    var cats: [CatFilter] = [.any, .any, .any]
    var source: String? = nil      // manual / watch / likes
    var kind: String? = nil        // video / image
    var favoritesOnly = false
    var account: String? = nil
    var sort: SortOrder = .newest
    var seed: UInt64 = 1

    var isDefault: Bool { cats.allSatisfy { $0 == .any } && source == nil && kind == nil && !favoritesOnly && account == nil }
}

/// Offline-first local copy of the library. Screens render only from here; the server sends changes.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var media: [Int: MediaItem] = [:]
    @Published private(set) var categories: [CategoryItem] = []
    @Published private(set) var axes: [String] = ["분류 1", "분류 2", "분류 3"]
    @Published var defaults: [String: Int?] = [:]
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published var loggedIn: Bool = SharedStore.token != nil
    @Published private(set) var sortedNewest: [MediaItem] = []

    private(set) var rev = 0
    private var syncTask: Task<Void, Never>?

    private struct Snapshot: Codable {
        var rev: Int
        var media: [MediaItem]
        var categories: [CategoryItem]
        var axes: [String]
        var defaults: [String: Int?]
    }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("moabom")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }

    init() { load() }

    // MARK: persistence
    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        rev = s.rev
        media = Dictionary(uniqueKeysWithValues: s.media.map { ($0.id, $0) })
        categories = s.categories
        axes = s.axes
        defaults = s.defaults
        resort()
    }

    private var saveWork: DispatchWorkItem?
    private func scheduleSave() {
        saveWork?.cancel()
        let snap = Snapshot(rev: rev, media: Array(media.values), categories: categories, axes: axes, defaults: defaults)
        let w = DispatchWorkItem {
            if let d = try? JSONEncoder().encode(snap) {
                try? d.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func resort() {
        sortedNewest = media.values.sorted { a, b in a.addedAt == b.addedAt ? a.id > b.id : a.addedAt > b.addedAt }
    }

    func resetAll() {
        media = [:]; categories = []; rev = 0; sortedNewest = []
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    // MARK: sync
    func sync() async {
        if let t = syncTask { await t.value; return }
        let t = Task { await runSync() }
        syncTask = t
        await t.value
        syncTask = nil
    }

    private func runSync() async {
        guard SharedStore.token != nil else { return }
        syncing = true
        defer { syncing = false }
        do {
            var changedCats = categories.isEmpty
            while true {
                let r = try await API.sync(since: rev)
                apply(r.media)
                if !r.categories.isEmpty { changedCats = true }
                if r.axes != axes { axes = r.axes; changedCats = true }
                rev = r.rev
                if !r.hasMore { break }
            }
            if changedCats || lastSync == nil { try await refreshCategories() }
            lastSync = Date()
            lastError = nil
            scheduleSave()
            Task { await MediaCache.shared.prefetchFavorites(Array(media.values.filter(\.isFavorite).map(\.id))) }
        } catch is CancellationError {
        } catch APIError.unauthorized {
            logout()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshCategories() async throws {
        let c = try await API.categories()
        categories = c.items
        axes = c.axes
        defaults = c.defaults
        let share = ShareCategories(axes: c.axes, items: c.items.map { ShareCategory(id: $0.id, axis: $0.axis, name: $0.name, sort: $0.sort) },
                                    defaults: c.defaults)
        SharedStore.categoriesJSON = try? JSONEncoder().encode(share)
        scheduleSave()
    }

    func apply(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }
        var m = media
        for it in items {
            if it.deleted != 0 { m.removeValue(forKey: it.id); Task { await MediaCache.shared.remove(id: it.id) } }
            else { m[it.id] = it }
        }
        media = m
        resort()
        scheduleSave()
    }

    func logout() {
        Task { try? await API.send("POST", "/api/auth/logout") }
        SharedStore.token = nil
        loggedIn = false
        resetAll()
    }

    // MARK: queries
    func items(_ f: LibraryFilter) -> [MediaItem] {
        var out = sortedNewest.filter { m in
            f.cats[0].matches(m.c1) && f.cats[1].matches(m.c2) && f.cats[2].matches(m.c3)
                && (f.source == nil || m.source == f.source)
                && (f.kind == nil || m.kind == f.kind)
                && (!f.favoritesOnly || m.isFavorite)
                && (f.account == nil || m.account == f.account)
        }
        switch f.sort {
        case .newest: break
        case .oldest: out.reverse()
        case .random:
            var g = SeededRandom(seed: f.seed)
            out.shuffle(using: &g)
        }
        return out
    }

    func cats(axis: Int) -> [CategoryItem] {
        categories.filter { $0.axis == axis }.sorted { ($0.sort, $0.name) < ($1.sort, $1.name) }
    }

    func catName(_ id: Int?) -> String? {
        guard let id else { return nil }
        return categories.first { $0.id == id }?.name
    }

    func label(for m: MediaItem) -> String {
        let names = [m.c1, m.c2, m.c3].compactMap { catName($0) }
        return names.isEmpty ? "미분류" : names.joined(separator: " · ")
    }

    func count(category id: Int) -> Int {
        media.values.reduce(0) { $0 + (($1.c1 == id || $1.c2 == id || $1.c3 == id) ? 1 : 0) }
    }

    var accounts: [(name: String, count: Int)] {
        var c: [String: Int] = [:]
        for m in media.values { if let a = m.account { c[a, default: 0] += 1 } }
        return c.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    // MARK: mutations (server first, then local)
    func classify(_ ids: [Int], axes changes: [String: Int?]) async {
        do {
            let r = try await API.classify(ids: ids, axes: changes)
            apply(r.items)
            Toast.shared.show(ids.count == 1 ? "분류를 바꿨어요" : "\(r.moved)개 분류를 바꿨어요", undo: { [weak self] in
                await self?.undo(r.undo)
            })
            Task { try? await refreshCategories() }
        } catch {
            Toast.shared.show(error.localizedDescription)
        }
    }

    func undo(_ entries: [UndoEntry]) async {
        do {
            apply(try await API.undo(entries))
            Toast.shared.show("되돌렸어요")
        } catch { Toast.shared.show(error.localizedDescription) }
    }

    func delete(_ ids: [Int]) async -> Bool {
        do {
            try await API.delete(ids: ids)
            var m = media
            for id in ids { m.removeValue(forKey: id) }
            media = m
            resort()
            scheduleSave()
            for id in ids { await MediaCache.shared.remove(id: id) }
            Toast.shared.show("\(ids.count)개 삭제했어요")
            return true
        } catch {
            Toast.shared.show(error.localizedDescription)
            return false
        }
    }

    func toggleFavorite(_ id: Int) async {
        guard var m = media[id] else { return }
        let newValue = !m.isFavorite
        m.favorite = newValue ? 1 : 0
        media[id] = m
        resort()
        do {
            try await API.favorite(ids: [id], value: newValue)
            scheduleSave()
            if newValue { Task { await MediaCache.shared.prefetchFavorites([id]) } }
        } catch {
            m.favorite = newValue ? 0 : 1
            media[id] = m
            resort()
            Toast.shared.show(error.localizedDescription)
        }
    }
}

struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
