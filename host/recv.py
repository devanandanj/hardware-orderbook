#!/usr/bin/env python3
"""Collect the board's snapshot packets, check them, and optionally diff against golden."""

from __future__ import annotations

import argparse
import socket
import struct
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "spec" / "generated"))
import itch_defs as d  # noqa: E402

CLOCK_NS = 8
FIELDS = d.SNAP_PACKET_FIELDS
MASKED = {FIELDS.index(f) for f in d.SNAP_DIFF_MASKED_FIELDS}


def addr(text: str) -> tuple[str, int]:
    host, port = text.rsplit(":", 1)
    return host, int(port)


def unpack(pkt: bytes) -> dict:
    return dict(zip(FIELDS, struct.unpack(d.SNAP_PACKET_FMT, pkt)))


def udp_rcvbuf_errors() -> int | None:
    try:
        lines = [l.split() for l in Path("/proc/net/snmp").read_text().splitlines() if l.startswith("Udp:")]
        return int(lines[1][lines[0].index("RcvbufErrors")])
    except (OSError, ValueError, IndexError):
        return None


def collect(sock: socket.socket, idle: float) -> list[bytes]:
    pkts = []
    sock.settimeout(None)
    while True:
        try:
            pkts.append(sock.recv(2048))
        except socket.timeout:
            return pkts
        sock.settimeout(idle)


def check(pkts: list[bytes], golden: bytes | None) -> int:
    errors = 0
    good = []
    for i, pkt in enumerate(pkts):
        if len(pkt) != d.SNAP_PACKET_LEN:
            print(f"packet {i}: length {len(pkt)}, want {d.SNAP_PACKET_LEN}")
            errors += 1
            continue
        f = unpack(pkt)
        if f["magic"] != d.SNAP_MAGIC or f["version"] != d.SNAP_VERSION:
            print(f"packet {i}: magic {f['magic']:#06x} version {f['version']}")
            errors += 1
            continue
        good.append(f)

    lost = 0
    for prev, cur in zip(good, good[1:]):
        step = (cur["snap_seq"] - prev["snap_seq"]) & 0xFFFFFFFF
        if step != 1:
            if step == 0 or step > 0x80000000:
                print(f"snap_seq went from {prev['snap_seq']} to {cur['snap_seq']}")
                errors += 1
            else:
                lost += step - 1
    first = good[0]["snap_seq"] if good else None
    print(f"received {len(pkts)} packets, {len(good)} valid, first snap_seq {first}, {lost} missing in sequence")

    status = Counter(name for f in good for name, bit in d.SNAP_STATUS_BITS.items() if f["status"] >> bit & 1)
    if status:
        print("status bits set: " + ", ".join(f"{n} {c}" for n, c in sorted(status.items())))

    lat = Counter((f["t_commit"] - f["t_arrive"]) & 0xFFFFFFFF for f in good)
    if lat:
        print("t_commit - t_arrive (cycles: count): " +
              ", ".join(f"{c}: {n}" for c, n in sorted(lat.items())))
        print(f"latency max {max(lat)} cycles = {max(lat) * CLOCK_NS} ns at {1000 // CLOCK_NS} MHz")

    if golden is not None:
        errors += diff(good, golden)
    return errors


def diff(good: list[dict], golden: bytes) -> int:
    if len(golden) % d.SNAP_PACKET_LEN:
        print(f"golden file is {len(golden)} bytes, not a multiple of {d.SNAP_PACKET_LEN}")
        return 1
    want = [struct.unpack_from(d.SNAP_PACKET_FMT, golden, o) for o in range(0, len(golden), d.SNAP_PACKET_LEN)]
    mismatches = 0
    for f in good:
        seq = f["snap_seq"]
        if seq >= len(want):
            print(f"snap_seq {seq} is past golden's {len(want)} snapshots")
            mismatches += 1
            continue
        got = tuple(f.values())
        bad = [i for i in range(len(FIELDS)) if i not in MASKED and got[i] != want[seq][i]]
        if bad:
            if not mismatches:
                print(f"first mismatch at snap_seq {seq}:")
                for i in bad:
                    print(f"  {FIELDS[i]}: board {got[i]}, golden {want[seq][i]}")
            mismatches += 1
    seen = {f["snap_seq"] for f in good}
    print(f"golden: {len(want)} snapshots, {len(seen & set(range(len(want))))} compared, {mismatches} mismatched")
    return mismatches


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--listen", type=addr, default=("0.0.0.0", 26401), help="ip:port")
    ap.add_argument("--golden", type=Path, help="golden snapshot.bin for the same .mold and base price")
    ap.add_argument("--idle", type=float, default=2.0, help="stop after this many quiet seconds")
    ap.add_argument("--out", type=Path, help="save the packets, concatenated like snapshot.bin")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 << 20)
    sock.bind(args.listen)
    print(f"listening on {args.listen[0]}:{args.listen[1]}", flush=True)

    drops_before = udp_rcvbuf_errors()
    pkts = collect(sock, args.idle)
    drops_after = udp_rcvbuf_errors()
    if drops_before is not None and drops_after != drops_before:
        print(f"host dropped {drops_after - drops_before} UDP datagrams (socket buffer full); "
              "raise net.core.rmem_max or send slower")

    if args.out:
        args.out.write_bytes(b"".join(pkts))
    golden = args.golden.read_bytes() if args.golden else None
    errors = check(pkts, golden)
    print("PASS" if not errors else f"FAIL: {errors} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
