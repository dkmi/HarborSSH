import XCTest
import UIKit
import SwiftTerm
@testable import HarborSSH

@MainActor final class HarborSSHTests: XCTestCase {
    func testLanguagePreferenceDefaultsToEnglishAndPersists() {
        let suite = "HarborSSHTests.language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppLanguage.current(in: defaults), .en)
        defaults.set("bg", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.current(in: UserDefaults(suiteName: suite)!), .bg)
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.current(in: defaults), .en)
        defaults.set("unsupported", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.current(in: defaults), .en)
    }
    func testBundledTranslationsForBothLanguages() {
        XCTAssertEqual(L10n.text("Unlock with Face ID", language: .en), "Unlock with Face ID")
        XCTAssertEqual(L10n.text("Unlock with Face ID", language: .bg), "Отключи с Face ID")
        XCTAssertEqual(L10n.text("Connected", language: .en), "Connected")
        XCTAssertEqual(L10n.text("Connected", language: .bg), "Свързан")
        XCTAssertEqual(L10n.text("Trust this server?", language: .bg), "Доверявате ли се на сървъра?")
    }
    func testTerminalPromptStaysAboveKeyboardAccessoryAfterLongOutput() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        let host = TerminalHostView(frame: window.bounds)
        host.terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        controller.view = host
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            host.terminal.resignFirstResponder()
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        host.layoutIfNeeded()
        host.terminal.layoutIfNeeded()
        let fullHeightRows = host.terminal.getTerminal().rows
        XCTAssertTrue(host.terminal.becomeFirstResponder())
        let keyboardShown = await waitUntil {
            host.layoutIfNeeded()
            return host.terminal.inputAccessoryView?.window != nil &&
                host.keyboardLayoutGuide.layoutFrame.minY < host.bounds.height - 100
        }
        XCTAssertTrue(keyboardShown, "Software keyboard and accessory must be visible")
        host.setNeedsLayout()
        host.layoutIfNeeded()
        host.layoutIfNeeded()
        host.terminal.layoutIfNeeded()
        for index in 0..<200 { host.terminal.feed(text: "output line \(index)\r\n") }
        host.terminal.feed(text: "test@server:~$ ")
        host.terminal.layoutIfNeeded()
        let accessory = try XCTUnwrap(host.terminal.inputAccessoryView)
        let accessoryTop = accessory.convert(accessory.bounds, to: host).minY
        XCTAssertLessThanOrEqual(host.terminal.frame.maxY, accessoryTop - 3)
        XCTAssertLessThan(host.terminal.getTerminal().rows, fullHeightRows)
        let cursor = host.terminal.getTerminal().getCursorLocation()
        XCTAssertLessThan(cursor.y, host.terminal.getTerminal().rows)
        XCTAssertGreaterThanOrEqual(cursor.y, 0)
        host.terminal.resignFirstResponder()
        let expanded = await waitUntil {
            host.layoutIfNeeded()
            host.terminal.layoutIfNeeded()
            return host.terminal.getTerminal().rows >= fullHeightRows
        }
        XCTAssertTrue(expanded, "Terminal should expand again when the keyboard closes")
    }
    func fixture(_ name: String) throws -> String {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") ?? bundle.url(forResource: name, withExtension: nil)!
        return try String(contentsOf: url, encoding: .utf8)
    }
    func profile(key: String? = nil, passphrase: String = "") -> Server {
        Server(name: "Local integration test", host: "127.0.0.1", port: 22222,
               username: "tester", useKey: key != nil, secret: key ?? "test-only", passphrase: passphrase)
    }
    func testInvalidKeyAndWrongPassphraseFail() throws {
        XCTAssertThrowsError(try SSHSession.authentication(profile(key: "invalid")))
        XCTAssertThrowsError(try SSHSession.authentication(profile(key: fixture("ed25519"), passphrase: "wrong")))
        XCTAssertNoThrow(try SSHSession.authentication(profile(key: fixture("ed25519"), passphrase: "test-passphrase")))
        XCTAssertNoThrow(try SSHSession.authentication(profile(key: fixture("rsa"))))
    }
    func testKeychainRoundTrip() throws {
        let previous = try Vault.read()
        defer { try? Vault.save(previous) }
        let server = profile()
        try Vault.save([server])
        XCTAssertEqual(try Vault.read(), [server])
        try Vault.save([])
        XCTAssertEqual(try Vault.read(), [])
    }
    func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return predicate()
    }
    func checkConnection(_ server: Server) async throws {
        let previous = try Vault.read()
        defer { try? Vault.save(previous) }
        let state = AppState()
        state.unlocked = true
        state.servers = [server]
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let session = state.session
        session.terminal = terminal
        defer { session.disconnect() }
        session.connect(server, store: state)
        let prompted = await waitUntil { session.trustRequest != nil || !session.running }
        XCTAssertTrue(prompted)
        XCTAssertNotNil(session.trustRequest, session.status)
        session.resolveTrust(true)
        let connected = await waitUntil { session.status == L10n.text("Connected") || !session.running }
        XCTAssertTrue(connected)
        XCTAssertEqual(session.status, L10n.text("Connected"))
        XCTAssertNotNil(state.servers.first?.pinnedKey)
        session.send(Array("echo integration-ok\r".utf8))
        let echoed = await waitUntil {
            let data: Data = terminal.getTerminal().getBufferAsData()
            return String(decoding: data, as: UTF8.self).contains("integration-ok")
        }
        XCTAssertTrue(echoed, "Interactive PTY did not echo input")
        state.lock()
        XCTAssertFalse(state.unlocked)
        XCTAssertFalse(session.running)
        XCTAssertTrue(state.servers.isEmpty)
    }
    func testPasswordPTYAndBackgroundLock() async throws { try await checkConnection(profile()) }
    func testEncryptedEd25519PTY() async throws { try await checkConnection(profile(key: fixture("ed25519"), passphrase: "test-passphrase")) }
    func testRSAPTY() async throws { try await checkConnection(profile(key: fixture("rsa"))) }
    func testChangedHostKeyIsBlocked() async {
        let state = AppState()
        state.unlocked = true
        var server = profile()
        server.pinnedKey = "different-host-key"
        state.session.connect(server, store: state)
        let finished = await waitUntil { !state.session.running }
        XCTAssertTrue(finished)
        XCTAssertTrue(state.session.status.contains(L10n.text("The server host key has changed. Connection blocked.")), state.session.status)
        XCTAssertNil(state.session.trustRequest)
        state.session.disconnect()
    }
    func testUntrustedHostCanBeRejected() async {
        let state = AppState()
        state.unlocked = true
        state.session.connect(profile(), store: state)
        _ = await waitUntil { state.session.trustRequest != nil || !state.session.running }
        XCTAssertNotNil(state.session.trustRequest)
        state.session.resolveTrust(false)
        _ = await waitUntil { !state.session.running }
        XCTAssertNotEqual(state.session.status, L10n.text("Connected"))
        XCTAssertTrue(state.servers.isEmpty)
        state.session.disconnect()
    }
}
