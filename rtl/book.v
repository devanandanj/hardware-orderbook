// book.v -- ITCH book reconstruction core.
//
// Holds up to MAX resting orders per side and applies one decoded ITCH
// command per cycle: a command accepted on cycle t is reflected in the
// slot state, counts and status on cycle t+1, when `commit` pulses.
// Semantics mirror golden/src/orderbook.cpp:
//
//   A  insert into a free slot; on a full side, overwrite the worst
//      resting order if the incoming price is strictly better, else drop.
//   D  free the slot holding order_ref.
//   E  reduce shares; free the slot if executed >= resting.
//   U  overwrite the original's slot with new ref/price/shares. The side
//      is the original's -- U carries none -- and freeing then re-adding
//      on the same side can never hit a full book, so in-place is exact.
//
// Order refs are assumed unique across the book (an ITCH feed guarantee).
//
// Storage is flops, both sides in one array: slot i is a bid for i < MAX,
// an ask for i >= MAX. Every lookup is a 2*MAX-wide parallel compare.
//
// Pure Verilog-2001.

`default_nettype none

module book #(
    parameter integer MAX = 64          // per side; power of two, <= 128
) (
    input  wire                 clk,
    input  wire                 rst,

    input  wire                 cmd_valid,
    output wire                 cmd_ready,
    input  wire [7:0]           cmd_type,          // 'A','D','U','E'
    input  wire                 cmd_side,          // A only: 0=buy, 1=sell
    input  wire [63:0]          cmd_order_ref,     // A,D,E; U: original
    input  wire [63:0]          cmd_new_order_ref, // U
    input  wire [31:0]          cmd_shares,        // A,U
    input  wire [31:0]          cmd_price,         // A,U
    input  wire [31:0]          cmd_exec_shares,   // E

    input  wire                 mold_gap,          // pulse from the de-framer

    output reg                  commit,
    output reg  [7:0]           bid_count,         // one byte, as in the snapshot
    output reg  [7:0]           ask_count,
    output wire                 book_full_bid,
    output wire                 book_full_ask,
    output reg                  unknown_order_ref,
    output reg                  mold_gap_seen,

    output wire [MAX-1:0]       slot_valid_bid,
    output wire [MAX-1:0]       slot_valid_ask,
    output wire [64*MAX-1:0]    slot_ref_bid_flat,
    output wire [64*MAX-1:0]    slot_ref_ask_flat,
    output wire [32*MAX-1:0]    slot_price_bid_flat,
    output wire [32*MAX-1:0]    slot_price_ask_flat,
    output wire [32*MAX-1:0]    slot_qty_bid_flat,
    output wire [32*MAX-1:0]    slot_qty_ask_flat
);

    // $clog2 is Verilog-2005; XST-safe stand-in.
    function integer clog2;
        input integer v;
        begin
            clog2 = 0;
            while ((1 << clog2) < v) clog2 = clog2 + 1;
        end
    endfunction

    localparam integer IW = clog2(MAX);       // slot index within a side
    localparam integer N  = 2 * MAX;

    localparam [7:0] T_ADD = 8'h41, T_DEL = 8'h44, T_EXE = 8'h45, T_REP = 8'h55;

    reg [N-1:0] valid;
    reg [63:0]  oref  [0:N-1];
    reg [31:0]  price [0:N-1];
    reg [31:0]  qty   [0:N-1];

    // Always ready: every command completes in one cycle.
    assign cmd_ready = 1'b1;

    // ---------------------------------------------------------------
    // Lookup: broadcast compare of cmd_order_ref against every slot.
    // Lowest index wins, so a bid hit beats an ask hit -- the same
    // search order as the golden model's FindOrder.
    // ---------------------------------------------------------------
    reg [N-1:0]      hit_vec;
    reg              hit;
    reg [IW:0]       hit_idx;
    integer i;

    always @(*) begin
        hit_idx = 0;
        for (i = N - 1; i >= 0; i = i - 1) begin
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

    reg [IW-1:0] free_idx;
    always @(*) begin
        free_idx = 0;
        for (i = MAX - 1; i >= 0; i = i - 1)
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
    always @(posedge clk) begin
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
    always @(*) begin
        bid_count = 0;
        ask_count = 0;
        for (i = 0; i < MAX; i = i + 1) begin
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
