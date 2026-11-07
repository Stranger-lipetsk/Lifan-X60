#!/usr/bin/env python3
"""Probe one fixed loopback port in CI's isolated synthetic container netns.

Sends only an ADB connection greeting, never sends shell/file commands. The
caller must enter a verified --network=none namespace first.
"""
import socket
import struct
import time

PORT = 43127


def exact(s, count):
    out = b''
    while len(out) < count:
        chunk = s.recv(count - len(out))
        if not chunk: raise OSError('connection closed')
        out += chunk
    return out


def main():
    last = None
    for _ in range(40):
        try:
            with socket.create_connection(('127.0.0.1', PORT), timeout=1) as s:
                s.settimeout(3)
                command = int.from_bytes(b'CNXN', 'little')
                payload = b'host::\0'
                s.sendall(struct.pack('<6I', command, 0x01000000, 4096, len(payload), sum(payload), command ^ 0xffffffff) + payload)
                raw = exact(s, 24)
                cmd, _, _, length, checksum, magic = struct.unpack('<6I', raw)
                if length > 4096 or magic != (cmd ^ 0xffffffff): raise ValueError('invalid packet header')
                response = exact(s, length)
                if checksum != sum(response): raise ValueError('invalid packet checksum')
                kind = cmd.to_bytes(4, 'little').decode('ascii', 'replace')
                if kind not in ('CNXN', 'AUTH'): raise ValueError('unexpected ADB response')
                print('Loopback ADB greeting response:', kind)
                return
        except (OSError, ValueError) as exc:
            last = exc
            time.sleep(.5)
    raise SystemExit('No successful isolated ADB greeting: ' + str(last))

if __name__ == '__main__': main()
