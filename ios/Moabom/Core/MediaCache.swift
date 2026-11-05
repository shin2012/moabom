import Foundation
import UIKit

/// Disk cache for thumbnails and original files with a user-set size limit.
/// When the limit is exceeded the oldest stored files are removed first (FIFO); favorites are kept.
actor MediaCache {
    static let shared = MediaCache()

    struct Entry: Codable {
        var size: Int
        var added: Date
        var isMedia: Bool
        var mediaID: Int
    }

    private let root: URL
    private var index: [String: Entry] = [:]
    private var pinned: Set<Int> = []
    private var inflight: [String: Task<URL?, Never>] = [:]
    private let session: URLSession

    static let limitKey = "cacheLimitGB"
    static let limitOptions: [Double] = [1, 2, 5, 10, 20, 0]   // 0 = 무제한

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("moabom/cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? dir.setResourceValues(v)
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 60 * 30
        c.httpMaximumConnectionsPerHost = 6
        var loaded: [String: Entry] = [:]
        if let d = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
           let i = try? JSONDecoder().decode([String: Entry].self, from: d) {
            loaded = i
        }
        root = dir
        session = URLSession(configuration: c)
        index = loaded
    }

    private var limitBytes: Int {
        let gb = UserDefaults.standard.object(forKey: Self.limitKey) as? Double ?? 5
        return gb <= 0 ? .max : Int(gb * 1_073_741_824)
    }

    private func url(for key: String) -> URL { root.appendingPathComponent(key) }

    private var saveScheduled = false
    private func saveIndex() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.flushIndex()
        }
    }
    private func flushIndex() {
        saveScheduled = false
        if let d = try? JSONEncoder().encode(index) { try? d.write(to: root.appendingPathComponent("index.json"), options: .atomic) }
    }

    func setPinned(_ ids: Set<Int>) { pinned = ids }

    // MARK: thumbnails
    func thumbnail(id: Int, width: Int) async -> UIImage? {
        let key = "t\(id)-\(width).jpg"
        let file = url(for: key)
        if index[key] != nil, let d = try? Data(contentsOf: file), let img = UIImage(data: d) { return img }
        guard let req = API.thumbRequest(id, width: width) else { return nil }
        guard let res = try? await session.data(for: req),
              (res.1 as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: res.0) else { return nil }
        let data = res.0
        try? data.write(to: file)
        index[key] = Entry(size: data.count, added: Date(), isMedia: false, mediaID: id)
        evictIfNeeded()
        saveIndex()
        return img
    }

    // MARK: originals
    func localFile(id: Int, ext: String) -> URL? {
        let key = "m\(id).\(ext)"
        guard index[key] != nil else { return nil }
        let f = url(for: key)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// Downloads the original into the cache (deduplicated) and returns its local URL.
    @discardableResult
    func fetchOriginal(id: Int, ext: String) async -> URL? {
        let key = "m\(id).\(ext)"
        if let f = localFile(id: id, ext: ext) { return f }
        if let t = inflight[key] { return await t.value }
        let t = Task<URL?, Never> { [session] in
            guard let src = API.fileURL(id),
                  let res = try? await session.download(from: src),
                  (res.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let tmp = res.0
            let dest = self.url(for: key)
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.moveItem(at: tmp, to: dest) } catch { return nil }
            return dest
        }
        inflight[key] = t
        let result = await t.value
        inflight[key] = nil
        if let result {
            let size = (try? FileManager.default.attributesOfItem(atPath: result.path)[.size] as? Int) ?? 0
            index[key] = Entry(size: size, added: Date(), isMedia: true, mediaID: id)
            evictIfNeeded()
            saveIndex()
        }
        return result
    }

    func prefetchFavorites(_ ids: [Int]) async {
        pinned.formUnion(ids)
        for id in ids {
            guard let m = await MainActor.run(body: { Store.shared.media[id] }) else { continue }
            await fetchOriginal(id: id, ext: (m.path as NSString).pathExtension.lowercased())
        }
    }

    // MARK: housekeeping
    private func evictIfNeeded() {
        let limit = limitBytes
        var total = index.values.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        for (key, e) in index.sorted(by: { $0.value.added < $1.value.added }) {
            if total <= limit { break }
            if pinned.contains(e.mediaID) && e.isMedia { continue }
            try? FileManager.default.removeItem(at: url(for: key))
            index.removeValue(forKey: key)
            total -= e.size
        }
    }

    func applyLimitChange() {
        evictIfNeeded()
        flushIndex()
    }

    func remove(id: Int) {
        for (key, e) in index where e.mediaID == id {
            try? FileManager.default.removeItem(at: url(for: key))
            index.removeValue(forKey: key)
        }
        saveIndex()
    }

    func usage() -> (thumbs: Int, media: Int, pinned: Int) {
        var t = 0, m = 0, p = 0
        for e in index.values {
            if e.isMedia { m += e.size; if pinned.contains(e.mediaID) { p += e.size } } else { t += e.size }
        }
        return (t, m, p)
    }

    func clear(media: Bool, thumbs: Bool) {
        for (key, e) in index where (e.isMedia && media) || (!e.isMedia && thumbs) {
            try? FileManager.default.removeItem(at: url(for: key))
            index.removeValue(forKey: key)
        }
        flushIndex()
    }
}

/// In-memory layer on top of the disk cache for scrolling grids.
@MainActor
final class ImageMemory {
    static let shared = ImageMemory()
    private let cache = NSCache<NSString, UIImage>()
    init() { cache.countLimit = 600 }
    func get(_ k: String) -> UIImage? { cache.object(forKey: k as NSString) }
    func set(_ k: String, _ img: UIImage) { cache.setObject(img, forKey: k as NSString) }
}
