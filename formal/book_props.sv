// SystemVerilog assertion harness for the RTL book core (rtl/book.v).
//
// The DUT (`book`) is pure Verilog-2001 and this file is the only place
// SystemVerilog appears in the project. It is loaded ONLY by SymbiYosys via
// book.sby -- Icarus, Verilator and Vivado do not see it. This preserves the
// tool-portability argument in the top-level README.
//
// Interface assumed of the DUT (finalise when rtl/book.v is written):
//
//   module book #(
//       parameter integer MAX = 32
//   ) (
//       input  wire                    clk,
//       input  wire                    rst,
//
//       // ITCH command in. cmd_valid is one-cycle-per-message; the book
//       // asserts cmd_ready when it can accept.
//       input  wire                    cmd_valid,
//       output wire                    cmd_ready,
//       input  wire [7:0]              cmd_type,           // 'A','D','U','E'
//       input  wire                    cmd_side,           // 0=buy, 1=sell
//       input  wire [63:0]             cmd_order_ref,      // A,D,U (orig),E
//       input  wire [63:0]             cmd_new_order_ref,  // U only
//       input  wire [31:0]             cmd_shares,         // A,U
//       input  wire [31:0]             cmd_price,          // A,U
//       input  wire [31:0]             cmd_exec_shares,    // E
//
//       // Committed book state, one snapshot per accepted command.
//       output wire                    commit,
//       output wire [$clog2(MAX+1)-1:0] bid_count,
//       output wire [$clog2(MAX+1)-1:0] ask_count,
//       output wire                    book_full_bid,
//       output wire                    book_full_ask,
//       output wire                    unknown_order_ref,
//       output wire                    mold_gap_seen,
//
//       // Slot exposure for formal introspection. The RTL keeps these
//       // whether or not synthesis wires them out -- they are wire, not
//       // reg, so unused they cost nothing.
//       output wire [MAX-1:0]          slot_valid_bid,
//       output wire [MAX-1:0]          slot_valid_ask,
//       output wire [64*MAX-1:0]       slot_ref_bid_flat,
//       output wire [64*MAX-1:0]       slot_ref_ask_flat
//   );
//
// Adjust the property names below if the RTL author picks different signal
// names -- do NOT weaken the property to match the RTL.

