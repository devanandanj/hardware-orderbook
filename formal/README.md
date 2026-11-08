# Formal verification of the book FSM

This directory proves control properties of `rtl/book.sv` with
[SymbiYosys](https://symbiyosys.readthedocs.io/). Data correctness (what each
command does to the table and the levels) is not proved here: `tb/book/`
checks every memory write against the golden model instead.

If a property is unprovable, either the property is wrong or the RTL is
wrong -- fix whichever is wrong, do not weaken the property.

## Approach

- `book_formal.sv` is a top whose inputs are all free, so the solver
  chooses the stimulus. It instantiates `book` and nothing else.
- The properties sit in `rtl/book.sv` under `` `ifdef FORMAL ``. They need
  internal signals, and open-source Yosys cannot reach those from a wrapper
  (no `bind`, no hierarchical references). sv2v, ISE and Verilator never
  define `FORMAL`, so they never see the block.
- The geometry is small: 2 sets of 1 way, a 1-entry CAM and 16 slots per
  side, from `book_small.yaml`. The FSM is the same at any size; only memory
  depths and the reset clear change. `generated/` holds its `itch_defs.vh`
  and is committed, like `spec/generated/`; CI checks it is current. After
  editing `book_small.yaml`, run
  `python3 ../spec/gen.py --book book_small.yaml --outdir generated`.
- The only assumption is that reset is applied once, at the start.
- The engine is bitwuzla. Boolector, the old default, stalls on the multiplier
  in `price_slot`, and yices and z3 take tens of minutes over the covers.
- `book.sby` tasks:
  - `prove` -- k-induction, depth 8. A PASS is an unbounded proof. The
    timeline invariants below keep it shallow; without them the window has
    to span a whole command (46 steps), which takes the solver an hour.
  - `cover` -- witnesses that each interesting outcome is reachable, so no
    property holds only vacuously.
  - `bmc` -- bounded check to depth 30, for quick counterexamples while
    editing.

## Running

Install the oss-cad-suite bundle (yosys + sby + solvers):
<https://github.com/YosysHQ/oss-cad-suite-build/releases>

```
make prove         # ~1 s
make cover         # ~70 s
make bmc           # ~3 s
```

CI runs `make prove cover` on every push.

## Properties

### Handshake and latency

- `done` pulses exactly once per accepted command and never otherwise;
  `cmd_ready` is low from accept until then.
- `done` comes within the cycles the message takes to arrive at one byte a
  clock (its ITCH length plus the 2-byte Mold length): D 21, X 25, E 33,
  U 37, A and C 38, F 42, anything else 8.

### Memory access rules

- No order table write in the cycle a lookup is issued or the one after,
  so a lookup never mixes old and new contents.
- No price book read or write while that book is busy.

### Status

- At most one of `order_dropped`, `price_rejected`, `unknown_order_ref`.
- `unknown_order_ref` only after E, C, X, D or U; `order_dropped` and
  `price_rejected` only after A, F or U.

### BBO

- An empty side reports slot, shares and orders as 0.

### Induction helpers

True from reset, and needed so k-induction does not start from states
reset never reaches:

- The order table and price_slot respond exactly 2 and 3 cycles after
  their requests, and `ps_pending` matches the price_slot pipeline.
- The first cycles after reset are spent in `S_INIT`; after it the table
  is out of its clear. In `S_IDLE` nothing is in flight and both price
  books are ready.
- Timeline: each state is pinned to the cycles since accept at which it
  can occur (`S_REM_RD` at cycle 3, the remove's write at cycle 4, `S_INS`
  of a replace at 8 to 10, `S_SETTLE` by 17), and to the command types that
  reach it. Status bits are only set on the way into `S_SETTLE`.
- A command writes one price book side only. The other side stays ready,
  and the written side is ready again within 5 cycles of its write.

### Coverage witnesses

An add that rests, is dropped, or is price-rejected; a partial cancel; a
delete that finds its order and one that does not; a replace that succeeds
and one that is price-rejected; a non-book message; both sides occupied;
and the bid side emptying.
