import CryptoKit
import Foundation
import LocalAuthentication
import SwiftUI

/// App lock: own 6-digit passcode + Face ID / Touch ID.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    @Published private(set) var locked: Bool
    @AppStorage("lockEnabled") var enabled = false
    @AppStorage("lockBiometrics") var useBiometrics = true
    @AppStorage("lockTimeout") var timeoutSeconds = 0    // 0 = 즉시
    private var backgroundedAt: Date?

    static let timeoutOptions: [(Int, String)] = [(0, "즉시"), (60, "1분 후"), (300, "5분 후"), (900, "15분 후"), (3600, "1시간 후")]

    init() {
        locked = UserDefaults.standard.bool(forKey: "lockEnabled")
    }

    var hasPasscode: Bool { SharedStore.read("passcode") != nil }

    var biometryName: String? {
        let c = LAContext()
        guard c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch c.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }

    private func hash(_ code: String) -> String {
        let salt = SharedStore.read("passcodeSalt") ?? {
            let s = UUID().uuidString
            SharedStore.write("passcodeSalt", s)
            return s
        }()
        return SHA256.hash(data: Data((salt + code).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func setPasscode(_ code: String) {
        SharedStore.write("passcodeSalt", UUID().uuidString)
        SharedStore.write("passcode", hash(code))
        enabled = true
    }

    func disable() {
        enabled = false
        SharedStore.write("passcode", nil)
        locked = false
    }

    func check(_ code: String) -> Bool {
        guard let stored = SharedStore.read("passcode") else { return false }
        if hash(code) == stored { locked = false; return true }
        return false
    }

    func unlockWithBiometrics() async {
        guard enabled, useBiometrics, locked else { return }
        let c = LAContext()
        c.localizedFallbackTitle = "암호 입력"
        guard c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return }
        if (try? await c.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "모아봄 잠금 해제")) == true {
            locked = false
        }
    }

    func lockNow() { if enabled && hasPasscode { locked = true } }

    func didEnterBackground() {
        backgroundedAt = Date()
        if enabled && timeoutSeconds == 0 { locked = true }
    }

    func willEnterForeground() {
        guard enabled, hasPasscode else { locked = false; return }
        if let t = backgroundedAt, Date().timeIntervalSince(t) >= Double(timeoutSeconds) { locked = true }
    }
}

/// Remembers where each video was paused.
enum PlaybackMemory {
    private static let key = "playbackPositions"
    static func position(_ id: Int) -> Double {
        (UserDefaults.standard.dictionary(forKey: key)?[String(id)] as? Double) ?? 0
    }
    static func save(_ id: Int, _ seconds: Double, duration: Double) {
        var d = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        if seconds < 3 || (duration > 0 && seconds > duration - 3) { d.removeValue(forKey: String(id)) } else { d[String(id)] = seconds }
        if d.count > 500 { d = Dictionary(uniqueKeysWithValues: d.prefix(400).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(d, forKey: key)
    }
}
