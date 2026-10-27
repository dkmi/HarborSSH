# Disposable SSH test keys

These keys were generated exclusively for Harbor SSH automated tests. They do not provide access to any production server and are intentionally public. Never install their public keys on a real server.

- `ed25519`: encrypted OpenSSH key, test passphrase `test-passphrase`.
- `rsa`: unencrypted OpenSSH RSA test key.

The local fixture server listens on loopback only and echoes input without executing commands.
