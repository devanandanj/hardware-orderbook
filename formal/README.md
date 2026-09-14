# Formal verification of the book core

This directory proves properties about the RTL book with
[SymbiYosys](https://symbiyosys.readthedocs.io/) driving Yosys and the built-in
model checkers. Formal verification of the invariants stated below is a
stronger claim than a byte-diff regression: it exhausts the state space up to
a bounded depth, and it is done automatically by CI on every push.

## Why this directory exists

The book has a small number of properties that must hold in every reachable
state -- for example, no order_ref ever appears twice, and `bid_count` never
exceeds `MAX_ORDERS_PER_SIDE`. Cocotb regression checks these against real
stimulus but cannot rule out adversarial states it never happened to
generate. SymbiYosys does.

This is also useful as a *design contract*. Everything here is written before
the RTL is authored; the RTL then has to satisfy it. If a property is
unprovable, either the property is wrong or the RTL is wrong -- fix whichever
is wrong, do not weaken the property.

## Approach

- The DUT (`rtl/book.v` -- not yet written) stays pure Verilog-2001 so it
  remains synthesisable in ISE/XST, Vivado, Icarus and Verilator. Assertions
  live outside it.
- `book_props.sv` is a SystemVerilog file that binds SVA properties to the
  DUT's signals. SymbiYosys reads it via a `bind` directive so the DUT source
  is not touched.
- `book.sby` runs three tasks:
  - `bmc` -- bounded model check to a depth that exhausts one round of every
    ITCH command type.
  - `prove` -- k-induction attempt for the invariant properties.
  - `cover` -- coverage witnesses that prove the interesting states are
    actually reachable (`book_full_bid`, `unknown_order_ref`, etc.), so a
    property is not vacuously satisfied.

## Running

Install the oss-cad-suite bundle (has yosys + sby + all backends):
<https://github.com/YosysHQ/oss-cad-suite-build/releases>

Then:

```
make prove         # runs all three tasks
make bmc           # bounded check only
make cover         # coverage witnesses only
```

CI runs `make prove` on every push once the RTL exists. The CI job is
currently commented out in `.github/workflows/ci.yml`; uncomment when
`rtl/book.v` is committed.

## Properties (see `book_props.sv` for the SVA)

### Safety -- invariants that hold at every clock edge

- `no_duplicate_order_ref` -- no order reference appears twice in the book,
  across both sides.
- `count_bounds` -- `bid_count` and `ask_count` are always in
  `[0, MAX_ORDERS_PER_SIDE]`.
- `book_full_iff_at_cap` -- `book_full_bid` iff `bid_count == MAX`; same for
  ask.
- `unknown_ref_sticky_until_cleared` -- `unknown_order_ref` is a status of
  the last command, not a running flag. Verify its precise semantics against
  the yaml.
- `mold_gap_sticky` -- once `mold_gap_seen` is set it stays set until reset.

### Functional correctness -- one-step effects of each command

- `add_then_present` -- an accepted `A` command results in the order being
  in the book at the next commit.
- `delete_removes` -- a `D` command against a present order_ref removes it
  and does not touch anything else.
- `update_swaps` -- a `U` command against a present `original_order_ref`
  removes it and inserts `new_order_ref` with the new shares/price on the
  same side.
- `execute_reduces` -- an `E` command reduces the target order's shares by
  `executed_shares`. If the result is zero, the order is removed.
- `unknown_ref_flagged` -- a `D`/`U`/`E` against a not-present order_ref
  leaves the book unchanged and raises `unknown_order_ref` for that snapshot.

### Feed-layer

- `heartbeat_no_effect` -- a MoldUDP64 header with `message_count == 0`
  advances no state and emits no snapshot.
- `eos_no_effect` -- same for `message_count == 0xFFFF`.
- `retransmit_ignored` -- a sequence number less than `expected` is
  silently discarded.

### Coverage witnesses -- proves the properties aren't vacuously green

- `cover_add_to_cap` -- reach `book_full_bid`.
- `cover_wraparound` -- reach a state where an Add, then a Delete of that
  Add, returns the book to the pre-Add state.
- `cover_gap` -- reach `mold_gap_seen`.

## Constraints on the environment

Assumptions live in `book_props.sv` under `// -- assumptions --`. Keep the
set minimal: only the ITCH invariants that a valid feed guarantees (e.g.
`side` is always `B` or `S`, prices are non-zero). Do not assume anything
about the book -- that is what we are proving.
