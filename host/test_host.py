#!/usr/bin/env python3
"""Loopback check of send.py and recv.py, no board needed."""

from __future__ import annotations

import socket
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "spec" / "generated"))
import itch_defs as d  # noqa: E402

PORT = 26411


def mold(seq: int, msgs: list[bytes]) -> bytes:
    return struct.pack(d.MOLD_HDR_FMT, b"TESTSESS  ", seq, len(msgs)) + b"".join(
        struct.pack(">H", len(m)) + m for m in msgs)


def snap(seq: int, t_arrive: int = 0, t_commit: int = 0, bid: int = 3000000) -> bytes:
    return struct.pack(d.SNAP_PACKET_FMT, d.SNAP_MAGIC, d.SNAP_VERSION, 0, seq, seq + 1, seq,
                       t_arrive, t_commit, bid, 100, bid + 100, 200, 1, 2)


def test_send(tmp: Path) -> None:
    packets = [mold(1, [b"A" * 36, b"D" * 19]), mold(3, []), mold(3, [b"E" * 31]),
               struct.pack(d.MOLD_HDR_FMT, b"TESTSESS  ", 4, d.MOLD_END_OF_SESSION)]
    path = tmp / "t.mold"
    path.write_bytes(b"".join(packets))
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.bind(("127.0.0.1", PORT))
    out = subprocess.run([sys.executable, HERE / "send.py", path, "--board", f"127.0.0.1:{PORT}"],
                         check=True, capture_output=True, text=True).stdout
    got = [rx.recv(2048) for _ in packets]
    assert got == packets, "send.py changed packet boundaries or bytes"
    assert out.startswith("sent 4 packets, 3 messages"), out


def run_recv(sends: list[bytes], golden: Path) -> tuple[int, str]:
    proc = subprocess.Popen([sys.executable, HERE / "recv.py", "--listen", f"127.0.0.1:{PORT}",
                             "--golden", golden, "--idle", "0.3"],
                            stdout=subprocess.PIPE, text=True)
    assert "listening" in proc.stdout.readline()
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for p in sends:
        tx.sendto(p, ("127.0.0.1", PORT))
    out = proc.communicate(timeout=10)[0]
    return proc.returncode, out


def test_recv(tmp: Path) -> None:
    golden = tmp / "golden.bin"
    golden.write_bytes(b"".join(snap(i) for i in range(50)))
    board = [snap(i, 100 * i, 100 * i + 10 + i % 10) for i in range(50)]

    rc, out = run_recv(board, golden)
    assert rc == 0 and "PASS" in out and "50 compared, 0 mismatched" in out, out
    assert "latency max 19 cycles = 152 ns" in out, out

    bad = board[:10] + board[11:]
    bad[20] = snap(21, 0, 0, bid=2999900)
    rc, out = run_recv(bad + [b"short"], golden)
    assert rc == 1, out
    assert "1 missing in sequence" in out, out
    assert "first mismatch at snap_seq 21" in out and "bid_price: board 2999900, golden 3000000" in out, out
    assert "length 5" in out and "1 mismatched" in out, out


def main() -> int:
    with tempfile.TemporaryDirectory() as t:
        test_send(Path(t))
        test_recv(Path(t))
    print("PASS host loopback")
    return 0


if __name__ == "__main__":
    sys.exit(main())
