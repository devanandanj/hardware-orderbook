# hardware-orderbook

An FPGA order book engine that consumes NASDAQ ITCH 5.0 messages framed in
MoldUDP64 over Ethernet, reconstructs a bounded order book in hardware, and
streams book snapshots back to the host over UDP.

## What this is, precisely

An ITCH **book reconstruction** engine, not a matching engine. ITCH 5.0 is an
outbound market data feed: it reports fills as `E` messages rather than
expecting the receiver to match. Nothing is matched locally — doing so would
double-count against the executions the feed already reports.

Scope is deliberately bounded: one selected symbol, seven message types (`A`,
`F`, `E`, `C`, `X`, `D`, `U`), and the geometry in `spec/book.yaml`: a hashed
order table of 1024 sets x 3 ways plus a 16-entry overflow CAM, and 16384 price
levels per side. Host output is the best bid and offer, not full depth.

## Status

This describes the v3 design. The spec and golden model implement it; the RTL
is in progress.

| Block | State |
|---|---|
| `spec/`, `golden/` | v3 |
| `ethernet/` | Done, simulation only; not yet connected to the book |
| `rtl/order_table.sv` | Done, tested against golden in `tb/order_table/`; timing not yet checked |
| `rtl/price_slot.sv`, `rtl/price_book.sv` | Done, tested against golden in `tb/price_slot/` and `tb/price_book/`; timing not yet checked |
| Book FSM, Mold/ITCH ingress, snapshot egress | Not started |
| `rtl/book.sv` | v2 core (64 orders per side, full-depth snapshots), to be replaced |
| `formal/` | Proves the v2 core |
| `tb/uvm/` | Written for the v2 core; does not build against the v3 golden model |

## Layout

```
spec/        wire-format single source of truth + code generator
  *.yaml       ITCH, MoldUDP64, book-snapshot layouts, and book geometry
  gen.py       emits Verilog / C++ / Python constants
  generated/   DO NOT EDIT -- regenerate with `python spec/gen.py`
rtl/         SystemVerilog RTL
tb/order_table/, tb/price_slot/, tb/price_book/
             Verilator tests of each block against the golden model
tb/uvm/      UVM testbench (Vivado xsim), golden model linked via DPI-C
formal/      SymbiYosys assertion harness for the book core
golden/      C++ golden model (git submodule, pinned)
ethernet/    GMII to UDP payload front end and MAC TX (git submodule, pinned)
```

`golden/` and `ethernet/` are git submodules pointing at
<https://github.com/devanandanj/Orderbook-cpp> and
<https://github.com/devanandanj/low-latency-1g-ethernet>. Clone with
`git clone --recursive` (or run `git submodule update --init --recursive`
after a plain clone) to fetch them.

Python tooling needs `pip install -r requirements.txt`.

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
the hand-written ones in the golden model.

## Key design decisions

| Decision | Choice | Why |
|---|---|---|
| RTL language | SystemVerilog, restricted subset | Matches the Ethernet front end, the testbench and the assertions. Vivado, Verilator and Yosys are the targets; ISE is not. Yosys limits the subset: memories stay plain vectors (it silently drops an array of structs), packed structs are assigned directly rather than cast, package names are qualified rather than wildcard-imported, functions assign to their name instead of using `return`, packed arrays stay one-dimensional, and structs stay out of generate blocks and function arguments |
| Order lookup | Set-associative hash table in BRAM, plus a small flop CAM | Thousands of resting orders rule out a parallel compare over every order. One BRAM bank per way reads a whole set in a cycle, and the CAM catches set overflow. The golden model mirrors the placement bit-exactly, so an order dropped in one is dropped in the other |
| Throughput | Multi-cycle FSM, not one message per cycle | The shortest book message, `D`, takes about 21 cycles to arrive on an 8-bit datapath including its length prefix, which leaves room for several memory accesses per message |
| Egress | Fixed-size 48-byte big-endian UDP packet, one per book message | Full depth no longer fits on the wire at this book size, so the packet carries the best bid and offer. UDP already supplies framing, length, and a checksum, so no SYNC word, no length field, no CRC. Fixed size means the serializer is a register file plus a byte counter |
| Trace | The snapshot bytes **are** the verification trace | The golden model emits the identical format, so the scoreboard is a byte diff |

## Verification

The plan is for the RTL and the golden model to consume the same `.mold`
binary stimulus files and emit the same snapshot packets, one per book message.
The scoreboard is a byte diff with the hardware cycle counters (`t_arrive`,
`t_commit`) masked out. Deep-book state, which the wire no longer carries, is
compared memory by memory in simulation.

The order table and price book blocks are checked against the golden model's
own code with Verilator, using directed corner cases and random traffic. Price
to slot is checked for every price in the window:

```bash
make -C tb/order_table                  # seed 1
make -C tb/order_table SEED=7 ROUNDS=200
make -C tb/price_slot
make -C tb/price_book
```

The v2 book core was verified with a UVM testbench in `tb/uvm/`, run on Vivado
xsim. It needs porting to the v3 golden model before it builds again:

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

SymbiYosys under `formal/` proves the v2 book's safety and per-command
functional properties -- see `formal/README.md`.


## License

MIT
