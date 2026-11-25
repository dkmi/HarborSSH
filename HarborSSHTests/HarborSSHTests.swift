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
    func testLongLineWrapsAtVisibleWidth() {
        for width: CGFloat in [320, 393, 852] {
            let view = TerminalView(frame: CGRect(x: 0, y: 0, width: width, height: 500))
            view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            view.layoutIfNeeded()
            let terminal = view.getTerminal()
            let columns = terminal.cols
            XCTAssertGreaterThan(columns, 1)
            view.feed(text: String(repeating: "x", count: columns - 1) + "YZ")
            XCTAssertEqual(terminal.getCharData(col: columns - 1, row: 0)?.getCharacter(), "Y")
            XCTAssertEqual(terminal.getCharData(col: 0, row: 1)?.getCharacter(), "Z")
            XCTAssertEqual(terminal.getCursorLocation().y, 1)
        }
    }
    func testPTYResynchronizesWidthChangedDuringOpeningBeforeInput() async throws {
        let previous = try Vault.read()
        defer { try? Vault.save(previous) }
        let state = AppState()
        state.unlocked = true
        let server = profile()
        state.servers = [server]
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 393, height: 500))
        state.session.terminal = terminal
        defer { state.session.disconnect() }
        state.session.connect(server, store: state)
        _ = await waitUntil { state.session.trustRequest != nil || !state.session.running }
        XCTAssertNotNil(state.session.trustRequest)
        state.session.resolveTrust(true)
        try await Task.sleep(nanoseconds: 200_000_000)
        // The fixture holds channel opening for 500 ms after the PTY size was captured.
        XCTAssertNotEqual(state.session.status, L10n.text("Connected"))
        state.session.resize(cols: 37, rows: 18)
        _ = await waitUntil { state.session.status == L10n.text("Connected") || !state.session.running }
        XCTAssertEqual(state.session.status, L10n.text("Connected"))
        state.session.send(Array("\u{1e}SIZE?\u{1f}".utf8))
        let initial = await waitUntil {
            let data: Data = terminal.getTerminal().getBufferAsData()
            return String(decoding: data, as: UTF8.self).contains("PTY_SIZE=37x18")
        }
        XCTAssertTrue(initial, "Server must use the latest viewport before receiving input")
        state.session.resize(cols: 61, rows: 20)
        state.session.resize(cols: 29, rows: 16)
        state.session.send(Array("\u{1e}SIZE?\u{1f}".utf8))
        let resized = await waitUntil {
            let data: Data = terminal.getTerminal().getBufferAsData()
            return String(decoding: data, as: UTF8.self).contains("PTY_SIZE=29x16")
        }
        XCTAssertTrue(resized, "Typing must follow the latest resize, in order")
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
