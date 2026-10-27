import Foundation
import Security
import LocalAuthentication
import SwiftUI

struct Server: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var host = ""
    var port = 22
    var username = ""
    var useKey = false
    var secret = ""
    var passphrase = ""
    var pinnedKey: String?
}

enum Vault {
    static let service = "com.harbor.ssh.vault"
    static func read() throws -> [Server] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "servers",
            kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return try JSONDecoder().decode([Server].self, from: data)
    }
    static func save(_ servers: [Server]) throws {
        let data = try JSONEncoder().encode(servers)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "servers"]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw failure(status) }
        } else if update != errSecSuccess { throw failure(update) }
    }
    static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey:
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"])
    }
}

@MainActor final class AppState: ObservableObject {
    @Published var unlocked = false
    @Published var authenticating = false
    @Published var servers: [Server] = []
    @Published var error: String?
    let session = SSHSession()
    private var context: LAContext?
    private var generation = 0

    func unlock() async {
        guard !authenticating, !unlocked else { return }
        authenticating = true
        let ticket = generation
        let context = LAContext()
        self.context = context
        context.localizedFallbackTitle = ""
        defer { authenticating = false; self.context = nil }
        var failure: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &failure), context.biometryType == .faceID else {
            error = "An iPhone with Face ID enrolled is required. Enable Face ID in Settings."
            return
        }
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: L10n.text("Unlock Harbor SSH"))
            guard success, ticket == generation else { return }
            servers = try Vault.read()
            unlocked = true
            error = nil
        } catch { if ticket == generation { self.error = error.localizedDescription } }
    }
    func lock() {
        generation += 1
        context?.invalidate()
        session.disconnect()
        unlocked = false
        servers = []
    }
    func save(_ server: Server) throws {
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == server.id }) { updated[index] = server }
        else { updated.append(server) }
        try Vault.save(updated)
        servers = updated
    }
    func delete(_ server: Server) {
        do {
            let updated = servers.filter { $0.id != server.id }
            try Vault.save(updated)
            servers = updated
        } catch { self.error = error.localizedDescription }
    }
}
