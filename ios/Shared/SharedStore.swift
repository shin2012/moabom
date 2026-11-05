import Foundation
import Security

/// Values shared between the app and the share extension through a keychain access group.
enum SharedStore {
    static let service = "kr.b-612.moabom"
    static let defaultServer = "https://moabom.b-612.space"

    static var accessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "SharedKeychainGroup") as? String
    }

    static var token: String? {
        get { read("token") }
        set { write("token", newValue) }
    }

    static var server: String {
        get { read("server") ?? defaultServer }
        set { write("server", newValue) }
    }

    /// Small JSON blob with categories, so the share extension can offer them offline.
    static var categoriesJSON: Data? {
        get { read("categories").flatMap { Data(base64Encoded: $0) } }
        set { write("categories", newValue?.base64EncodedString()) }
    }

    static func read(_ key: String) -> String? {
        var q = baseQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else {
            #if targetEnvironment(simulator)
            return UserDefaults.standard.string(forKey: "sim.\(key)")
            #else
            return nil
            #endif
        }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String?) {
        let q = baseQuery(key)
        SecItemDelete(q as CFDictionary)
        #if targetEnvironment(simulator)
        UserDefaults.standard.removeObject(forKey: "sim.\(key)")
        #endif
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        #if targetEnvironment(simulator)
        // Unsigned simulator builds (CI screenshots) may have no keychain entitlement.
        UserDefaults.standard.set(status == errSecSuccess ? nil : value, forKey: "sim.\(key)")
        #else
        _ = status
        #endif
    }

    private static func baseQuery(_ key: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let g = accessGroup, !g.contains("$(") { q[kSecAttrAccessGroup as String] = g }
        return q
    }
}

struct ShareCategory: Codable, Hashable, Identifiable {
    let id: Int
    let axis: Int
    let name: String
    let sort: Int
}

struct ShareCategories: Codable {
    var axes: [String]
    var items: [ShareCategory]
    var defaults: [String: Int?]
}

enum APIError: LocalizedError {
    case unauthorized
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "다시 로그인해 주세요"
        case .server(let m): return m
        case .network(let m): return m
        }
    }
}

/// Minimal request helper used by both targets.
enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func request(_ method: String, _ path: String, query: [String: String] = [:],
                        body: Any? = nil, token: String? = SharedStore.token) async throws -> Data {
        guard var comps = URLComponents(string: SharedStore.server + path) else { throw APIError.network("잘못된 서버 주소") }
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { throw APIError.network("잘못된 서버 주소") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw APIError.network("서버에 연결할 수 없습니다")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw APIError.unauthorized }
        if !(200..<300).contains(code) {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw APIError.server(detail ?? "오류가 발생했습니다 (\(code))")
        }
        return data
    }
}
