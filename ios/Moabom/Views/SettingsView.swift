import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var lock = AppLock.shared
    @AppStorage(MediaCache.limitKey) private var limitGB: Double = 5
    @State private var usage: (thumbs: Int, media: Int, pinned: Int) = (0, 0, 0)
    @State private var settingPasscode = false
    @State private var confirmLogout = false
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section("분류") {
                    NavigationLink { CategoryManagerView() } label: {
                        Label("분류 관리", systemImage: "folder")
                    }
                    NavigationLink { StatsView() } label: {
                        Label("통계", systemImage: "chart.bar")
                    }
                }

                Section {
                    Toggle("앱 잠금", isOn: Binding(get: { lock.enabled && lock.hasPasscode }, set: { on in
                        if on { settingPasscode = true } else { lock.disable() }
                    }))
                    if lock.enabled && lock.hasPasscode {
                        if let b = lock.biometryName { Toggle("\(b) 사용", isOn: $lock.useBiometrics) }
                        Picker("잠그는 시점", selection: $lock.timeoutSeconds) {
                            ForEach(AppLock.timeoutOptions, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        Button("암호 바꾸기") { settingPasscode = true }
                    }
                } header: { Text("잠금") } footer: {
                    Text("앱을 닫거나 다른 앱으로 넘어가면 지정한 시간 뒤에 잠겨요. 앱 전환 화면에서는 내용이 가려져요.")
                }

                Section {
                    Picker("최대 용량", selection: $limitGB) {
                        ForEach(MediaCache.limitOptions, id: \.self) { v in
                            Text(v == 0 ? "제한 없음" : "\(Int(v))GB").tag(v)
                        }
                    }
                    .onChange(of: limitGB) { _, _ in Task { await MediaCache.shared.applyLimitChange(); await refreshUsage() } }
                    LabeledContent("원본 파일", value: Fmt.bytes(usage.media))
                    LabeledContent("썸네일", value: Fmt.bytes(usage.thumbs))
                    if usage.pinned > 0 { LabeledContent("즐겨찾기 보관", value: Fmt.bytes(usage.pinned)) }
                    Button("원본 파일 비우기") { Task { await MediaCache.shared.clear(media: true, thumbs: false); await refreshUsage() } }
                    Button("썸네일 비우기") { Task { await MediaCache.shared.clear(media: false, thumbs: true); await refreshUsage() } }
                } header: { Text("기기 저장 공간") } footer: {
                    Text("최대 용량을 넘으면 가장 먼저 저장된 파일부터 지워요. 즐겨찾기한 항목은 지우지 않고 기기에 보관해요.")
                }

                Section("동기화") {
                    LabeledContent("항목", value: "\(store.media.count)개")
                    LabeledContent("마지막 동기화", value: store.lastSync.map { $0.formatted(date: .omitted, time: .shortened) } ?? "-")
                    if let e = store.lastError { Text(e).font(.caption).foregroundStyle(.red) }
                    Button("지금 동기화") { Task { await store.sync() } }
                    Button("처음부터 다시 받기") { confirmReset = true }
                }

                Section("서버") {
                    LabeledContent("주소", value: SharedStore.server.replacingOccurrences(of: "https://", with: ""))
                    Button("로그아웃", role: .destructive) { confirmLogout = true }
                }

                Section {
                    LabeledContent("버전", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                }
            }
            .navigationTitle("설정")
            .task { await refreshUsage() }
            .sheet(isPresented: $settingPasscode) { PasscodeSetupView() }
            .confirmationDialog("로그아웃할까요?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("로그아웃", role: .destructive) { store.logout() }
            }
            .confirmationDialog("기기의 목록을 지우고 서버에서 다시 받을까요?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("다시 받기") { store.resetAll(); Task { await store.sync() } }
            }
        }
    }

    private func refreshUsage() async {
        await MediaCache.shared.setPinned(Set(store.media.values.filter(\.isFavorite).map(\.id)))
        usage = await MediaCache.shared.usage()
    }
}

struct PasscodeSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var first: String?
    @State private var code = ""
    @State private var message = "새 암호 6자리를 입력하세요"

    var body: some View {
        VStack(spacing: 28) {
            HStack { Button("취소") { dismiss() }; Spacer() }.padding()
            Spacer()
            Text(message).font(.headline)
            PasscodeDots(count: code.count)
            Keypad { key in
                if key == "⌫" { if !code.isEmpty { code.removeLast() }; return }
                guard code.count < 6 else { return }
                code += key
                if code.count == 6 { finish() }
            }
            Spacer()
        }
    }

    private func finish() {
        if let f = first {
            if f == code {
                AppLock.shared.setPasscode(code)
                Toast.shared.show("앱 잠금을 켰어요")
                dismiss()
            } else {
                first = nil
                code = ""
                message = "암호가 달라요. 처음부터 다시 입력하세요"
            }
        } else {
            first = code
            code = ""
            message = "한 번 더 입력하세요"
        }
    }
}

struct PasscodeDots: View {
    let count: Int
    var body: some View {
        HStack(spacing: 18) {
            ForEach(0..<6, id: \.self) { i in
                Circle().fill(i < count ? Color.primary : Color.clear)
                    .overlay(Circle().stroke(Color.primary, lineWidth: 1.5))
                    .frame(width: 14, height: 14)
            }
        }
    }
}

struct Keypad: View {
    let onKey: (String) -> Void
    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]]

    var body: some View {
        VStack(spacing: 16) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 26) {
                    ForEach(row, id: \.self) { k in
                        if k.isEmpty {
                            Color.clear.frame(width: 76, height: 76)
                        } else {
                            Button { onKey(k) } label: {
                                Group {
                                    if k == "⌫" { Image(systemName: "delete.left").font(.title2) }
                                    else { Text(k).font(.system(size: 32, weight: .regular, design: .rounded)) }
                                }
                                .frame(width: 76, height: 76)
                                .background(k == "⌫" ? Color.clear : Color.white.opacity(0.1), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .sensoryFeedback(.impact(weight: .light), trigger: k)
                        }
                    }
                }
            }
        }
    }
}
