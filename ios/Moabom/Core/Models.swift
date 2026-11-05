import Foundation
import CoreGraphics

struct MediaItem: Codable, Identifiable, Hashable {
    let id: Int
    var path: String
    var thumb: String?
    var kind: String
    var size: Int
    var width: Int?
    var height: Int?
    var duration: Double?
    var c1: Int?
    var c2: Int?
    var c3: Int?
    var source: String
    var owner: String?
    var watchedBy: String?
    var title: String?
    var sourceUrl: String?
    var uploadedAt: String?
    var addedAt: String
    var favorite: Int
    var rev: Int
    var deleted: Int

    var isVideo: Bool { kind == "video" }
    var isFavorite: Bool { favorite != 0 }
    var account: String? { watchedBy ?? owner }
    var aspect: CGFloat {
        guard let w = width, let h = height, w > 0, h > 0 else { return 1 }
        return CGFloat(w) / CGFloat(h)
    }
    func category(axis: Int) -> Int? { axis == 1 ? c1 : axis == 2 ? c2 : c3 }
    var isUnsorted: Bool { c1 == nil && c2 == nil && c3 == nil }
}

struct CategoryItem: Codable, Identifiable, Hashable {
    let id: Int
    var axis: Int
    var name: String
    var sort: Int
    var deleted: Int?
    var count: Int?
}

struct SyncResponse: Decodable {
    let rev: Int
    let hasMore: Bool
    let media: [MediaItem]
    let categories: [CategoryItem]
    let axes: [String]
}

struct CategoriesResponse: Decodable {
    let axes: [String]
    let items: [CategoryItem]
    let defaults: [String: Int?]
}

struct ClassifyResponse: Decodable {
    let moved: Int
    let undo: [UndoEntry]
    let items: [MediaItem]
}

struct UndoEntry: Codable {
    let id: Int
    let before: [String: Int?]
}

struct DownloadItem: Decodable, Identifiable, Hashable {
    let id: Int
    let url: String
    var username: String?
    var title: String?
    var status: String
    var progress: Double?
    var error: String?
    var createdAt: String?
    var watchedBy: String?

    var statusLabel: String {
        ["queued": "대기", "downloading": "받는 중", "completed": "완료", "failed": "실패", "cancelled": "취소"][status] ?? status
    }
}

struct DownloadsResponse: Decodable {
    let downloads: [DownloadItem]
    let active: Int
}

struct WatchedAccount: Decodable, Identifiable, Hashable {
    var id: String { username }
    let username: String
    let lastChecked: String?
    let accountStatus: String?
    let mediaCount: Int?
    let lastDownloadAt: String?
}

struct WatchResponse: Decodable { let watched: [WatchedAccount] }

struct LikesStatus: Decodable {
    let enabled: Bool
    let lastChecked: String?
    let xUsername: String?
}

struct StatsRow: Decodable, Hashable {
    let name: String?
    let source: String?
    let count: Int
    let sizeBytes: Int
}

struct StatsResponse: Decodable {
    let totalFiles: Int
    let totalSizeBytes: Int
    let videos: Int
    let images: Int
    let axes: [String]
    let byAxis: [[StatsRow]]
    let bySource: [StatsRow]
    let byWatch: [StatsRow]
    let disk: Disk?
    struct Disk: Decodable { let total: Int; let free: Int }
}

struct DeviceRow: Decodable, Identifiable, Hashable {
    let id: String
    let kind: String
    let name: String?
    let lastUsed: String?
}

enum Fmt {
    static func bytes(_ b: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
    static func duration(_ s: Double?) -> String {
        guard let s, s > 0 else { return "" }
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
    static func date(_ iso: String?) -> String {
        guard let iso, let d = parse(iso) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "M월 d일 HH:mm" : "yyyy년 M월 d일"
        return f.string(from: d)
    }
    static func parse(_ iso: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: iso) { return d }
        }
        return nil
    }
}
