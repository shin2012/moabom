import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject var store: Store
    @State private var url = ""
    @State private var picks: [Int: Int?] = [:]
    @State private var downloads: [DownloadItem] = []
    @State private var watched: [WatchedAccount] = []
    @State private var likes: LikesStatus?
    @State private var newAccount = ""
    @State private var sending = false
    @State private var section = 0

    var body: some View {
        NavigationStack {
            List {
                Picker("", selection: $section) {
                    Text("링크로 받기").tag(0)
                    Text("자동 감시").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if section == 0 { downloadSections } else { watchSections }
            }
            .navigationTitle("받기")
            .refreshable { await Task { await reload() }.value }
            .task { await poll() }
            .onAppear { applyDefaults(); if DebugRoute.screen == "watch" { section = 1 } }
        }
    }

    // MARK: 받기
    @ViewBuilder
    private var downloadSections: some View {
        Section {
            HStack {
                TextField("링크 붙여넣기", text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { submit() }
                if url.isEmpty {
                    Button { if let s = UIPasteboard.general.string { url = s } } label: { Image(systemName: "doc.on.clipboard") }
                } else {
                    Button { url = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            ForEach(1...3, id: \.self) { axis in
                AxisChips(title: store.axes[safe: axis - 1] ?? "분류 \(axis)",
                          options: store.cats(axis: axis).map { (id: $0.id, name: $0.name) },
                          selected: picks[axis] ?? nil) { picks[axis] = $0 }
                    .padding(.vertical, 4)
            }
            Button {
                submit()
            } label: {
                HStack { Spacer(); if sending { ProgressView() } else { Text("받기").fontWeight(.semibold) }; Spacer() }
            }
            .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || sending)
        } footer: {
            Text("X 게시물 링크는 사진·영상을 모두 받아요. 다른 앱의 공유 메뉴에서 ‘모아봄’을 눌러도 돼요.")
        }

        Section("최근") {
            if downloads.isEmpty { Text("기록이 없어요").foregroundStyle(.secondary) }
            ForEach(downloads.prefix(80)) { d in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(d.title?.isEmpty == false ? d.title! : d.url).lineLimit(1).font(.subheadline)
                        Spacer()
                        Text(d.statusLabel).font(.caption.weight(.semibold))
                            .foregroundStyle(d.status == "failed" ? .red : d.status == "completed" ? .green : .secondary)
                    }
                    HStack(spacing: 6) {
                        if let u = d.username { Text("@\(u)") }
                        if d.watchedBy != nil { Text("· 감시") }
                        Text("· \(Fmt.date(d.createdAt))")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if d.status == "downloading" { ProgressView(value: (d.progress ?? 0) / 100) }
                    if let e = d.error, d.status == "failed" { Text(e).font(.caption2).foregroundStyle(.red).lineLimit(2) }
                }
                .swipeActions {
                    if d.status == "failed" || d.status == "cancelled" {
                        Button("다시") { act(d.id, "retry") }.tint(.blue)
                    }
                    if d.status == "queued" || d.status == "downloading" {
                        Button("취소", role: .destructive) { act(d.id, "cancel") }
                    }
                }
            }
        }
    }

    // MARK: 감시
    @ViewBuilder
    private var watchSections: some View {
        Section {
            HStack {
                TextField("X 계정 추가 (@이름)", text: $newAccount)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { addAccount() }
                Button("추가") { addAccount() }.disabled(newAccount.isEmpty)
            }
        } footer: { Text("추가한 계정의 새 게시물을 15분마다 확인해서 받아요.") }

        if let l = likes {
            Section("좋아요") {
                Toggle(isOn: Binding(get: { l.enabled }, set: { _ in toggleLikes() })) {
                    VStack(alignment: .leading) {
                        Text("내 좋아요 받기")
                        Text(l.xUsername.map { "@\($0)" } ?? "웹 설정에서 X 계정 이름을 입력하세요").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }

        Section("감시 중 \(watched.count)") {
            ForEach(watched) { w in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("@\(w.username)").font(.subheadline.weight(.semibold))
                            statusBadge(w.accountStatus)
                        }
                        Text("\(w.mediaCount ?? 0)개 · 마지막 \(Fmt.date(w.lastDownloadAt).isEmpty ? "-" : Fmt.date(w.lastDownloadAt))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { run(w.username) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                }
                .swipeActions {
                    Button("삭제", role: .destructive) { removeAccount(w.username) }
                }
            }
        }
    }

    private func statusBadge(_ s: String?) -> some View {
        let (t, c): (String, Color) = switch s {
        case "active": ("정상", .green)
        case "suspended": ("정지됨", .red)
        case "not_found", "unavailable": ("이용 불가", .orange)
        default: ("", .secondary)
        }
        return Text(t).font(.caption2.weight(.semibold)).foregroundStyle(c)
    }

    // MARK: actions
    private func applyDefaults() {
        guard picks.isEmpty else { return }
        for a in 1...3 { picks[a] = store.defaults["c\(a)"] ?? nil }
    }

    private func submit() {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        sending = true
        Task {
            defer { sending = false }
            do {
                var axes: [String: Int?] = [:]
                for a in 1...3 { axes["c\(a)"] = picks[a] ?? nil }
                try await API.download(url: u, axes: axes)
                url = ""
                Toast.shared.show("대기열에 넣었어요")
                await reload()
            } catch { Toast.shared.show(error.localizedDescription) }
        }
    }

    private func act(_ id: Int, _ action: String) {
        Task {
            do { try await API.send("POST", "/api/download/\(id)/\(action)"); await reload() }
            catch { Toast.shared.show(error.localizedDescription) }
        }
    }

    private func addAccount() {
        let n = newAccount.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        Task {
            do { try await API.send("POST", "/api/watch", body: ["username": n]); newAccount = ""; await reload() }
            catch { Toast.shared.show(error.localizedDescription) }
        }
    }

    private func removeAccount(_ u: String) {
        Task {
            try? await API.send("DELETE", "/api/watch/\(u)")
            await reload()
        }
    }

    private func run(_ u: String) {
        Toast.shared.show("@\(u) 확인 중…")
        Task {
            do {
                let d = try await API.send("POST", "/api/watch/\(u)/run")
                let n = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["new_downloads"] as? Int ?? 0
                Toast.shared.show("새 항목 \(n)개")
                await reload()
            } catch { Toast.shared.show(error.localizedDescription) }
        }
    }

    private func toggleLikes() {
        Task {
            do { try await API.send("POST", "/api/likes/watch"); await reload() }
            catch { Toast.shared.show(error.localizedDescription) }
        }
    }

    private func reload() async {
        if let d: DownloadsResponse = try? await API.get("/api/downloads", query: ["limit": "100"]) { downloads = d.downloads }
        if section == 1 || watched.isEmpty {
            if let w: WatchResponse = try? await API.get("/api/watch") { watched = w.watched }
            likes = try? await API.get("/api/likes/status")
        }
    }

    /// Refresh while the screen is visible; faster when something is downloading.
    private func poll() async {
        var lastActive = 0
        while !Task.isCancelled {
            await reload()
            let active = downloads.filter { $0.status == "queued" || $0.status == "downloading" }.count
            if active < lastActive { await store.sync() }
            lastActive = active
            try? await Task.sleep(nanoseconds: active > 0 ? 2_000_000_000 : 15_000_000_000)
        }
    }
}
