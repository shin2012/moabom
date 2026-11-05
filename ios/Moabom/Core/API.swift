import Foundation

/// Typed wrappers around the server API.
enum API {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await HTTP.request("GET", path, query: query)
        return try decoder.decode(T.self, from: data)
    }

    @discardableResult
    static func send(_ method: String, _ path: String, body: Any? = nil) async throws -> Data {
        try await HTTP.request(method, path, body: body)
    }

    static func login(server: String, username: String, password: String, device: String) async throws -> String {
        SharedStore.server = server
        let data = try await HTTP.request("POST", "/api/auth/login",
                                          body: ["username": username, "password": password, "client": "app", "device": device],
                                          token: nil)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let t = obj["token"] as? String else {
            throw APIError.server("로그인 응답이 올바르지 않습니다")
        }
        return t
    }

    static func sync(since: Int) async throws -> SyncResponse {
        try await get("/api/sync", query: ["since": String(since), "limit": "3000"])
    }

    static func categories() async throws -> CategoriesResponse { try await get("/api/categories") }

    /// `axes` keys present = change; value nil = 미분류.
    static func classify(ids: [Int], axes: [String: Int?]) async throws -> ClassifyResponse {
        var body: [String: Any] = ["ids": ids]
        for (k, v) in axes { body[k] = v.map { $0 as Any } ?? NSNull() }
        let data = try await HTTP.request("POST", "/api/media/classify", body: body)
        return try decoder.decode(ClassifyResponse.self, from: data)
    }

    static func undo(_ entries: [UndoEntry]) async throws -> [MediaItem] {
        let undo = entries.map { e -> [String: Any] in
            ["id": e.id, "before": e.before.mapValues { $0.map { $0 as Any } ?? NSNull() }]
        }
        let data = try await HTTP.request("POST", "/api/media/undo", body: ["undo": undo])
        struct R: Decodable { let items: [MediaItem] }
        return try decoder.decode(R.self, from: data).items
    }

    static func delete(ids: [Int]) async throws { try await send("POST", "/api/media/delete", body: ["ids": ids]) }
    static func favorite(ids: [Int], value: Bool) async throws {
        try await send("POST", "/api/media/favorite", body: ["ids": ids, "value": value])
    }

    static func download(url: String, axes: [String: Int?]) async throws {
        var body: [String: Any] = ["url": url, "use_defaults": false]
        for (k, v) in axes { body[k] = v.map { $0 as Any } ?? NSNull() }
        try await send("POST", "/api/download", body: body)
    }

    static func fileURL(_ id: Int) -> URL? {
        guard let t = SharedStore.token, var c = URLComponents(string: SharedStore.server + "/api/media/\(id)/file") else { return nil }
        c.queryItems = [URLQueryItem(name: "token", value: t)]
        return c.url
    }

    static func thumbRequest(_ id: Int, width: Int) -> URLRequest? {
        guard let url = URL(string: SharedStore.server + "/api/media/\(id)/thumb?w=\(width)") else { return nil }
        var r = URLRequest(url: url)
        if let t = SharedStore.token { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return r
    }
}
