import AVFoundation
import SwiftUI

@main
struct MoabomApp: App {
    @StateObject private var store = Store.shared
    @StateObject private var lock = AppLock.shared
    @Environment(\.scenePhase) private var phase

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        if UserDefaults.standard.object(forKey: MediaCache.limitKey) == nil {
            UserDefaults.standard.set(5.0, forKey: MediaCache.limitKey)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.55, green: 0.6, blue: 1.0))
        }
        .onChange(of: phase) { _, p in
            switch p {
            case .background: lock.didEnterBackground()
            case .active:
                lock.willEnterForeground()
                Task { await store.sync() }
            default: break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var lock = AppLock.shared
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            if !store.loggedIn {
                LoginView()
            } else {
                MainTabs()
                    .task {
                        while !Task.isCancelled {
                            await store.sync()
                            try? await Task.sleep(nanoseconds: 60_000_000_000)
                        }
                    }
            }
            ToastOverlay()
            if store.loggedIn && lock.enabled && lock.locked {
                LockView().transition(.opacity)
            }
            if phase != .active && lock.enabled {
                // Hide content in the app switcher.
                Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
                    .overlay(Text("모아봄").font(.title.weight(.bold)).foregroundStyle(.secondary))
            }
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var store: Store
    @SceneStorage("tab") private var tab = "feed"

    var body: some View {
        TabView(selection: $tab) {
            Tab("둘러보기", systemImage: "play.rectangle.on.rectangle", value: "feed") { FeedView() }
            Tab("보관함", systemImage: "square.grid.3x3", value: "library") { LibraryView() }
            Tab("받기", systemImage: "arrow.down.circle", value: "downloads") { DownloadsView() }
            Tab("설정", systemImage: "gearshape", value: "settings") { SettingsView() }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
