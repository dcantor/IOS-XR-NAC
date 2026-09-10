#!/usr/bin/env python3
"""Send one or more commands to a QEMU monitor telnet port and print replies.

    ./tools/qmon.py 4101 'info status' 'info registers'

Deliberately refuses to forward 'quit'/'q', which would terminate the VM.
"""
import socket
import sys
import time

BANNED = {"quit", "q", "system_powerdown", "system_reset"}


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: qmon.py <monitor-port> <command> [command ...]")
    port, cmds = int(sys.argv[1]), sys.argv[2:]
    for c in cmds:
        if c.strip().split()[0].lower() in BANNED:
            sys.exit("refusing to send %r to the monitor" % c)

    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    sock.settimeout(3)
    time.sleep(0.5)
    try:
        sock.recv(65536)  # banner + telnet negotiation
    except socket.timeout:
        pass

    for cmd in cmds:
        sock.sendall(cmd.encode() + b"\n")
        time.sleep(1.5)
        buf = b""
        while True:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
        print("=== %s ===" % cmd)
        # The monitor echoes each keystroke with cursor-movement escapes; drop
        # the echoed command line and show only the reply.
        text = buf.decode(errors="replace").replace("\r", "")
        print("\n".join(text.split("\n")[1:]).strip())
    sock.close()


if __name__ == "__main__":
    main()
