#!/usr/bin/env python3
"""Tiny RCON client: send one command to the local Minecraft server.

Usage: rcon.py "whitelist add Steve"
Reads the password from /opt/minecraft/.rcon-password. Only talks to 127.0.0.1.
"""
import socket
import struct
import sys

HOST, PORT = "127.0.0.1", 25575
PW_FILE = "/opt/minecraft/.rcon-password"


def packet(req_id: int, kind: int, body: str) -> bytes:
    payload = struct.pack("<ii", req_id, kind) + body.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


def read_packet(sock: socket.socket):
    def recv_exact(n: int) -> bytes:
        data = b""
        while len(data) < n:
            chunk = sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("server closed the connection")
            data += chunk
        return data

    (length,) = struct.unpack("<i", recv_exact(4))
    data = recv_exact(length)
    req_id, kind = struct.unpack("<ii", data[:8])
    return req_id, kind, data[8:-2].decode("utf-8", "replace")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.strip())
        return 2
    command = " ".join(sys.argv[1:])
    with open(PW_FILE) as f:
        password = f.read().strip()
    with socket.create_connection((HOST, PORT), timeout=10) as sock:
        sock.sendall(packet(1, 3, password))
        req_id, _, _ = read_packet(sock)
        if req_id == -1:
            print("RCON login failed", file=sys.stderr)
            return 1
        sock.sendall(packet(2, 2, command))
        _, _, body = read_packet(sock)
        if body:
            print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
