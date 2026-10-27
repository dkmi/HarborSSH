# Harbor SSH for iPhone

[English](README.md) · [Български](README.bg.md)

A native SwiftUI SSH client for iOS 17+ with English and Bulgarian interfaces. **English is the default**, regardless of the iPhone's language.

## Features

- Add, edit, delete and search saved servers.
- Configure the host, username and SSH port.
- Authenticate using a password or an OpenSSH private key: Ed25519 / RSA, with or without a passphrase.
- Import a key from Files or paste it using the system Paste button.
- Interactive xterm-256color terminal with PTY, resizing and SwiftTerm's keyboard accessory: Esc, Ctrl, Tab and arrow keys. Use Ctrl + C to interrupt a command.
- Face ID required at launch and after entering the background. No PIN fallback.
- Hide the interface while the app is inactive and close the SSH connection when locked.
- Store server profiles and secrets in iOS Keychain using `WhenUnlockedThisDeviceOnly`; no iCloud synchronization.
- Confirm a SHA-256 fingerprint on the first connection and pin the server's public host key. A changed key blocks the connection.
- Original 1024×1024 app icon in the AppIcon asset catalog.
- Switch between **EN / BG** from the lock screen, the server list toolbar or the terminal toolbar. The choice takes effect immediately and is saved on this device.

## Language selection

The first launch uses English. Select **BG** for Bulgarian or **EN** for English. Switching languages does not disconnect an active session or change stored credentials. The preference persists across app restarts and background locking.

Application labels, connection statuses, app-generated errors and host-key confirmation text follow the selected language. Remote terminal output is displayed as received. iOS-owned permission dialogs, Face ID system messages and the Files picker may follow the device's language settings.

## Open and run

1. Open `HarborSSH.xcodeproj` in Xcode 26 or later.
2. Wait for Swift Package Manager to download the dependencies.
3. In Signing & Capabilities, choose your Apple Development Team and change the Bundle Identifier if needed.
4. Select an iPhone with Face ID enrolled and press Run.

For Simulator, enable Features → Face ID → Enrolled. Use Matching Face when prompted. Real Face ID must be verified on a physical iPhone.

If Xcode reports a missing Metal Toolchain, install it from Xcode Settings → Components or run `xcodebuild -downloadComponent MetalToolchain`.

The project is ready for development signing. Installing on a physical device or distributing it requires signing with your Apple account. A signed IPA is not included.

On the first connection, compare the displayed fingerprint with the one provided by the server administrator or console. After a legitimate host-key replacement, delete the profile and create it again. Editing the host or port requires confirming trust again.

Citadel's RSA authentication uses `ssh-rsa` (SHA-1); servers allowing only RSA-SHA2 will reject it. Use an Ed25519 key for modern servers. Legacy transport ciphers are not enabled.

## Verification

Tests cover Keychain round trips, encrypted Ed25519 and RSA key parsing, incorrect passphrases, interactive PTY connections with passwords and keys, rejecting trust, changed host keys and disconnecting when the app locks. Language tests cover the English default, saving the preference and the bundled English/Bulgarian translations. A keyboard regression test checks that the prompt stays above the accessory after 200 output lines and that the terminal expands again when the keyboard closes.

Integration tests use a local Python SSH endpoint that echoes bytes and does not execute commands. `HarborSSHTests/Fixtures` contains generated test keys only; never use them on a real server.

```sh
python3 -m venv .test-venv
.test-venv/bin/pip install 'paramiko>=3.5,<4'
.test-venv/bin/python HarborSSHTests/ssh_fixture.py
```

In another terminal, with an iPhone Simulator available:

```sh
GITHUB_ACTIONS=true xcodebuild test \
  -project HarborSSH.xcodeproj -scheme HarborSSH \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGN_IDENTITY=-
```

`GITHUB_ACTIONS=true` excludes unused benchmark dependencies from SwiftTerm 1.13.0. It is not required when opening the project normally in Xcode.

`project.yml` supports regeneration with XcodeGen. The generated `.xcodeproj` is included; XcodeGen is not required to run the app.

## Dependencies

- [Citadel](https://github.com/orlandos-nl/Citadel): SSH transport, authentication and PTY.
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm): terminal emulator, version 1.13.0.

Direct dependencies are pinned to specific Git revisions; `Package.resolved` pins transitive versions. Library licenses are available in their respective repositories.
