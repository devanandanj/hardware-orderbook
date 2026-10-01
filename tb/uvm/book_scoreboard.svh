// Scoreboard: replays every observed command into the C++ golden model via
// DPI-C and compares the full book after each commit.

class book_scoreboard extends uvm_subscriber #(book_txn);
    `uvm_component_utils(book_scoreboard)

    bit model_gap_seen;
    int unsigned n_checked, n_unknown, n_evicted, n_discarded;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        golden_reset();
    endfunction

    function void check_side(string name, bit side, order_t got[$], book_txn t);
        int n = golden_count(side);
        if (got.size() != n) begin
            `uvm_error("SB", $sformatf("%s count: rtl=%0d golden=%0d after %s",
                                       name, got.size(), n, t.convert2string()))
            return;
        end
        for (int i = 0; i < n; i++) begin
            longint unsigned r;
            int unsigned p, q;
            golden_get(side, i, r, p, q);
            if (got[i].oref != r || got[i].price != p || got[i].qty != q) begin
                `uvm_error("SB", $sformatf(
                    "%s[%0d]: rtl={ref %0d, px %0d, qty %0d} golden={ref %0d, px %0d, qty %0d} after %s",
                    name, i, got[i].oref, got[i].price, got[i].qty, r, p, q,
                    t.convert2string()))
                return;
            end
        end
    endfunction

    function void write(book_txn t);
        int rc = golden_apply(t.typ, t.side, t.oref, t.new_ref, t.shares,
                              t.price, t.exe);
        model_gap_seen |= t.gap;

        case (rc)
            G_UNKNOWN:   n_unknown++;
            G_EVICTED:   n_evicted++;
            G_DISCARDED: n_discarded++;
            default: ;
        endcase

        if (t.unknown != (rc == G_UNKNOWN))
            `uvm_error("SB", $sformatf("unknown_order_ref: rtl=%0d golden=%0d after %s",
                                       t.unknown, rc == G_UNKNOWN, t.convert2string()))
        if (t.gap_seen != model_gap_seen)
            `uvm_error("SB", $sformatf("mold_gap_seen: rtl=%0d expected=%0d after %s",
                                       t.gap_seen, model_gap_seen, t.convert2string()))
        if (t.bid_count != t.bids.size() || t.ask_count != t.asks.size())
            `uvm_error("SB", $sformatf("count outputs disagree with slot valids after %s",
                                       t.convert2string()))

        check_side("bids", 0, t.bids, t);
        check_side("asks", 1, t.asks, t);
        n_checked++;
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("SB", $sformatf("checked %0d commits: %0d unknown-ref, %0d evicted, %0d discarded",
                                  n_checked, n_unknown, n_evicted, n_discarded), UVM_LOW)
        if (n_checked == 0)
            `uvm_error("SB", "no commits checked")
    endfunction
endclass


// Functional coverage, derived purely from what the monitor observed: the
// previous commit's book tells us whether a lookup hit, whether an add found
// its side full, and whether an execution was partial.
class book_coverage extends uvm_subscriber #(book_txn);
    `uvm_component_utils(book_coverage)

    typedef enum {O_INSERT, O_EVICT, O_DISCARD, O_HIT, O_MISS} outcome_e;

    // Previous commit's book: ref -> {side, qty}.
    bit        prev_side[bit [63:0]];
    bit [31:0] prev_qty[bit [63:0]];
    int        prev_count[2];

    // Sampled variables.
    bit [7:0]  typ;
    bit        side;
    bit        side_full;
    outcome_e  outcome;
    bit        full_fill;
    bit        gap_seen;

    covergroup cg;
        cp_typ: coverpoint typ {
            bins add = {T_ADD}; bins del = {T_DEL}; bins exe = {T_EXE}; bins rep = {T_REP};
        }
        cp_side: coverpoint side;
        cp_full: coverpoint side_full;

        cp_add_out: coverpoint outcome iff (typ == T_ADD) {
            bins insert = {O_INSERT}; bins evict = {O_EVICT}; bins discard = {O_DISCARD};
        }
        cp_lookup_typ: coverpoint typ iff (typ != T_ADD) {
            bins del = {T_DEL}; bins exe = {T_EXE}; bins rep = {T_REP};
        }
        cp_lookup_out: coverpoint outcome iff (typ != T_ADD) {
            bins hit = {O_HIT}; bins miss = {O_MISS};
        }
        cp_exec: coverpoint full_fill iff (typ == T_EXE && outcome == O_HIT) {
            bins partial = {0}; bins full = {1};
        }
        cp_gap: coverpoint gap_seen;

        // Every add outcome on both sides.
        x_add: cross cp_side, cp_add_out;
        // Every lookup command both hitting and missing.
        x_lookup: cross cp_lookup_typ, cp_lookup_out;
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg = new();
    endfunction

    function void write(book_txn t);
        typ      = t.typ;
        gap_seen = t.gap_seen;
        if (t.typ == T_ADD) begin
            side      = t.side;
            side_full = prev_count[side] == `BOOK_MAX;
            if (!side_full)
                outcome = O_INSERT;
            else
                outcome = present(t, t.oref) ? O_EVICT : O_DISCARD;
        end else begin
            outcome   = prev_side.exists(t.oref) ? O_HIT : O_MISS;
            side      = (outcome == O_HIT) ? prev_side[t.oref] : 0;
            side_full = prev_count[side] == `BOOK_MAX;
            full_fill = (outcome == O_HIT) && t.exe >= prev_qty[t.oref];
        end
        cg.sample();

        prev_side.delete();
        prev_qty.delete();
        foreach (t.bids[i]) begin prev_side[t.bids[i].oref] = 0; prev_qty[t.bids[i].oref] = t.bids[i].qty; end
        foreach (t.asks[i]) begin prev_side[t.asks[i].oref] = 1; prev_qty[t.asks[i].oref] = t.asks[i].qty; end
        prev_count[0] = t.bids.size();
        prev_count[1] = t.asks.size();
    endfunction

    function bit present(book_txn t, bit [63:0] r);
        foreach (t.bids[i]) if (t.bids[i].oref == r) return 1;
        foreach (t.asks[i]) if (t.asks[i].oref == r) return 1;
        return 0;
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("COV", $sformatf("functional coverage: %0.1f%%", cg.get_coverage()), UVM_LOW)
    endfunction
endclass
