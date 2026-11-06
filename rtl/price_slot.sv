/*
 *
 *   Price to slot
 *   github/devanandanj
 *
 *
 */

`include "itch_defs.vh"

`default_nettype none

// slot = (price - base) / TICK + CENTER, as golden's PriceToSlot. Fixed
// 3-cycle latency, one request per cycle. rsp_slot means nothing unless
// rsp_ok: the price is on the tick grid and inside the slot window.
module price_slot (
    input  logic                    clk,

    input  logic [31:0]             base_price,    // session register
    input  logic                    req_valid,
    input  logic [31:0]             req_price,

    output logic                    rsp_valid,
    output logic                    rsp_ok,
    output logic [`BOOK_SLOT_W-1:0] rsp_slot
);

    localparam int TICK   = `BOOK_PRICE_TICK;
    localparam int SLOT_W = `BOOK_SLOT_W;
    localparam int D_W    = $clog2(`BOOK_SLOTS * TICK);

    // d = price - (base - CENTER*TICK) makes the window 0 <= d < SLOTS*TICK,
    // and then slot is simply d / TICK.
    localparam logic [33:0] OFFSET = `BOOK_SLOT_CENTER * TICK;
    localparam logic [33:0] WINDOW = `BOOK_SLOTS * TICK;

    // Reciprocal multiply. Exact over the window only: tb/price_slot checks
    // every value of it, so rerun that if the tick or slot count changes.
    localparam int          SHIFT = 26;
    localparam logic [19:0] RECIP = 20'((1 << SHIFT) / TICK + 1);

    wire [33:0] d = {2'b00, req_price} - {2'b00, base_price} + OFFSET;

    logic              s1_valid, s1_ok;
    logic [D_W-1:0]    s1_d;

    logic              s2_valid, s2_ok;
    logic [D_W-1:0]    s2_d;
    logic [SLOT_W-1:0] s2_q;

    wire [D_W+19:0] prod = s1_d * RECIP;

    always_ff @(posedge clk) begin
        s1_valid <= req_valid;
        s1_ok    <= !d[33] && d < WINDOW;
        s1_d     <= d[D_W-1:0];

        s2_valid <= s1_valid;
        s2_ok    <= s1_ok;
        s2_d     <= s1_d;
        s2_q     <= prod[SHIFT +: SLOT_W];

        rsp_valid <= s2_valid;
        rsp_ok    <= s2_ok && s2_d == D_W'(s2_q * TICK);
        rsp_slot  <= s2_q;
    end

endmodule

`default_nettype wire
