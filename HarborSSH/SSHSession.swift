import SwiftUI
import Citadel
import Crypto
import NIOCore
import NIOSSH
import SwiftTerm

struct ConnectionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class HostValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let verify: @Sendable (String) async throws -> Void
    init(verify: @escaping @Sendable (String) async throws -> Void) { self.verify = verify }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        Task {
            do { try await verify(key); validationCompletePromise.succeed(()) }
            catch { validationCompletePromise.fail(error) }
        }
    }
}

@MainActor final class SSHSession: ObservableObject {
    @Published private var statusKey = "Disconnected"
    @Published private var statusDetail: String?
    var status: String {
        let title = L10n.text(statusKey)
        return statusDetail.map { "\(title): \(L10n.text($0))" } ?? title
    }
    @Published var running = false
    @Published private var trustDetails: String?
    var trustRequest: String? {
        trustDetails.map { "\($0)\n\n\(L10n.text("Compare this fingerprint with the server before trusting it."))" }
    }
    private var trustContinuation: CheckedContinuation<Bool, Never>?
    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var input: AsyncStream<[UInt8]>.Continuation?
    weak var terminal: TerminalView?
    private var generation = UUID()
    private var validationFailure: String?
    private var cols = 80
    private var rows = 24

    static func authentication(_ server: Server) throws -> SSHAuthenticationMethod {
        if !server.useKey { return .passwordBased(username: server.username, password: server.secret) }
        let pass = server.passphrase.isEmpty ? nil : Data(server.passphrase.utf8)
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: server.secret, decryptionKey: pass) {
            return .ed25519(username: server.username, privateKey: key)
        }
        if let key = try? Insecure.RSA.PrivateKey(sshRsa: server.secret, decryptionKey: pass) {
            return .rsa(username: server.username, privateKey: key)
        }
        throw ConnectionFailure(message: "Invalid key or passphrase. OpenSSH Ed25519 and RSA keys are supported.")
    }

    func connect(_ server: Server, store: AppState) {
        disconnect()
        let token = UUID()
        generation = token
        validationFailure = nil
        statusDetail = nil
        running = true
        statusKey = "Connecting…"
        let validator = HostValidator { [weak self, weak store] key in
            guard let self, let store else { throw CancellationError() }
            try await self.verify(key, server: server, store: store, token: token)
        }
        task = Task {
            var connected: SSHClient?
            do {
                // Parse before opening a socket so malformed keys fail immediately.
                let authentication = try Self.authentication(server)
                var settings = SSHClientSettings(host: server.host, port: server.port,
                    authenticationMethod: { authentication },
                    hostKeyValidator: .custom(validator))
                if server.useKey && server.secret.contains("OPENSSH PRIVATE KEY") {
                    settings.algorithms.publicKeyAlgorihtms = .add([(Insecure.RSA.PublicKey.self, Insecure.RSA.Signature.self)])
                }
                let connection = try await SSHClient.connect(to: settings)
                connected = connection
                guard generation == token, !Task.isCancelled else { try? await connection.close(); return }
                client = connection
                try await connection.withPTY(.init(wantReply: true, term: "xterm-256color",
                    terminalCharacterWidth: cols, terminalRowHeight: rows,
                    terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))) { inbound, outbound in
                    self.writer = outbound
                    self.statusKey = "Connected"
                    let stream = AsyncStream<[UInt8]> { self.input = $0 }
                    self.inputTask = Task {
                        do {
                            for await bytes in stream { try await outbound.write(ByteBuffer(bytes: bytes)) }
                        } catch { self.statusKey = "Error"; self.statusDetail = error.localizedDescription; self.disconnect() }
                    }
                    for try await output in inbound {
                        guard self.generation == token else { break }
                        switch output {
                        case .stdout(let buffer), .stderr(let buffer):
                            self.terminal?.feed(byteArray: Array(buffer.readableBytesView)[...])
                        }
                    }
                }
                if generation == token { statusKey = "Session ended" }
            } catch {
                if generation == token { statusKey = "Error"; statusDetail = validationFailure ?? error.localizedDescription }
            }
            if let connected { try? await connected.close() }
            if generation == token { running = false; writer = nil; input?.finish(); inputTask?.cancel(); client = nil }
        }
    }
    private func verify(_ key: String, server: Server, store: AppState, token: UUID) async throws {
        guard generation == token else { throw CancellationError() }
        if let pinned = server.pinnedKey {
            guard pinned == key else {
                let message = "The server host key has changed. Connection blocked."
                validationFailure = message
                throw ConnectionFailure(message: message)
            }
            return
        }
        let parts = key.split(separator: " ")
        let raw = parts.count > 1 ? Data(base64Encoded: String(parts[1])) ?? Data() : Data()
        let fingerprint = Data(SHA256.hash(data: raw)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        trustDetails = "\(server.host):\(server.port)\nSHA256:\(fingerprint)"
        let accepted = await withCheckedContinuation { trustContinuation = $0 }
        guard accepted, generation == token, store.unlocked else { throw CancellationError() }
        var updated = server
        updated.pinnedKey = key
        try store.save(updated)
    }
    func resolveTrust(_ accepted: Bool) {
        trustDetails = nil
        trustContinuation?.resume(returning: accepted)
        trustContinuation = nil
    }
    func send(_ bytes: [UInt8]) { input?.yield(bytes) }
    func resize(cols: Int, rows: Int) {
        self.cols = cols; self.rows = rows
        guard let writer else { return }
        Task { try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }
    func disconnect() {
        generation = UUID()
        resolveTrust(false)
        input?.finish(); input = nil
        inputTask?.cancel(); inputTask = nil
        task?.cancel(); task = nil
        if let client { Task { try? await client.close() } }
        client = nil; writer = nil; running = false
        statusKey = "Disconnected"
        statusDetail = nil
        terminal?.feed(text: "\r\n[\(L10n.text("Session closed"))]\r\n")
    }
}
