import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers

@main struct HarborSSHApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var phase
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.en.rawValue
    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(red: 0.035, green: 0.06, blue: 0.10).ignoresSafeArea()
                if state.unlocked { ServerList(language: language).environmentObject(state) }
                else { LockView(language: language).environmentObject(state) }
                if phase != .active {
                    Color(red: 0.035, green: 0.06, blue: 0.10).ignoresSafeArea()
                    Image(systemName: "lock.shield.fill").font(.system(size: 60)).foregroundStyle(.mint)
                }
            }
            .preferredColorScheme(.dark).tint(.mint)
            .environment(\.locale, Locale(identifier: language))
            .onChange(of: phase) { _, value in
                if value == .background { state.lock() }
            }
        }
    }
}

struct LockView: View {
    let language: String
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "terminal.fill").font(.system(size: 78)).foregroundStyle(.mint)
            Text("Harbor SSH").font(.largeTitle.bold())
            Text(L10n.text("Your terminal. Anywhere.")).foregroundStyle(.secondary)
            Spacer()
            LanguagePicker()
            if let error = state.error { Text(L10n.text(error)).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center) }
            Button { Task { await state.unlock() } } label: {
                Label(state.authenticating ? L10n.text("Authenticating…") : L10n.text("Unlock with Face ID"), systemImage: "faceid")
                    .frame(maxWidth: .infinity).padding(10)
            }.buttonStyle(.borderedProminent).disabled(state.authenticating)
            Text(L10n.text("Protected by Face ID and iOS Keychain")).font(.footnote).foregroundStyle(.secondary)
        }.padding(32).padding(.bottom, 20)
        .task { await state.unlock() }
    }
}

struct ServerList: View {
    let language: String
    @EnvironmentObject var state: AppState
    @State private var editing: Server?
    @State private var selected: Server?
    @State private var query = ""
    var filtered: [Server] {
        state.servers.filter { query.isEmpty || "\($0.name) \($0.host) \($0.username)".localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield").font(.title).foregroundStyle(.mint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("Ready to connect")).font(.headline)
                            Text(L10n.serverCount(state.servers.count)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 12)
                }
                Section(L10n.text("Servers")) {
                    ForEach(filtered) { server in
                        Button { selected = server } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "server.rack").font(.title2).foregroundStyle(.mint)
                                    .frame(width: 48, height: 48).background(.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(server.name).font(.headline).foregroundStyle(.primary)
                                    Text("\(server.username)@\(server.host):\(server.port)")
                                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                    Label(server.useKey ? L10n.text("SSH key") : L10n.text("Password"), systemImage: server.useKey ? "key" : "lock")
                                        .font(.caption2).foregroundStyle(.mint)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
                        }
                        .swipeActions {
                            Button(L10n.text("Delete"), role: .destructive) { state.delete(server) }
                            Button(L10n.text("Edit")) { editing = server }.tint(.blue)
                        }
                        .contextMenu {
                            Button(L10n.text("Edit"), systemImage: "pencil") { editing = server }
                            Button(L10n.text("Delete"), systemImage: "trash", role: .destructive) { state.delete(server) }
                        }
                    }
                }
            }
            .overlay {
                if state.servers.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.text("Your first connection"), systemImage: "network")
                    } description: { Text(L10n.text("Add a server to open a secure SSH terminal.")) }
                    actions: { Button(L10n.text("Add server")) { editing = Server() }.buttonStyle(.borderedProminent) }
                } else if filtered.isEmpty { ContentUnavailableView(L10n.text("No servers found"), systemImage: "magnifyingglass", description: Text(L10n.text("Try another name, host or username."))) }
            }
            .searchable(text: $query, prompt: L10n.text("Name, host or username"))
            .navigationTitle("Harbor SSH")
            .toolbar {
                leadingControls
                ToolbarItem(placement: .topBarTrailing) { Button { editing = Server() } label: { Image(systemName: "plus") }.accessibilityLabel(L10n.text("Add server")) }
            }
            .sheet(item: $editing) { server in ServerEditor(language: language, server: server).environmentObject(state) }
            .fullScreenCover(item: $selected) { server in SessionScreen(server: server, state: state, language: language) }
            .alert(L10n.text("Error"), isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
                Button(L10n.text("OK")) { state.error = nil }
            } message: { Text(L10n.text(state.error ?? "")) }
        }
    }

    @ToolbarContentBuilder
    private var leadingControls: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { leadingControlsView }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { leadingControlsView }
        }
    }

    private var leadingControlsView: some View {
        HStack(spacing: 16) {
            Button { state.lock() } label: {
                Image(systemName: "lock.fill")
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Lock"))
            LanguagePicker()
        }
        .fixedSize(horizontal: true, vertical: true)
    }

}

