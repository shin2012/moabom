import Foundation

/// Launch-argument hooks used only by the CI screenshot workflow (Debug builds).
/// e.g. `-demoServer http://127.0.0.1:8977 -demoUser demo -demoPass x -screen library`
enum DebugRoute {
    static var screen: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "screen")
        #else
        return nil
        #endif
    }

    @MainActor
    static func prepare() async {
        #if DEBUG
        let d = UserDefaults.standard
        if let s = d.string(forKey: "demoServer"), let u = d.string(forKey: "demoUser"), let p = d.string(forKey: "demoPass"),
           SharedStore.token == nil || SharedStore.server != s {
            if let t = try? await API.login(server: s, username: u, password: p, device: "CI 시뮬레이터") {
                SharedStore.token = t
                Store.shared.loggedIn = true
            }
        }
        if screen == "lock" && !AppLock.shared.hasPasscode {
            AppLock.shared.setPasscode("123456")
        }
        if screen == "lock" { AppLock.shared.lockNow() }
        if Store.shared.loggedIn { await Store.shared.sync() }
        #endif
    }
}
