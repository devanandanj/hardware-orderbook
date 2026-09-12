# hardware-orderbook

An FPGA order book engine that consumes NASDAQ ITCH 5.0 messages framed in
MoldUDP64 over Ethernet, reconstructs a bounded order book in hardware, and
streams book snapshots back to the host over UDP.

Final-year ECE capstone, College of Engineering Kidangoor.
Advaith Krishna S · Aishamol PT · Devanandan J · Fathima Neharin
Guide: Prof. Syamesh KG

## What this is, precisely

An ITCH **book reconstruction** engine, not a matching engine. ITCH 5.0 is an
outbound market data feed: it reports fills as `E` messages rather than
expecting the receiver to match. Nothing is matched locally — doing so would
double-count against the executions the feed already reports.

Scope is deliberately bounded: four message types (`A`, `D`, `U`, `E`) and 32
resting orders per side.

## Layout

```
spec/        wire-format single source of truth + code generator
  *.yaml       ITCH, MoldUDP64, and book-snapshot layouts
  gen.py       emits Verilog / C++ / Python constants
  generated/   DO NOT EDIT -- regenerate with `python spec/gen.py`
rtl/         Verilog-2001 RTL
tb/          cocotb testbenches and the scoreboard
bench/       latency experiment harness and plotting
docs/
```

Still in their own repositories until migration: the C++ golden model
(`../Orderbook-cpp`) and the host stimulus/listener tooling
(`../moldudp-scapy`).

## spec/ is the contract

Every byte offset, field width, and endianness decision lives in `spec/*.yaml`
and is generated into all three languages. Nothing hand-writes a wire format.

This exists because the project previously had two mutually incompatible
book-snapshot formats — one little-endian with 17-byte level records, one
big-endian with 16-byte records — because each was written by hand in a
different repository.

```bash
python spec/gen.py            # regenerate
python spec/gen.py --check    # fail if generated files are stale (CI)
python spec/test_spec.py      # validate, and cross-check against the golden model
```

`gen.py` refuses to emit anything unless every message's fields are contiguous
and sum to its declared length, so a mistyped offset fails at generation time
rather than as a scoreboard mismatch hundreds of messages into a run.
`test_spec.py` additionally verifies that the generated constants agree with
the hand-written ones in the frozen golden model.

## Key design decisions

| Decision | Choice | Why |
|---|---|---|
| RTL language | Verilog-2001 | The only choice that is simultaneously ISE/XST-, Vivado-, Icarus-, and Verilator-safe. cocotb makes the testbench Python, so SystemVerilog would buy nothing |
| Order lookup | 64-wide parallel comparator in flops | At 32 orders per side, a one-cycle broadcast compare *is* the hardware advantage. BRAM's registered read would serialize exactly the thing that makes this fast |
| Throughput | Multi-cycle FSM, not one message per cycle | A 36-byte Add takes 36 cycles just to arrive on an 8-bit datapath, leaving ~30 cycles of slack. This removes the read/write hazard entirely |
| Egress | Fixed-size 1056-byte big-endian UDP snapshot | UDP already supplies framing, length, and a checksum, so no SYNC word, no length field, no CRC. Fixed size means the serializer is a register file plus a byte counter |
| Trace | The snapshot bytes **are** the verification trace | The golden model emits the identical format, so the scoreboard is a byte diff |

## Verification

Both the RTL and the golden model consume the same `.mold` binary stimulus
files and emit the same snapshot byte format. The scoreboard is a byte diff
with the hardware cycle counters (`t_arrive`, `t_commit`) masked out.

cocotb + Icarus Verilog is the primary simulator; Verilator is the fast path
for long randomised runs.


## License

MIT
