#!/usr/bin/env python3
"""Replay a .mold file to the board, one MoldUDP64 packet per UDP datagram."""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "spec" / "generated"))
import itch_defs as d  # noqa: E402


def mold_packets(data: bytes):
    pos = 0
    while pos < len(data):
        if pos + d.MOLD_HDR_LEN > len(data):
            raise ValueError(f"truncated header at byte {pos}")
        _, _, count = struct.unpack_from(d.MOLD_HDR_FMT, data, pos)
        end = pos + d.MOLD_HDR_LEN
        if count in (d.MOLD_HEARTBEAT, d.MOLD_END_OF_SESSION):
            count = 0
        for _ in range(count):
            if end + d.MOLD_MSGLEN_W > len(data):
                raise ValueError(f"truncated message length at byte {end}")
            (length,) = struct.unpack_from(">H", data, end)
            end += d.MOLD_MSGLEN_W + length
        if end > len(data):
            raise ValueError(f"truncated packet at byte {pos}")
        yield data[pos:end], count
        pos = end


def addr(text: str) -> tuple[str, int]:
    host, port = text.rsplit(":", 1)
    return host, int(port)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mold", type=Path)
    ap.add_argument("--board", type=addr, default=("192.168.10.2", 26400), help="ip:port")
    ap.add_argument("--pps", type=float, default=50000,
                    help="packets per second, 0 for as fast as possible; the board sends one "
                         "114-cycle snapshot frame per message, so line rate overflows it")
    ap.add_argument("--count", type=int, help="stop after this many packets")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    gap = 1.0 / args.pps if args.pps else 0.0
    packets = messages = 0
    start = next_at = time.perf_counter()
    for pkt, count in mold_packets(args.mold.read_bytes()):
        if packets == args.count:
            break
        if gap:
            while time.perf_counter() < next_at:
                pass
            next_at += gap
        sock.sendto(pkt, args.board)
        packets += 1
        messages += count
    secs = time.perf_counter() - start
    print(f"sent {packets} packets, {messages} messages in {secs:.3f} s ({packets / secs:.0f} pps)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
