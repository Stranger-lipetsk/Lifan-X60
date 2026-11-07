#!/usr/bin/env python3
"""Read exactly one synthetic fixture using ADB sync, in isolated CI netns.

No arbitrary host, port, path, shell command or device can be selected. Caller
enters a verified Docker --network=none namespace. This is not a device client.
"""
import socket
import struct
import sys

PORT = 43127
PATH = b'/lab/root-only-synthetic.txt'
EXPECTED = b'X60 isolated synthetic root-only fixture\n'


def exact(sock, length):
    out = b''
    while len(out) < length:
        part = sock.recv(length - len(out))
        if not part: raise OSError('connection closed')
        out += part
    return out


def send(sock, command, a0, a1, payload=b''):
    code = int.from_bytes(command, 'little')
    sock.sendall(struct.pack('<6I', code, a0, a1, len(payload), sum(payload), code ^ 0xffffffff) + payload)


def receive(sock):
    cmd, a0, a1, size, checksum, magic = struct.unpack('<6I', exact(sock, 24))
    if size > 4096 or magic != cmd ^ 0xffffffff: raise ValueError('bad packet header')
    data = exact(sock, size)
    if sum(data) != checksum: raise ValueError('bad packet checksum')
    return cmd.to_bytes(4, 'little'), a0, a1, data


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ('0', '1'):
        raise SystemExit('synthetic mode must be 0 or 1')
    with socket.create_connection(('127.0.0.1', PORT), timeout=5) as sock:
        sock.settimeout(10)
        send(sock, b'CNXN', 0x01000000, 4096, b'host::\0')
        cmd, _, _, _ = receive(sock)
        if cmd != b'CNXN': raise ValueError('unexpected auth or connection response')
        send(sock, b'OPEN', 1, 0, b'sync:\0')
        cmd, remote, local, _ = receive(sock)
        if cmd != b'OKAY' or local != 1 or remote == 0: raise ValueError('cannot open sync')
        send(sock, b'WRTE', 1, remote, b'RECV' + struct.pack('<I', len(PATH)) + PATH)
        buffer = b''
        data = b''
        result = None
        for _ in range(30):
            cmd, a0, a1, chunk = receive(sock)
            if cmd == b'OKAY': continue
            if cmd != b'WRTE' or a0 != remote or a1 != 1: raise ValueError('unexpected sync transport')
            send(sock, b'OKAY', 1, remote)
            buffer += chunk
            while len(buffer) >= 8:
                kind, size = struct.unpack_from('<4sI', buffer)
                if kind == b'DONE':
                    if size != 0: raise ValueError('bad done')
                    buffer = buffer[8:]; result = 'read'; break
                if kind not in (b'DATA', b'FAIL') or size > 4096: raise ValueError('bad sync reply')
                if len(buffer) < 8 + size: break
                part = buffer[8:8+size]; buffer = buffer[8+size:]
                if kind == b'FAIL': result = 'denied'; break
                data += part
            if result: break
        if sys.argv[1] == '0' and result == 'denied':
            print('Root-only synthetic fixture: denied for synthetic shell-UID daemon')
        elif sys.argv[1] == '1' and result == 'read' and data == EXPECTED:
            print('Root-only synthetic fixture: read byte-for-byte by synthetic root-UID daemon')
        else:
            raise ValueError('unexpected sync result ' + repr(result))

if __name__ == '__main__': main()
