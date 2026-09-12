#!/usr/bin/env python3
"""
Tests for the wire-format specification and its generated output.

Run standalone:   python spec/test_spec.py
Run under pytest: pytest spec/test_spec.py

Three things are checked:

1. Internal consistency -- every generated struct format string packs to
   exactly the declared message length.
2. Agreement with the frozen golden model -- the hand-written constants in
   Orderbook-cpp must match what the spec generates. This is the check that
   proves the spec describes the model that is already verified, rather than
   a plausible-looking format someone invented.
3. Physical constraints -- the snapshot payload must fit in one
   non-fragmenting UDP datagram.

The per-field byte offsets inside each ITCH message are NOT checked here.
They are verified by the end-to-end byte-diff regression once the model is
built against the generated header.
"""

from __future__ import annotations

import os
import re
import struct
import sys
from pathlib import Path

SPEC_DIR = Path(__file__).resolve().parent
GENERATED = SPEC_DIR / "generated"

sys.path.insert(0, str(GENERATED))
import itch_defs as d  # noqa: E402

# The golden model lives in its own repository until the migration happens.
MODEL_DIR = Path(
    os.environ.get("ORDERBOOK_CPP_DIR", SPEC_DIR.parent.parent / "Orderbook-cpp")
)

# Named constants in the golden model, and the generated value each must equal.
MODEL_CONSTANTS = {
    "include/itchparser.h": {
        "ADD_ORDER_LEN": lambda: d.ITCH_MESSAGES["add_order"]["length"],
        "ORDER_DELETE_LEN": lambda: d.ITCH_MESSAGES["order_delete"]["length"],
        "ORDER_REPLACE_LEN": lambda: d.ITCH_MESSAGES["order_replace"]["length"],
        "ORDER_EXECUTE_LEN": lambda: d.ITCH_MESSAGES["order_executed"]["length"],
    },
    "include/moldudp64.h": {
        "MOLDUDP64_HEADER_LEN": lambda: d.MOLD_HDR_LEN,
        "MOLDUDP64_SESSION_OFFSET": lambda: d.MOLD_SESSION_OFF,
        "MOLDUDP64_SESSION_LEN": lambda: d.MOLD_SESSION_W,
        "MOLDUDP64_SEQNUM_OFFSET": lambda: d.MOLD_SEQUENCE_OFF,
        "MOLDUDP64_MSGCOUNT_OFFSET": lambda: d.MOLD_MESSAGE_COUNT_OFF,
        "MOLDUDP64_HEARTBEAT": lambda: d.MOLD_HEARTBEAT,
        "MOLDUDP64_END_OF_SESSION": lambda: d.MOLD_END_OF_SESSION,
    },
    "include/using.h": {
        "MAX_ORDERS_PER_SIDE": lambda: d.SNAP_MAX_PER_SIDE,
    },
}

# Largest UDP payload that will not fragment on a 1500-byte-MTU Ethernet link
# (1500 - 20 bytes IPv4 header - 8 bytes UDP header).
MAX_UNFRAGMENTED_UDP_PAYLOAD = 1472


def _read_cpp_constant(path: Path, name: str) -> int:
    """Pull `constexpr ... NAME = <value>;` out of a C++ header."""
    text = path.read_text(encoding="utf-8")
    match = re.search(
        rf"\b{re.escape(name)}\s*=\s*(0[xX][0-9a-fA-F]+|\d+)\s*;", text
    )
    if match is None:
        raise AssertionError(f"{path.name}: constant '{name}' not found")
    return int(match.group(1), 0)


def test_struct_formats_match_declared_lengths() -> None:
    for name, message in d.ITCH_MESSAGES.items():
        size = struct.calcsize(message["struct_fmt"])
        assert size == message["length"], (
            f"itch.{name}: struct format {message['struct_fmt']} packs "
            f"{size} bytes but the message is {message['length']}"
        )

    assert struct.calcsize(d.MOLD_HDR_FMT) == d.MOLD_HDR_LEN
    assert struct.calcsize(d.SNAP_HDR_FMT) == d.SNAP_HDR_LEN
    assert struct.calcsize(d.SNAP_LEVEL_FMT) == d.SNAP_LEVEL_LEN


def test_snapshot_total_length() -> None:
    expected = d.SNAP_HDR_LEN + 2 * d.SNAP_MAX_PER_SIDE * d.SNAP_LEVEL_LEN
    assert d.SNAP_TOTAL_LEN == expected

    assert d.SNAP_TOTAL_LEN <= MAX_UNFRAGMENTED_UDP_PAYLOAD, (
        f"snapshot payload is {d.SNAP_TOTAL_LEN} bytes and would fragment; "
        f"reduce max_orders_per_side or shrink the level record"
    )


def test_status_bits_fit_in_one_byte() -> None:
    bits = list(d.SNAP_STATUS_BITS.values())
    assert len(bits) == len(set(bits)), "duplicate status bit position"
    assert all(0 <= b <= 7 for b in bits), "status word is only one byte wide"


def test_masked_fields_exist_in_header() -> None:
    for name in d.SNAP_DIFF_MASKED_FIELDS:
        assert name in d.SNAP_HDR_FIELDS, (
            f"'{name}' is masked from the diff but is not a header field"
        )


def test_agrees_with_golden_model() -> None:
    if not MODEL_DIR.is_dir():
        print(f"SKIP golden-model cross-check: {MODEL_DIR} not found "
              f"(set ORDERBOOK_CPP_DIR to override)")
        return

    for rel_path, constants in MODEL_CONSTANTS.items():
        path = MODEL_DIR / rel_path
        assert path.is_file(), f"golden model file missing: {path}"

        for name, expected_fn in constants.items():
            actual = _read_cpp_constant(path, name)
            expected = expected_fn()
            assert actual == expected, (
                f"{rel_path}: {name} is {actual} in the golden model but "
                f"the spec generates {expected}. One of them is wrong -- "
                f"do not 'fix' this by editing the generated file."
            )


def main() -> int:
    tests = [fn for name, fn in sorted(globals().items())
             if name.startswith("test_") and callable(fn)]

    failures = 0
    for test in tests:
        try:
            test()
        except AssertionError as exc:
            print(f"FAIL {test.__name__}\n     {exc}")
            failures += 1
        else:
            print(f"ok   {test.__name__}")

    print(f"\n{len(tests) - failures}/{len(tests)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
