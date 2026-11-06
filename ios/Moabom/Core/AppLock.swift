import CryptoKit
import Foundation
import LocalAuthentication
import SwiftUI
import UIKit

/// App lock: own 6-digit passcode + Face ID / Touch ID.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    @Published private(set) var locked: Bool
    /// False while the app is in the background; players pause and mute on the way out.
    @Published private(set) var inForeground = true
    @AppStorage("lockEnabled") var enabled = false
    @AppStorage("lockBiometrics") var useBiometrics = true
    @AppStorage("lockTimeout") var timeoutSeconds = 0    // 0 = 즉시
    /// Set only by a real trip to the background; cleared on return so inactive→active
    /// transitions (Face ID sheet, Control Center, notification shade) never re-lock.
    private var backgroundedAt: Date?
    private var authenticating = false
    /// Offer Face ID automatically once per launch / return from background (not after a cancel).
    private var autoPromptPending: Bool

    static let timeoutOptions: [(Int, String)] = [(0, "즉시"), (60, "1분 후"), (300, "5분 후"), (900, "15분 후"), (3600, "1시간 후")]

    init() {
        let on = UserDefaults.standard.bool(forKey: "lockEnabled")
        locked = on
        autoPromptPending = on
    }

    /// Video may make sound / play only when unlocked and on screen.
    var playbackAllowed: Bool { !locked && inForeground }

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
        guard enabled, useBiometrics, locked, !authenticating,
              UIApplication.shared.applicationState == .active else { return }
        authenticating = true
        defer { authenticating = false }
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
        inForeground = false
        // Sound always starts off when the user comes back.
        UserDefaults.standard.set(true, forKey: "feedMuted")
        if enabled && timeoutSeconds == 0 { locked = true }
    }

    /// Called on every scenePhase == .active, which also fires after inactive-only interruptions.
    func willEnterForeground() {
        let returning = backgroundedAt
        backgroundedAt = nil
        if !enabled || !hasPasscode {
            locked = false
        } else if let t = returning {
            if Date().timeIntervalSince(t) >= Double(timeoutSeconds) { locked = true }
            if locked { autoPromptPending = true }
        }
        inForeground = true
        Task { await autoPrompt() }
    }

    /// Face ID once per launch/return; a cancelled prompt is not re-shown (button stays available).
    func autoPrompt() async {
        guard locked, autoPromptPending, UIApplication.shared.applicationState == .active else { return }
        autoPromptPending = false
        await unlockWithBiometrics()
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
