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
    var close: () -> Void = {}

    enum State: Equatable { case idle, sending, done, failed(String) }

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
                            if case .failed(let m) = model.state { Text(m).foregroundStyle(.red).font(.footnote) }
                        }
                        .padding(20)
                    }
                }
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
