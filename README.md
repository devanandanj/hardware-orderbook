# hardware-orderbook

An FPGA order book engine that consumes NASDAQ ITCH 5.0 messages framed in
MoldUDP64 over Ethernet, reconstructs a bounded order book in hardware, and
streams book snapshots back to the host over UDP.

## What this is, precisely

An ITCH **book reconstruction** engine, not a matching engine. ITCH 5.0 is an
outbound market data feed: it reports fills as `E` messages rather than
expecting the receiver to match. Nothing is matched locally — doing so would
double-count against the executions the feed already reports.

Scope is deliberately bounded: four message types (`A`, `D`, `U`, `E`) and 64
resting orders per side.

## Layout

```
spec/        wire-format single source of truth + code generator
  *.yaml       ITCH, MoldUDP64, and book-snapshot layouts
  gen.py       emits Verilog / C++ / Python constants
  generated/   DO NOT EDIT -- regenerate with `python spec/gen.py`
rtl/         Verilog-2001 RTL
tb/uvm/      UVM testbench (Vivado xsim), golden model linked via DPI-C
bench/       latency experiment harness and plotting
formal/      SymbiYosys assertion harness for the book core
golden/      C++ golden model (git submodule, pinned)
docs/
```

The `golden/` directory is a git submodule pointing at
<https://github.com/devanandanj/Orderbook-cpp>. Clone with
`git clone --recursive` (or run `git submodule update --init --recursive`
after a plain clone) to fetch it.

The host stimulus/listener tooling (`../moldudp-scapy`) is not yet linked
in as a submodule; do so when it stabilises.

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
| RTL language | Verilog-2001 | The only choice that is simultaneously ISE/XST-, Vivado-, Icarus-, and Verilator-safe. SystemVerilog lives in the testbench and assertions, where it earns its keep |
| Order lookup | 128-wide parallel comparator in flops | At 64 orders per side, a one-cycle broadcast compare *is* the hardware advantage. BRAM's registered read would serialize exactly the thing that makes this fast |
| Throughput | Multi-cycle FSM, not one message per cycle | A 36-byte Add takes 36 cycles just to arrive on an 8-bit datapath, leaving ~30 cycles of slack. This removes the read/write hazard entirely |
| Egress | Fixed-size 1056-byte big-endian UDP packet, one per side | Two packets per ITCH message keeps each packet under the 1472-byte unfragmented-UDP limit while doubling book capacity vs. a single combined snapshot. UDP already supplies framing, length, and a checksum, so no SYNC word, no length field, no CRC. Fixed size means the serializer is a register file plus a byte counter |
| Trace | The snapshot bytes **are** the verification trace | The golden model emits the identical format, so the scoreboard is a byte diff |

## Verification

Both the RTL and the golden model consume the same `.mold` binary stimulus
files and emit the same snapshot byte format (a bid packet then an ask
packet per ITCH message). The scoreboard is a byte diff with the hardware
cycle counters (`t_arrive`, `t_commit`) masked out.

The book core is verified with a UVM testbench in `tb/uvm/`, run on Vivado
xsim:

- **Agent**: driver, monitor and sequencer on `book_if`, one command per cycle.
- **Scoreboard**: replays every observed command into the C++ golden model
  through DPI-C and compares the full book after each commit, so the RTL is
  checked against the same code as everything else, not a re-port.
- **Sequences**: a directed full-book corner sequence (fill, tie/worse/better
  adds, partial and over-fill executions, replace, unknown refs) and a
  constrained-random A/D/E/U mix.
- **Coverage**: command type x hit/miss, add outcome (insert/evict/discard)
  x side, partial vs. full execution.
- **SVA** in `book_if`: commit timing, count bounds, full flags, sticky gap.

```bash
tb/uvm/run.sh                      # book_random_test, seed 1
tb/uvm/run.sh book_fill_test 42    # named test and seed
```

SymbiYosys under `formal/` proves the book's safety and per-command
functional properties -- see `formal/README.md`.


## License

MIT
