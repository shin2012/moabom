import SwiftUI

struct LockView: View {
    @ObservedObject var lock = AppLock.shared
    @State private var code = ""
    @State private var wrong = false

    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(wrong ? "암호가 맞지 않아요" : "암호를 입력하세요").font(.headline)
                .foregroundStyle(wrong ? .red : .primary)
            PasscodeDots(count: code.count)
                .offset(x: wrong ? -6 : 0)
                .animation(wrong ? .default.repeatCount(3, autoreverses: true).speed(4) : .default, value: wrong)
            Keypad { key in
                if key == "⌫" { if !code.isEmpty { code.removeLast() }; return }
                guard code.count < 6 else { return }
                wrong = false
                code += key
                if code.count == 6 {
                    if !lock.check(code) { wrong = true; code = "" }
                }
            }
            if lock.useBiometrics, let b = lock.biometryName {
                Button("\(b)로 열기") { Task { await lock.unlockWithBiometrics() } }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .task { await lock.autoPrompt() }
    }
}

struct LoginView: View {
    @EnvironmentObject var store: Store
    @State private var server = SharedStore.server
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 6) {
                        Text("모아봄").font(.largeTitle.weight(.bold))
                        Text("내 서버에 모아 둔 영상과 사진").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .listRowBackground(Color.clear)
                }
                Section("서버") {
                    TextField("https://", text: $server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                Section("계정") {
                    TextField("아이디", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("비밀번호", text: $password).textContentType(.password)
                        .onSubmit { login() }
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                Section {
                    Button { login() } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("로그인").fontWeight(.semibold) }; Spacer() }
                    }
                    .disabled(username.isEmpty || password.isEmpty || busy)
                }
            }
        }
    }

    private func login() {
        busy = true
        error = nil
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        Task {
            defer { busy = false }
            do {
                let token = try await API.login(server: s, username: username, password: password,
                                                device: "\(UIDevice.current.name) 앱")
                SharedStore.token = token
                store.loggedIn = true
                await store.sync()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
