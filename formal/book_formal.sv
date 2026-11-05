// book_formal.sv -- formal harness for rtl/book.sv.
//
// A wrapper rather than a `bind`: open-source Yosys has no bind, and a
// wrapper keeps book.sv untouched and synthesizable. Every command input
// is a free top-level input, so the solver chooses the stimulus; the only
// constraints are the feed guarantees under "assumptions".
//
// Each property compares the book one cycle after a command against the
// book one cycle before it ($past), slot by slot, so it pins down exactly
// what a command may change -- and that nothing else changes.
//
// Run at a small MAX (book.sby sets 4): the logic is identical at any size,
// and a small book lets k-induction close.

`default_nettype none

module book_formal #(
    parameter integer MAX = 4
) (
    input wire        clk,
    input wire        rst,
    input wire        cmd_valid,
    input wire [7:0]  cmd_type,
    input wire        cmd_side,
    input wire [63:0] cmd_order_ref,
    input wire [63:0] cmd_new_order_ref,
    input wire [31:0] cmd_shares,
    input wire [31:0] cmd_price,
    input wire [31:0] cmd_exec_shares,
    input wire        mold_gap
);

    localparam integer N = 2 * MAX;
    localparam [7:0] T_ADD = 8'h41, T_DEL = 8'h44, T_EXE = 8'h45, T_REP = 8'h55;

    wire              cmd_ready, commit;
    wire [7:0]        bid_count, ask_count;
    wire              book_full_bid, book_full_ask, unknown_order_ref, mold_gap_seen;
    wire [MAX-1:0]    vb, va;
    wire [64*MAX-1:0] rb, ra;
    wire [32*MAX-1:0] pb, pa, qb, qa;

    book #(.MAX(MAX)) dut (
        .clk(clk), .rst(rst),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_type(cmd_type),
        .cmd_side(cmd_side), .cmd_order_ref(cmd_order_ref),
        .cmd_new_order_ref(cmd_new_order_ref), .cmd_shares(cmd_shares),
        .cmd_price(cmd_price), .cmd_exec_shares(cmd_exec_shares),
        .mold_gap(mold_gap),
        .commit(commit), .bid_count(bid_count), .ask_count(ask_count),
        .book_full_bid(book_full_bid), .book_full_ask(book_full_ask),
        .unknown_order_ref(unknown_order_ref), .mold_gap_seen(mold_gap_seen),
        .slot_valid_bid(vb), .slot_valid_ask(va),
        .slot_ref_bid_flat(rb), .slot_ref_ask_flat(ra),
        .slot_price_bid_flat(pb), .slot_price_ask_flat(pa),
        .slot_qty_bid_flat(qb), .slot_qty_ask_flat(qa)
    );

    // Both sides as one array, as in book.sv: slot s is an ask iff s >= MAX.
    wire [N-1:0]    v = {va, vb};
    wire [64*N-1:0] r = {ra, rb};
    wire [32*N-1:0] p = {pa, pb};
    wire [32*N-1:0] q = {qa, qb};

    // ------------------------------------------------------------------
    // Queries over a book image.
    // ------------------------------------------------------------------

    function on_side;               // order `key` rests on side `sd`
        input [N-1:0]    fv;
        input [64*N-1:0] fr;
        input [63:0]     key;
        input            sd;
        integer i;
        begin
            on_side = 1'b0;
            for (i = 0; i < N; i = i + 1)
                if (fv[i] && ((i >= MAX) == sd) && fr[64*i +: 64] == key)
                    on_side = 1'b1;
        end
    endfunction

    function [31:0] field_of;       // price or qty of order `key`
        input [N-1:0]    fv;
        input [64*N-1:0] fr;
        input [32*N-1:0] ff;
        input [63:0]     key;
        integer i;
        begin
            field_of = 0;
            for (i = 0; i < N; i = i + 1)
                if (fv[i] && fr[64*i +: 64] == key)
                    field_of = ff[32*i +: 32];
        end
    endfunction

    function [7:0] count_side;
        input [N-1:0] fv;
        input         sd;
        integer i;
        begin
            count_side = 0;
            for (i = 0; i < N; i = i + 1)
                if (fv[i] && ((i >= MAX) == sd))
                    count_side = count_side + 1;
        end
    endfunction

    // Worst resting price on a side: lowest bid, highest ask.
    function [31:0] worst_price;
        input [N-1:0]    fv;
        input [32*N-1:0] fp;
        input            sd;
        integer i;
        begin
            worst_price = sd ? 32'h0 : 32'hFFFF_FFFF;
            for (i = 0; i < N; i = i + 1)
                if (fv[i] && ((i >= MAX) == sd))
                    if (sd ? fp[32*i +: 32] > worst_price
                           : fp[32*i +: 32] < worst_price)
                        worst_price = fp[32*i +: 32];
        end
    endfunction

    // Among orders at the worst price, the highest ref is the worst.
    function [63:0] worst_ref;
        input [N-1:0]    fv;
        input [64*N-1:0] fr;
        input [32*N-1:0] fp;
        input            sd;
        input [31:0]     wp;
        integer i;
        begin
            worst_ref = 0;
            for (i = 0; i < N; i = i + 1)
                if (fv[i] && ((i >= MAX) == sd) && fp[32*i +: 32] == wp
                    && fr[64*i +: 64] >= worst_ref)
                    worst_ref = fr[64*i +: 64];
        end
    endfunction

    // ------------------------------------------------------------------
    // Reset and history.
    // ------------------------------------------------------------------

    reg f_past_valid = 1'b0;
    reg f_past_rst;
    always @(posedge clk) begin
        f_past_valid <= 1'b1;
        f_past_rst   <= rst;
    end

    // Start in reset.
    always @(*) if (!f_past_valid) assume (rst);

    wire f_check = f_past_valid && !f_past_rst && !rst;

    // ------------------------------------------------------------------
    // Assumptions -- only what a valid ITCH feed guarantees.
    // ------------------------------------------------------------------

    wire present_now = on_side(v, r, cmd_order_ref, 1'b0)
                    || on_side(v, r, cmd_order_ref, 1'b1);
    wire new_present = on_side(v, r, cmd_new_order_ref, 1'b0)
                    || on_side(v, r, cmd_new_order_ref, 1'b1);

    always @(*) if (cmd_valid) begin
        assume (cmd_type == T_ADD || cmd_type == T_DEL
             || cmd_type == T_EXE || cmd_type == T_REP);
        // Order refs are unique for the life of the book.
        if (cmd_type == T_ADD) assume (!present_now);
        if (cmd_type == T_REP) assume (!new_present);
    end

    // ------------------------------------------------------------------
    // The previous cycle's command and book, named.
    // ------------------------------------------------------------------

    // Explicit history registers ($past is only legal in clocked blocks).
    reg             c_valid;
    reg [7:0]       c_type;
    reg             c_side;
    reg [63:0]      c_ref, c_new;
    reg [31:0]      c_sh, c_px, c_exe;
    reg [N-1:0]     pv;
    reg [64*N-1:0]  pr;
    reg [32*N-1:0]  pp, pq;

    always @(posedge clk) begin
        c_valid <= cmd_valid;
        c_type  <= cmd_type;
        c_side  <= cmd_side;
        c_ref   <= cmd_order_ref;
        c_new   <= cmd_new_order_ref;
        c_sh    <= cmd_shares;
        c_px    <= cmd_price;
        c_exe   <= cmd_exec_shares;
        pv      <= v;
        pr      <= r;
        pp      <= p;
        pq      <= q;
    end

    wire hit_bid = on_side(pv, pr, c_ref, 1'b0);
    wire hit_ask = on_side(pv, pr, c_ref, 1'b1);
    wire hit     = hit_bid || hit_ask;
    wire hit_sd  = hit_ask;                 // side the target rested on

    wire [31:0] wp      = worst_price(pv, pp, c_side);
    wire [63:0] wr      = worst_ref(pv, pr, pp, c_side, wp);
    wire        was_full = count_side(pv, c_side) == MAX;
    wire        better  = c_side ? (c_px < wp) : (c_px > wp);

    wire is_add   = c_valid && c_type == T_ADD;
    wire is_del   = c_valid && c_type == T_DEL;
    wire is_exe   = c_valid && c_type == T_EXE;
    wire is_rep   = c_valid && c_type == T_REP;
    wire evicting = is_add && was_full && better;
    wire inserted = is_add && (!was_full || better);

    // ------------------------------------------------------------------
    // Safety invariants -- every cycle.
    // ------------------------------------------------------------------

    always @(*) if (f_past_valid && !rst) begin
        a_bid_count:  assert (bid_count == count_side(v, 1'b0));
        a_ask_count:  assert (ask_count == count_side(v, 1'b1));
        a_bid_bound:  assert (bid_count <= MAX);
        a_ask_bound:  assert (ask_count <= MAX);
        a_full_bid:   assert (book_full_bid == (bid_count == MAX));
        a_full_ask:   assert (book_full_ask == (ask_count == MAX));
        a_ready:      assert (cmd_ready);
    end

    // ------------------------------------------------------------------
    // One-step effects of each command.
    // ------------------------------------------------------------------

    always @(posedge clk) if (f_check) begin
        a_commit: assert (commit == c_valid);
        a_gap:    assert (mold_gap_seen == ($past(mold_gap_seen) || $past(mold_gap)));

        if (c_valid)
            a_unknown: assert (unknown_order_ref == (c_type != T_ADD && !hit));

        // A: lands on its side with its price and shares, unless the side
        // was full and it does not beat the worst resting order.
        if (inserted) begin
            a_add_present: assert (on_side(v, r, c_ref, c_side));
            a_add_price:   assert (field_of(v, r, p, c_ref) == c_px);
            a_add_qty:     assert (field_of(v, r, q, c_ref) == c_sh);
        end
        if (is_add && !inserted)
            a_add_dropped: assert (!on_side(v, r, c_ref, c_side));
        // ...and an eviction removes precisely the worst order.
        if (evicting)
            a_evict_worst: assert (!on_side(v, r, wr, c_side));

        // D: the order is gone.
        if (is_del && hit)
            a_del_gone: assert (!on_side(v, r, c_ref, hit_sd));

        // E: shares reduced, or the order removed once fully filled.
        if (is_exe && hit) begin
            if (c_exe >= field_of(pv, pr, pq, c_ref))
                a_exe_gone: assert (!on_side(v, r, c_ref, hit_sd));
            else begin
                a_exe_rest: assert (on_side(v, r, c_ref, hit_sd));
                a_exe_qty:  assert (field_of(v, r, q, c_ref)
                                    == field_of(pv, pr, pq, c_ref) - c_exe);
            end
        end

        // U: the original is replaced by the new order on the SAME side,
        // whatever cmd_side said -- U carries no side.
        if (is_rep && hit) begin
            a_rep_old_gone: assert (!on_side(v, r, c_ref, 1'b0)
                                 && !on_side(v, r, c_ref, 1'b1));
            a_rep_new_in:   assert (on_side(v, r, c_new, hit_sd));
            a_rep_price:    assert (field_of(v, r, p, c_new) == c_px);
            a_rep_qty:      assert (field_of(v, r, q, c_new) == c_sh);
        end
    end

    // ------------------------------------------------------------------
    // Induction helper: no order ref rests in two slots, across both sides.
    //
    // Reachable states never violate this (the feed assumptions forbid
    // reusing a ref), but k-induction starts from an arbitrary state; without
    // this assertion it picks one with a duplicate ref, and a D then removes
    // one copy and leaves the other.
    // ------------------------------------------------------------------

    genvar di, dj;
    generate
        for (di = 0; di < N; di = di + 1) begin : g_dup_i
            for (dj = di + 1; dj < N; dj = dj + 1) begin : g_dup_j
                always @(*) if (f_past_valid && !rst)
                    assert (!(v[di] && v[dj]
                              && r[64*di +: 64] == r[64*dj +: 64]));
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // Frame conditions: nothing else changes.
    //
    // (1) Every order that was resting and is not the command's target
    //     (nor the evicted worst order) is still in the same slot,
    //     unchanged. With no command, that is every order.
    // (2) Every order resting now was either already there or is the one
    //     the command adds (A's ref, U's new ref).
    // ------------------------------------------------------------------

    genvar s;
    generate
        for (s = 0; s < N; s = s + 1) begin : g_frame
            wire [63:0] old_ref = pr[64*s +: 64];
            wire        sd      = (s >= MAX);
            wire touched = c_valid && (old_ref == c_ref
                                       || (evicting && sd == c_side && old_ref == wr));

            always @(posedge clk) if (f_check) begin
                if (pv[s] && !touched) begin
                    assert (v[s]);
                    assert (r[64*s +: 64] == old_ref);
                    assert (p[32*s +: 32] == pp[32*s +: 32]);
                    assert (q[32*s +: 32] == pq[32*s +: 32]);
                end
                if (v[s] && !(pv[s] && r[64*s +: 64] == old_ref))
                    assert (c_valid
                        && ((c_type == T_ADD && r[64*s +: 64] == c_ref)
                         || (c_type == T_REP && r[64*s +: 64] == c_new)));
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // Coverage -- each interesting state is reachable, so no assertion
    // above is vacuously true.
    // ------------------------------------------------------------------

    reg f_add_del_seen = 1'b0;     // A then D of the same ref emptied the book
    always @(posedge clk) if (f_check) begin
        c_full_bid:  cover (book_full_bid);
        c_full_ask:  cover (book_full_ask);
        c_evict:     cover (evicting);
        c_discard:   cover (is_add && !inserted);
        c_exe_part:  cover (is_exe && hit && c_exe < field_of(pv, pr, pq, c_ref));
        c_rep:       cover (is_rep && hit);
        c_unknown:   cover (unknown_order_ref);
        c_gap:       cover (mold_gap_seen);
        c_roundtrip: cover (is_del && hit && bid_count == 0 && ask_count == 0
                            && $past(bid_count) + $past(ask_count) == 1);
    end

endmodule

`default_nettype wire
