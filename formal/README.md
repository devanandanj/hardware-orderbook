# Formal verification of the book core

This directory proves properties about the RTL book with
[SymbiYosys](https://symbiyosys.readthedocs.io/) driving Yosys and the built-in
model checkers. Formal verification of the invariants stated below is a
stronger claim than a byte-diff regression: it exhausts the state space up to
a bounded depth, and it is done automatically by CI on every push.

## Why this directory exists

The book has a small number of properties that must hold in every reachable
state -- for example, `bid_count` never
exceeds `MAX_ORDERS_PER_SIDE`. Cocotb regression checks these against real
stimulus but cannot rule out adversarial states it never happened to
generate. SymbiYosys does.

If a property is unprovable, either the property is wrong or the RTL is
wrong -- fix whichever is wrong, do not weaken the property.

## Approach

- `rtl/book.v` stays pure Verilog-2001. The properties live in
  `book_formal.sv`, a wrapper that instantiates `book` and asserts on its
  outputs. (Not a `bind`: open-source Yosys does not support it.)
- Every command input is a free top-level input, so the solver chooses the
  stimulus. The only constraints are the feed guarantees listed under
  "Assumptions" below.
- Each functional property compares the book one cycle after a command with
  the book one cycle before it, slot by slot.
- Proofs run at `MAX = 4` per side (`chparam` in `book.sby`). The RTL is
  identical at any size; a small book lets k-induction close in seconds.
- `book.sby` tasks:
  - `prove` -- k-induction. A PASS here is an unbounded proof: the
    properties hold in every reachable state.
  - `cover` -- witnesses that every interesting state is reachable, so no
    property is vacuously true.
  - `bmc` -- bounded check to depth 10, which covers filling a side and
    evicting from it. Redundant once `prove` passes; useful for quick
    counterexamples while editing.

## Running

Install the oss-cad-suite bundle (yosys + sby + solvers):
<https://github.com/YosysHQ/oss-cad-suite-build/releases>

```
make prove         # unbounded proof (~30 s)
make cover         # reachability witnesses
make bmc           # bounded check (minutes)
```

CI runs `make prove cover` on every push.

## Properties (see `book_formal.sv`)

### Safety -- every cycle

- Counts equal the number of occupied slots per side and never exceed `MAX`.
- `book_full_*` is set iff that side is at `MAX`.
- `cmd_ready` is always high (one command per cycle).
- No order ref rests in two slots, across both sides. This is an induction
  helper: unreachable from reset, but without it k-induction starts from a
  state with a duplicate ref, where a `D` removes one copy and leaves the
  other.

### Functional -- one-step effect of each command

- `A` -- lands on its side with its price and shares, unless the side was
  full and its price does not strictly beat the worst resting order, in
  which case it is dropped. An evicting add removes precisely the worst
  order (lowest bid / highest ask; on a price tie, the highest ref).
- `D` -- the order is gone.
- `E` -- shares are reduced by `executed_shares`, or the order is removed
  once `executed_shares >= shares`.
- `U` -- the original is gone and the new ref rests on the original's side
  with the new price and shares, whatever `cmd_side` says.
- `unknown_order_ref` is set iff the last command was `D`/`E`/`U` and its
  ref was not in the book.
- `commit` pulses exactly one cycle after each accepted command.
- `mold_gap_seen` is the sticky OR of every `mold_gap` pulse since reset.

### Frame -- nothing else changes

- Every resting order that is not the command's target (nor the evicted
  order) stays in the same slot with the same ref, price and shares. With no
  command, that is every order.
- Every order resting now was either already there or is the one the
  command adds.

### Coverage witnesses

Both sides full, evict, discard, partial execution, replace, unknown ref,
gap seen, and an add-then-delete that empties the book.

## Assumptions

Only what a valid ITCH feed guarantees -- nothing about the book, which is
what is being proved:

- `cmd_type` is one of `A`, `D`, `E`, `U`.
- An `A`'s order ref is not already in the book; neither is a `U`'s new ref.
  (Refs are unique for the life of the feed.)

The MoldUDP64 feed-layer properties (heartbeat, end-of-session,
retransmission) belong to the de-framer, which is not written yet.
