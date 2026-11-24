import SwiftUI
import UIKit
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel()
        model.close = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load(from: extensionContext) }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    @Published var url: String = ""
    @Published var cats: ShareCategories?
    @Published var picks: [Int: Int?] = [:]
    @Published var state: State = .idle
    @Published var watchState: WatchState = .idle
    /// Set right after an account is newly added → asks whether to fetch its whole video history.
    @Published var askBackfill: String?
    var close: () -> Void = {}

    enum State: Equatable { case idle, sending, done, failed(String) }
    enum WatchState: Equatable { case idle, sending, added(String), already(String), backfilling(String), failed(String) }

    /// X account behind the shared link (x.com/<name>/status/... or a profile link).
    var account: String? {
        guard let u = URL(string: url), let host = u.host?.lowercased(),
              ["x.com", "twitter.com", "www.x.com", "www.twitter.com", "mobile.twitter.com", "mobile.x.com"].contains(host)
        else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard let first = parts.first,
              first.range(of: "^[A-Za-z0-9_]{1,15}$", options: .regularExpression) != nil,
              !["i", "home", "search", "explore", "notifications", "messages", "settings", "intent", "share", "hashtag"]
                .contains(first.lowercased())
        else { return nil }
        return first
    }

    func addWatch() {
        guard let name = account else { return }
        watchState = .sending
        Task {
            do {
                let data = try await HTTP.request("POST", "/api/watch", body: ["username": name, "from_now": true])
                let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                let stored = obj["username"] as? String ?? name
                if obj["already"] as? Bool ?? false {
                    watchState = .already(stored)
                } else {
                    watchState = .added(stored)
                    askBackfill = stored
                }
            } catch {
                watchState = .failed(error.localizedDescription)
            }
        }
    }

    func startBackfill(_ name: String) {
        Task {
            do {
                _ = try await HTTP.request("POST", "/api/watch/\(name)/all", body: ["videos_only": true])
                watchState = .backfilling(name)
            } catch {
                watchState = .failed(error.localizedDescription)
            }
        }
    }

    var loggedIn: Bool { SharedStore.token != nil }

    func load(from ctx: NSExtensionContext?) async {
        if let d = SharedStore.categoriesJSON, let c = try? JSONDecoder().decode(ShareCategories.self, from: d) {
            cats = c
            for a in 1...3 { picks[a] = c.defaults["c\(a)"] ?? nil }
        }
        let providers = (ctx?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let u = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                url = u.absoluteString
                return
            }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let s = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               let found = s.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("http") }) {
                url = String(found)
                return
            }
        }
    }

    func send() {
        state = .sending
        Task {
            var body: [String: Any] = ["url": url, "use_defaults": false]
            for a in 1...3 { body["c\(a)"] = (picks[a] ?? nil).map { $0 as Any } ?? NSNull() }
            do {
                _ = try await HTTP.request("POST", "/api/download", body: body)
                state = .done
                try? await Task.sleep(nanoseconds: 700_000_000)
                close()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            Group {
                if !model.loggedIn {
                    Text("모아봄 앱에서 먼저 로그인해 주세요").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(model.url.isEmpty ? "링크를 찾지 못했어요" : model.url)
                                .font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                            if let c = model.cats {
                                ForEach(1...3, id: \.self) { axis in
                                    AxisChips(title: axis <= c.axes.count ? c.axes[axis - 1] : "분류 \(axis)",
                                              options: c.items.filter { $0.axis == axis }.sorted { $0.sort < $1.sort }.map { (id: $0.id, name: $0.name) },
                                              selected: model.picks[axis] ?? nil) { model.picks[axis] = $0 }
                                }
                            }
                            if let name = model.account { WatchRow(name: name, state: model.watchState) { model.addWatch() } }
                            if case .failed(let m) = model.state { Text(m).foregroundStyle(.red).font(.footnote) }
                        }
                        .padding(20)
                    }
                }
            }
            .alert("영상 전체 받기", isPresented: Binding(get: { model.askBackfill != nil },
                                                      set: { if !$0 { model.askBackfill = nil } })) {
                Button("취소", role: .cancel) { model.askBackfill = nil }
                Button("확인") {
                    if let n = model.askBackfill { model.startBackfill(n) }
                    model.askBackfill = nil
                }
            } message: {
                Text("@\(model.askBackfill ?? "")의 지금까지 올라온 영상을 모두 받을까요? 이미 받은 게시물은 건너뛰어요.")
            }
            .navigationTitle("모아봄에 받기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { model.close() } }
                ToolbarItem(placement: .confirmationAction) {
                    switch model.state {
                    case .sending: ProgressView()
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    default:
                        Button("받기") { model.send() }.fontWeight(.semibold)
                            .disabled(model.url.isEmpty || !model.loggedIn)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// "Add this account to auto-watch" option shown under the category chips.
struct WatchRow: View {
    let name: String
    let state: ShareModel.WatchState
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("자동감시").font(.subheadline.weight(.semibold))
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: icon).foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state == .sending { ProgressView() }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
        }
    }

    private var disabled: Bool {
        switch state {
        case .sending, .added, .already, .backfilling: return true
        default: return false
        }
    }
    private var icon: String {
        switch state {
        case .added, .already, .backfilling: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        default: return "eye.circle"
        }
    }
    private var tint: Color {
        switch state {
        case .added, .already, .backfilling: return .green
        case .failed: return .red
        default: return .accentColor
        }
    }
    private var title: String {
        switch state {
        case .added(let n), .backfilling(let n): return "@\(n) 자동감시에 추가됨"
        case .already(let n): return "@\(n) 이미 자동감시 중"
        default: return "@\(name) 자동감시에 추가"
        }
    }
    private var subtitle: String {
        switch state {
        case .failed(let m): return m
        case .backfilling: return "지금까지 올라온 영상도 전부 받는 중이에요"
        case .added, .already: return "새 게시물을 자동으로 받아요"
        default: return "이 계정의 새 게시물을 앞으로 자동으로 받아요"
        }
    }
}