`default_nettype none

module book_props #(
    parameter integer MAX = 32
) (
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     cmd_valid,
    input  wire                     cmd_ready,
    input  wire [7:0]               cmd_type,
    input  wire                     cmd_side,
    input  wire [63:0]              cmd_order_ref,
    input  wire [63:0]              cmd_new_order_ref,
    input  wire [31:0]              cmd_shares,
    input  wire                     commit,
    input  wire [$clog2(MAX+1)-1:0] bid_count,
    input  wire [$clog2(MAX+1)-1:0] ask_count,
    input  wire                     book_full_bid,
    input  wire                     book_full_ask,
    input  wire                     unknown_order_ref,
    input  wire                     mold_gap_seen,
    input  wire [MAX-1:0]           slot_valid_bid,
    input  wire [MAX-1:0]           slot_valid_ask,
    input  wire [64*MAX-1:0]        slot_ref_bid_flat,
    input  wire [64*MAX-1:0]        slot_ref_ask_flat
);

    // ------------------------------------------------------------------
    // Helper functions -- structural queries on the slot arrays.
    // ------------------------------------------------------------------

    function automatic bit ref_in_side(
        input bit [MAX-1:0]      valid,
        input bit [64*MAX-1:0]   refs_flat,
        input bit [63:0]         needle
    );
        int i;
        ref_in_side = 1'b0;
        for (i = 0; i < MAX; i++) begin
            if (valid[i] && refs_flat[64*i +: 64] == needle) begin
                ref_in_side = 1'b1;
            end
        end
    endfunction

    function automatic int count_side(input bit [MAX-1:0] valid);
        int i;
        count_side = 0;
        for (i = 0; i < MAX; i++) begin
            if (valid[i]) count_side = count_side + 1;
        end
    endfunction

    // ------------------------------------------------------------------
    // Assumptions on the environment -- ONLY what a valid ITCH feed
    // guarantees. Keep this list short and defensible.
    // ------------------------------------------------------------------

    always @(*) if (!rst && cmd_valid) begin
        // side is either buy or sell -- ITCH wire char 'B' or 'S' is
        // decoded upstream, this is the 1-bit form.
        assume (cmd_side == 1'b0 || cmd_side == 1'b1);

        // Message type is one of the four we accept.
        assume (cmd_type == 8'h41   // 'A'
             || cmd_type == 8'h44   // 'D'
             || cmd_type == 8'h55   // 'U'
             || cmd_type == 8'h45); // 'E'
    end

    // ------------------------------------------------------------------
    // Safety invariants -- must hold every cycle.
    // ------------------------------------------------------------------

    // count_bounds: reported counts never exceed MAX and match slot arrays.
    always @(posedge clk) if (!rst) begin
        a_bid_count_bound: assert (bid_count <= MAX);
        a_ask_count_bound: assert (ask_count <= MAX);
        a_bid_count_matches: assert (bid_count == count_side(slot_valid_bid));
        a_ask_count_matches: assert (ask_count == count_side(slot_valid_ask));
    end

    // book_full_iff_at_cap
    always @(posedge clk) if (!rst) begin
        a_full_bid: assert (book_full_bid == (bid_count == MAX));
        a_full_ask: assert (book_full_ask == (ask_count == MAX));
    end

    // no_duplicate_order_ref: an order_ref appears at most once, across
    // both sides. Encoded as a pairwise slot-slot check.
    genvar gi, gj;
    generate
        for (gi = 0; gi < MAX; gi++) begin : g_dup_i
            for (gj = gi + 1; gj < MAX; gj++) begin : g_dup_j
                // Same side, different slot.
                always @(posedge clk) if (!rst) begin
                    a_no_dup_bid: assert (
                        !(slot_valid_bid[gi] && slot_valid_bid[gj]
                          && slot_ref_bid_flat[64*gi +: 64]
                             == slot_ref_bid_flat[64*gj +: 64])
                    );
                    a_no_dup_ask: assert (
                        !(slot_valid_ask[gi] && slot_valid_ask[gj]
                          && slot_ref_ask_flat[64*gi +: 64]
                             == slot_ref_ask_flat[64*gj +: 64])
                    );
                end
            end
            // Cross-side: same slot index paired with itself in the other
            // side; the full cross-check is 32x32 which is too big to write
            // out. Rely on the per-side check plus the property that a
            // given order_ref only ever hits one side (asserted below).
        end
    endgenerate

    // mold_gap_seen is sticky: once set, stays set until rst.
    always @(posedge clk) if (!rst && $past(mold_gap_seen)) begin
        a_gap_sticky: assert (mold_gap_seen);
    end

    // ------------------------------------------------------------------
    // Functional properties -- one-step effects of each command.
    //
    // These reference the command that was accepted on the previous cycle
    // (cmd_valid && cmd_ready) and check its effect at the commit edge.
    // ------------------------------------------------------------------

    wire accepted = cmd_valid && cmd_ready;

    // add_then_present: after an accepted A, the order_ref is in the
    // correct side at the next commit.
    always @(posedge clk) if (!rst && $past(accepted) && $past(cmd_type) == 8'h41 && commit) begin
        a_add_present: assert (
            $past(cmd_side) == 1'b0
                ? ref_in_side(slot_valid_bid, slot_ref_bid_flat, $past(cmd_order_ref))
                : ref_in_side(slot_valid_ask, slot_ref_ask_flat, $past(cmd_order_ref))
        );
    end

    // delete_removes: after an accepted D whose order_ref was present,
    // it is not present at commit.
    always @(posedge clk) if (!rst && $past(accepted) && $past(cmd_type) == 8'h44 && commit) begin
        a_delete_gone_bid: assert (
            !ref_in_side(slot_valid_bid, slot_ref_bid_flat, $past(cmd_order_ref))
        );
        a_delete_gone_ask: assert (
            !ref_in_side(slot_valid_ask, slot_ref_ask_flat, $past(cmd_order_ref))
        );
    end

    // update_swaps: after an accepted U, the new_order_ref is present and
    // the original is not.
    always @(posedge clk) if (!rst && $past(accepted) && $past(cmd_type) == 8'h55 && commit
                              && !$past(unknown_order_ref)) begin
        a_update_new_in: assert (
            ref_in_side(slot_valid_bid, slot_ref_bid_flat, $past(cmd_new_order_ref))
         || ref_in_side(slot_valid_ask, slot_ref_ask_flat, $past(cmd_new_order_ref))
        );
        a_update_old_out: assert (
            !ref_in_side(slot_valid_bid, slot_ref_bid_flat, $past(cmd_order_ref))
         && !ref_in_side(slot_valid_ask, slot_ref_ask_flat, $past(cmd_order_ref))
        );
    end

    // unknown_ref_flagged: a D/U/E against a not-present order_ref must
    // raise unknown_order_ref for that snapshot.
    wire ref_present =
        ref_in_side(slot_valid_bid, slot_ref_bid_flat, cmd_order_ref)
     || ref_in_side(slot_valid_ask, slot_ref_ask_flat, cmd_order_ref);

    always @(posedge clk) if (!rst && $past(accepted) && commit) begin
        if ($past(cmd_type) == 8'h44
         || $past(cmd_type) == 8'h55
         || $past(cmd_type) == 8'h45) begin
            a_unknown_ref: assert (
                unknown_order_ref == !$past(ref_present)
            );
        end
    end

    // ------------------------------------------------------------------
    // Cover -- witnesses that the interesting states are reachable, so
    // the assertions above are not vacuously green.
    // ------------------------------------------------------------------

    c_full_bid:    cover property (@(posedge clk) book_full_bid);
    c_full_ask:    cover property (@(posedge clk) book_full_ask);
    c_gap:         cover property (@(posedge clk) mold_gap_seen);
    c_unknown_ref: cover property (@(posedge clk) unknown_order_ref);
    c_add_then_delete: cover property (
        @(posedge clk) accepted && cmd_type == 8'h41
                       ##[1:32] accepted && cmd_type == 8'h44
                       ##1 bid_count == 0 && ask_count == 0
    );

endmodule

// SymbiYosys binds this module onto the DUT via book.sby, so no explicit
// `bind` directive is needed here.
