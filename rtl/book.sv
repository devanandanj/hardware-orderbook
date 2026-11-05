/*
 *
 *
 *
 *
 *
 */

`default_nettype none

module book #(
    parameter int MAX = 64          // per side; power of two, <= 128
) (
    input  logic              clk,
    input  logic              rst,

    input  logic              cmd_valid,
    output logic              cmd_ready,
    input  logic [7:0]        cmd_type,              // 'A','D','U','E'
    input  logic              cmd_side,              // A only: 0=buy, 1=sell
    input  logic [63:0]       cmd_order_ref,         // A,D,E; U: original
    input  logic [63:0]       cmd_new_order_ref,     // U
    input  logic [31:0]       cmd_shares,            // A,U
    input  logic [31:0]       cmd_price,             // A,U
    input  logic [31:0]       cmd_exec_shares,       // E

    input  logic              mold_gap,              // pulse from the de-framer

    output logic              commit,
    output logic [7:0]        bid_count,             // one byte, as in the snapshot
    output logic [7:0]        ask_count,
    output logic              book_full_bid,
    output logic              book_full_ask,
    output logic              unknown_order_ref,
    output logic              mold_gap_seen,

    output logic [MAX-1:0]    slot_valid_bid,
    output logic [MAX-1:0]    slot_valid_ask,
    output logic [64*MAX-1:0] slot_ref_bid_flat,
    output logic [64*MAX-1:0] slot_ref_ask_flat,
    output logic [32*MAX-1:0] slot_price_bid_flat,
    output logic [32*MAX-1:0] slot_price_ask_flat,
    output logic [32*MAX-1:0] slot_qty_bid_flat,
    output logic [32*MAX-1:0] slot_qty_ask_flat
);

    localparam int IW = $clog2(MAX);          // slot index within a side
    localparam int N  = 2 * MAX;

    localparam logic [7:0] T_ADD = 8'h41, T_DEL = 8'h44, T_EXE = 8'h45, T_REP = 8'h55;

    logic [N-1:0] valid;
    logic [63:0]  oref  [0:N-1];
    logic [31:0]  price [0:N-1];
    logic [31:0]  qty   [0:N-1];

    // Always ready: every command completes in one cycle.
    assign cmd_ready = 1'b1;

    // ---------------------------------------------------------------
    // Lookup: broadcast compare of cmd_order_ref against every slot.
    // Lowest index wins, so a bid hit beats an ask hit -- the same
    // search order as the golden model's FindOrder.
    // ---------------------------------------------------------------
    logic [N-1:0]    hit_vec;
    logic            hit;
    logic [IW:0]     hit_idx;

    always_comb begin
        hit_idx = 0;
        for (int i = N - 1; i >= 0; i--) begin
            hit_vec[i] = valid[i] && (oref[i] == cmd_order_ref);
            if (hit_vec[i]) hit_idx = i;
        end
        hit = |hit_vec;
    end

    // ---------------------------------------------------------------
    // Add target: lowest free slot on cmd_side, or the worst resting
    // order when that side is full.
    // ---------------------------------------------------------------
    wire [MAX-1:0] side_valid = cmd_side ? valid[N-1:MAX] : valid[MAX-1:0];
    wire           side_full  = &side_valid;

    logic [IW-1:0] free_idx;
    always_comb begin
        free_idx = 0;
        for (int i = MAX - 1; i >= 0; i--)
            if (!side_valid[i]) free_idx = i;
    end

    // Worst-order tournament tree over the full side, heap layout: node k
    // has children 2k, 2k+1; leaves are MAX..2*MAX-1. Only consulted when
    // the side is full, so no valid masking is needed.
    // Worse = further from the touch (lower bid / higher ask); a price tie
    // goes to the higher ref, matching FindWorstIndex.
    // ponytail: one-cycle log2(MAX)-deep compare tree; pipeline it across
    // the ~30 idle cycles per message if it fails timing.
    wire [31:0]   t_price [1:N-1];
    wire [63:0]   t_ref   [1:N-1];
    wire [IW-1:0] t_idx   [1:N-1];

    genvar k;
    generate
        for (k = MAX; k < N; k = k + 1) begin : g_leaf
            wire [IW:0] s = cmd_side ? k : k - MAX;  // slot in the shared array
            assign t_price[k] = price[s];
            assign t_ref[k]   = oref[s];
            assign t_idx[k]   = k - MAX;
        end
        for (k = MAX - 1; k >= 1; k = k - 1) begin : g_node
            wire lp_lo = t_price[2*k] < t_price[2*k+1];
            wire lp_eq = t_price[2*k] == t_price[2*k+1];
            wire l_worse = lp_eq ? (t_ref[2*k] > t_ref[2*k+1])
                                 : (cmd_side ? !lp_lo : lp_lo);
            assign t_price[k] = l_worse ? t_price[2*k] : t_price[2*k+1];
            assign t_ref[k]   = l_worse ? t_ref[2*k]   : t_ref[2*k+1];
            assign t_idx[k]   = l_worse ? t_idx[2*k]   : t_idx[2*k+1];
        end
    endgenerate

    // Strictly better than the worst; a tie keeps the resting order.
    wire beats_worst = cmd_side ? (cmd_price < t_price[1])
                                : (cmd_price > t_price[1]);

    wire [IW:0] add_idx = {cmd_side, side_full ? t_idx[1] : free_idx};
    wire        add_do  = !side_full || beats_worst;

    // ---------------------------------------------------------------
    // Apply.
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            valid             <= 0;
            commit            <= 1'b0;
            unknown_order_ref <= 1'b0;
            mold_gap_seen     <= 1'b0;
        end else begin
            commit <= cmd_valid;
            if (mold_gap) mold_gap_seen <= 1'b1;

            if (cmd_valid) begin
                unknown_order_ref <= (cmd_type != T_ADD) && !hit;
                case (cmd_type)
                    T_ADD: if (add_do) begin
                        valid[add_idx] <= 1'b1;
                        oref[add_idx]  <= cmd_order_ref;
                        price[add_idx] <= cmd_price;
                        qty[add_idx]   <= cmd_shares;
                    end
                    T_DEL: if (hit) valid[hit_idx] <= 1'b0;
                    T_EXE: if (hit) begin
                        if (cmd_exec_shares >= qty[hit_idx])
                            valid[hit_idx] <= 1'b0;
                        else
                            qty[hit_idx] <= qty[hit_idx] - cmd_exec_shares;
                    end
                    T_REP: if (hit) begin
                        oref[hit_idx]  <= cmd_new_order_ref;
                        price[hit_idx] <= cmd_price;
                        qty[hit_idx]   <= cmd_shares;
                    end
                    default: ;
                endcase
            end
        end
    end

    // ---------------------------------------------------------------
    // Counts are popcounts of the valid bits, so they cannot drift.
    // ---------------------------------------------------------------
    always_comb begin
        bid_count = 0;
        ask_count = 0;
        for (int i = 0; i < MAX; i++) begin
            bid_count = bid_count + valid[i];
            ask_count = ask_count + valid[MAX + i];
        end
    end

    assign book_full_bid = &valid[MAX-1:0];
    assign book_full_ask = &valid[N-1:MAX];

    assign slot_valid_bid = valid[MAX-1:0];
    assign slot_valid_ask = valid[N-1:MAX];

    generate
        for (k = 0; k < MAX; k = k + 1) begin : g_flat
            assign slot_ref_bid_flat  [64*k +: 64] = oref[k];
            assign slot_ref_ask_flat  [64*k +: 64] = oref[MAX + k];
            assign slot_price_bid_flat[32*k +: 32] = price[k];
            assign slot_price_ask_flat[32*k +: 32] = price[MAX + k];
            assign slot_qty_bid_flat  [32*k +: 32] = qty[k];
            assign slot_qty_ask_flat  [32*k +: 32] = qty[MAX + k];
        end
    endgenerate

endmodule

`default_nettype wire
