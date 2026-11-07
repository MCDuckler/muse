import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var app: AppModel
    @State private var server = UserDefaults.standard.string(forKey: Keys.server) ?? API.defaultServer
    @State private var user = UserDefaults.standard.string(forKey: Keys.user) ?? ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showServer = false
    @FocusState private var focus: Field?

    private enum Field { case user, password, server }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Spacer(minLength: 40)
                Wordmark(height: 40)
                Text("Sign in to your house.")
                    .font(.system(size: 17))
                    .foregroundColor(Theme.muted)
                VStack(spacing: 10) {
                    field("Name", text: $user, field: .user)
                        .textContentType(.username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("", text: $password, prompt: Text("Password").foregroundColor(Theme.faint))
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit { go() }
                        .fieldStyle()
                    if showServer {
                        field("House address", text: $server, field: .server)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                    }
                }
                if let e = error {
                    Text(e)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(action: go) {
                    HStack {
                        if busy { ProgressView().tint(Theme.ground) }
                        Text(busy ? "Signing in…" : "Sign in")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButton(filled: true))
                .disabled(busy || user.isEmpty || password.isEmpty)
                .opacity(user.isEmpty || password.isEmpty ? 0.5 : 1)
                Button(showServer ? "Hide the house address" : "Another house…") {
                    withAnimation { showServer.toggle() }
                }
                .font(.system(size: 14))
                .foregroundColor(Theme.muted)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.ground.ignoresSafeArea())
        .onAppear { focus = user.isEmpty ? .user : .password }
    }

    private func field(_ title: String, text: Binding<String>, field: Field) -> some View {
        TextField("", text: text, prompt: Text(title).foregroundColor(Theme.faint))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .focused($focus, equals: field)
            .fieldStyle()
    }

    private func go() {
        guard !busy, !user.isEmpty, !password.isEmpty else { return }
        busy = true
        error = nil
        focus = nil
        Task {
            do {
                try await app.signIn(server: server, user: user.trimmingCharacters(in: .whitespaces), password: password)
            } catch {
                self.error = APIError.from(error).message
            }
            busy = false
        }
    }
}

extension View {
    func fieldStyle() -> some View {
        self.font(.system(size: 17))
            .foregroundColor(Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.edge, lineWidth: 1))
    }
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: Offline
    @Environment(\.dismiss) private var dismiss
    @State private var coverBytes: Int64 = 0
    @State private var confirmSignOut = false
    @State private var confirmRemove = false

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    row("Signed in as", app.userName)
                    row("House", app.api.base.replacingOccurrences(of: "https://", with: ""))
                }
                Section {
                    row("Kept songs", "\(offline.files.count) · \(formatBytes(offline.totalBytes))")
                    if !offline.active.isEmpty {
                        row("Fetching now", "\(offline.active.count)")
                    }
                    if !offline.failed.isEmpty {
                        row("Couldn't fetch", "\(offline.failed.count)")
                    }
                    Toggle("Fetch on mobile data", isOn: $offline.allowCellular)
                        .tint(Theme.ok)
                    Button("Check kept playlists again") { Task { await offline.syncAll() } }
                    Button("Remove all kept songs", role: .destructive) { confirmRemove = true }
                        .disabled(offline.files.isEmpty && offline.kept.isEmpty)
                } header: {
                    Text("On this iPhone")
                } footer: {
                    Text("Kept playlists play with no signal and stay in step with the house.")
                }
                Section("Covers") {
                    row("Cached", formatBytes(coverBytes))
                    Button("Clear cached covers") {
                        ImagePipeline.shared.clear()
                        coverBytes = 0
                    }
                }
                Section {
                    Button("Send playback report") { app.sendReport(reason: "asked from settings", manual: true) }
                    row("Version", "\(Build.version) (\(Build.number))")
                } header: {
                    Text("Help")
                } footer: {
                    Text("The report is what the player did lately. It goes to the house, for working out why something stopped.")
                }
                Section {
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Sign out? Kept songs are removed from this iPhone.", isPresented: $confirmSignOut,
                                titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    dismiss()
                    app.signOut()
                }
            }
            .confirmationDialog("Remove every kept song from this iPhone?", isPresented: $confirmRemove,
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) { offline.removeAll() }
            }
            .task {
                coverBytes = await Task.detached(priority: .utility) { ImagePipeline.shared.diskBytes() }.value
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundColor(Theme.text)
            Spacer()
            Text(value)
                .foregroundColor(Theme.muted)
                .lineLimit(1)
        }
    }
}