struct ServerEditor: View {
    let language: String
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State var server: Server
    @State private var port = ""
    @State private var importing = false
    @State private var error: String?
    private var valid: Bool {
        !server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !server.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (Int(port).map { (1...65535).contains($0) } ?? false) && !server.secret.isEmpty
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("Server")) {
                    TextField(L10n.text("Name, e.g. Production"), text: $server.name)
                    TextField(L10n.text("Hostname or IP address"), text: $server.host).keyboardType(.URL)
                    TextField(L10n.text("Port"), text: $port).keyboardType(.numberPad)
                    TextField(L10n.text("Username"), text: $server.username)
                }
                Section {
                    Picker(L10n.text("Authentication"), selection: $server.useKey) {
                        Text(L10n.text("Password")).tag(false)
                        Text(L10n.text("SSH key")).tag(true)
                    }.pickerStyle(.segmented)
                    if server.useKey {
                        Button(L10n.text("Import private key"), systemImage: "square.and.arrow.down") { importing = true }
                        Text(server.secret.isEmpty ? L10n.text("No key selected") : L10n.text("Private key loaded")).font(.caption).foregroundStyle(.secondary)
                        PasteButton(payloadType: String.self) { values in
                            if let key = values.first { server.secret = key }
                        }
                        SecureField(L10n.text("Passphrase (optional)"), text: $server.passphrase)
                    } else { SecureField(L10n.text("Password"), text: $server.secret) }
                } header: { Text(L10n.text("Credentials")) }
                footer: { Text(L10n.text("Passwords and keys are stored in Keychain on this iPhone only. Supports OpenSSH Ed25519 (recommended) and RSA with ssh-rsa, including passphrases.")) }
                if let error { Section { Text(L10n.text(error)).foregroundStyle(.red) } }
                if server.pinnedKey != nil {
                    Section { Label(L10n.text("Server host key saved"), systemImage: "checkmark.shield").foregroundStyle(.mint) }
                }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle(L10n.text("SSH server")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Save")) { save() }.disabled(!valid) }
            }
            .onAppear { port = String(server.port) }
            .onChange(of: server.useKey) { _, _ in server.secret = ""; server.passphrase = "" }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    guard data.count < 128_000, let key = String(data: data, encoding: .utf8) else {
                        throw ConnectionFailure(message: L10n.text("Choose an OpenSSH private key text file smaller than 128 KB."))
                    }
                    server.secret = key
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    func save() {
        do {
            server.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            server.host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
            server.username = server.username.trimmingCharacters(in: .whitespacesAndNewlines)
            server.port = Int(port) ?? 22
            if let previous = state.servers.first(where: { $0.id == server.id }), previous.host != server.host || previous.port != server.port {
                server.pinnedKey = nil
            }
            if server.useKey { _ = try SSHSession.authentication(server) }
            try state.save(server)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct SessionScreen: View {
    let language: String
    let server: Server
    @ObservedObject var state: AppState
    @ObservedObject var session: SSHSession
    @Environment(\.dismiss) var dismiss
    init(server: Server, state: AppState, language: String) { self.language = language; self.server = server; self.state = state; self.session = state.session }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Circle().fill(session.running ? .mint : .orange).frame(width: 6, height: 6)
                    Text(session.status).font(.caption).lineLimit(3)
                    Spacer()
                }.padding(12).background(.white.opacity(0.04))
                // SwiftTerm supplies its own keyboard accessory (Esc, Ctrl, Tab, arrows).
                // A second SwiftUI row can sit underneath that accessory on iPhone.
                TerminalSurface(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }.background(Color.black)
            // UIKit owns keyboard avoidance so the accessory is included exactly once.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .navigationTitle(server.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L10n.text("Close")) { session.disconnect(); dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { LanguagePicker() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { session.connect(currentServer, store: state) } label: { Image(systemName: "arrow.clockwise") }.disabled(session.running).accessibilityLabel(L10n.text("Reconnect"))
                }
            }
            .task { session.connect(currentServer, store: state) }
            .onDisappear { session.disconnect() }
            .alert(L10n.text("Trust this server?"), isPresented: Binding(get: { session.trustRequest != nil }, set: { if !$0 { session.resolveTrust(false) } })) {
                Button(L10n.text("Cancel"), role: .cancel) { session.resolveTrust(false) }
                Button(L10n.text("Trust server")) { session.resolveTrust(true) }
            } message: { Text(session.trustRequest ?? "") }
        }
    }
    var currentServer: Server { state.servers.first(where: { $0.id == server.id }) ?? server }

}

/// Keeps the terminal's actual frame above both the keyboard and its accessory.
/// SwiftTerm derives its PTY row count from this frame, not from a clipping mask.
final class TerminalHostView: UIView {
    let terminal = TerminalView(frame: .zero)
    private var terminalBottom: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        terminalBottom = terminal.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalBottom
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let guideTop = keyboardLayoutGuide.layoutFrame.minY
        var visibleBottom = min(bounds.maxY, max(0, guideTop))
        if terminal.isFirstResponder, let accessory = terminal.inputAccessoryView,
           accessory.window != nil, !accessory.isHidden {
            // The accessory can extend above the keyboard guide on some iOS versions.
            let accessoryTop = accessory.convert(accessory.bounds, to: self).minY
            visibleBottom = min(visibleBottom, max(0, accessoryTop))
        }
        // Leave a small gap so the last glyph and caret never touch the buttons.
        let inset = min(4, visibleBottom)
        let constant = visibleBottom - inset - guideTop
        if abs(terminalBottom.constant - constant) > 0.5 {
            terminalBottom.constant = constant
            setNeedsLayout()
        }
    }
}

struct TerminalSurface: UIViewRepresentable {
    let session: SSHSession
    func makeUIView(context: Context) -> TerminalHostView {
        let host = TerminalHostView(frame: .zero)
        let terminal = host.terminal
        terminal.terminalDelegate = context.coordinator
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .init(red: 0.82, green: 0.94, blue: 0.90, alpha: 1)
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        session.terminal = terminal
        return host
    }
    func updateUIView(_ uiView: TerminalHostView, context: Context) { uiView.setNeedsLayout() }
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: SSHSession
        init(_ session: SSHSession) { self.session = session }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { @MainActor in session.send(bytes) }
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in session.resize(cols: newCols, rows: newRows) }
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
