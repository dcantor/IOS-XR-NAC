#!/usr/bin/env python3
"""Persistent console attachment for a lab node.

Keeps one telnet connection to a QEMU serial chardev open, appends everything
the guest prints to run/<node>-console.log, and forwards anything written to
the FIFO run/<node>.in on to the guest. That way a long XR boot can be watched
and driven without repeatedly fighting over the single-client telnet port.

    ./tools/conmux.py xr1 5101 &             # attach
    printf 'show version\r' > run/xr1.in     # send a line

Telnet IAC negotiation is answered with a blanket refusal, which is what the
QEMU chardev expects from a dumb client.
"""
import os
import select
import socket
import sys

IAC, DONT, WONT, WILL, DO = 255, 254, 252, 251, 253


def strip_iac(sock, data):
    """Answer telnet option negotiation and return only the payload bytes."""
    res, i = bytearray(), 0
    while i < len(data):
        if data[i] == IAC and i + 2 < len(data):
            cmd, opt = data[i + 1], data[i + 2]
            if cmd == DO:
                sock.sendall(bytes([IAC, WONT, opt]))
            elif cmd == WILL:
                sock.sendall(bytes([IAC, DONT, opt]))
            i += 3
        elif data[i] == IAC:
            i += 2
        else:
            res.append(data[i])
            i += 1
    return bytes(res)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: conmux.py <node> <console-port>")
    node, port = sys.argv[1], int(sys.argv[2])
    run = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "run")
    log = os.path.join(run, node + "-console.log")
    fifo = os.path.join(run, node + ".in")

    if not os.path.exists(fifo):
        os.mkfifo(fifo)

    sock = socket.create_connection(("127.0.0.1", port))
    # O_RDWR on the FIFO keeps it open across writers, so select() does not
    # spin on EOF each time a writer closes its end.
    fin = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)

    with open(log, "ab", buffering=0) as f:
        while True:
            ready, _, _ = select.select([sock, fin], [], [], 30)
            if sock in ready:
                data = sock.recv(65536)
                if not data:
                    break
                f.write(strip_iac(sock, data))
            if fin in ready:
                sock.sendall(os.read(fin, 4096))


if __name__ == "__main__":
    main()
