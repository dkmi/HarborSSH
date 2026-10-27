"""Local-only test SSH endpoint. No commands are executed. Requires paramiko.
Run this process before xcodebuild test. Credentials are disposable fixtures.
"""
import socket
import threading
from pathlib import Path
import paramiko

ROOT = Path(__file__).parent / 'Fixtures'
KEYS = [paramiko.Ed25519Key.from_private_key_file(str(ROOT / 'ed25519'), password='test-passphrase'),
        paramiko.RSAKey.from_private_key_file(str(ROOT / 'rsa'))]
HOST_KEY = KEYS[0]

class Server(paramiko.ServerInterface):
    def get_allowed_auths(self, username): return 'password,publickey'
    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if username == 'tester' and password == 'test-only' else paramiko.AUTH_FAILED
    def check_auth_publickey(self, username, key):
        return paramiko.AUTH_SUCCESSFUL if username == 'tester' and any(key == k for k in KEYS) else paramiko.AUTH_FAILED
    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_pty_request(self, *args): return True
    def check_channel_shell_request(self, channel): return True
    def check_channel_window_change_request(self, *args): return True

def serve(connection):
    transport = paramiko.Transport(connection)
    try:
        transport.add_server_key(HOST_KEY)
        transport.start_server(server=Server())
        channel = transport.accept(30)
        if channel:
            channel.send(b'Harbor test SSH endpoint\r\n$ ')
            while data := channel.recv(4096): channel.send(data)
    except (EOFError, OSError, paramiko.SSHException): pass
    finally: transport.close()

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(('127.0.0.1', 22222))
listener.listen()
print('Test SSH listening on 127.0.0.1:22222', flush=True)
while True:
    connection, _ = listener.accept()
    threading.Thread(target=serve, args=(connection,), daemon=True).start()
