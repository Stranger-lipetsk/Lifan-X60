#!/usr/bin/env python3
"""Line protocol for an already-open, synthetic file descriptor in CI only."""
import os
import sys


def run(path, reader, writer):
    fd = os.open(path, os.O_RDWR | os.O_APPEND)
    try:
        st = os.fstat(fd)
        print(f'READY {st.st_dev}:{st.st_ino}', file=writer, flush=True)
        for line in reader:
            command = line.strip()
            if command == 'before-switch':
                payload = b'WRITE_AFTER_SNAPSHOT_BEFORE_SWITCH\n'
            elif command == 'after-switch':
                payload = b'WRITE_AFTER_SWITCH_OLD_FD\n'
            elif command == 'finish':
                os.lseek(fd, 0, os.SEEK_SET)
                contents = os.read(fd, 4096)
                ok = all(part in contents for part in (b'INITIAL\n', b'WRITE_AFTER_SNAPSHOT_BEFORE_SWITCH\n', b'WRITE_AFTER_SWITCH_OLD_FD\n'))
                print(f'OLD_FD_CONTAINS_BOTH={str(ok).lower()}', file=writer, flush=True)
                return 0 if ok else 1
            else:
                raise ValueError(f'unexpected command: {command}')
            os.write(fd, payload)
            os.fsync(fd)
            print(f'WROTE {command}', file=writer, flush=True)
        raise RuntimeError('command stream ended before finish')
    finally:
        os.close(fd)


def main():
    if len(sys.argv) != 2:
        raise SystemExit('expected one synthetic file path')
    sys.exit(run(sys.argv[1], sys.stdin, sys.stdout))


if __name__ == '__main__':
    main()
