/*
 *
 *   Price Book
 *   github/devanandanj
 *
 *
 */

`include "itch_defs.vh"

`default_nettype none

// One side's price levels and its best occupied slot: highest for bids,
// lowest for asks. Semantics follow golden's PriceBookNoteWrite. The book
// FSM owns the arithmetic: it reads a level, then writes the new value.
//
// One operation at a time, and only while ready is high. A read responds
// on the next cycle. After a write, ready drops until occupancy and the
// best level are up to date, and best_* is valid again when it returns.
module price_book #(
    parameter bit SELL = 0
) (
    input  logic                    clk,
    input  logic                    rst,
    output logic                    ready,

    input  logic                    rd_valid,
    input  logic [`BOOK_SLOT_W-1:0] rd_slot,
    output logic                    rd_rsp_valid,
    output logic [31:0]             rd_shares,
    output logic [15:0]             rd_orders,

    input  logic                    wr_valid,
    input  logic [`BOOK_SLOT_W-1:0] wr_slot,
    input  logic [31:0]             wr_shares,
    input  logic [15:0]             wr_orders,

    output logic                    best_valid,
    output logic [`BOOK_SLOT_W-1:0] best_slot,
    output logic [31:0]             best_shares,
    output logic [15:0]             best_orders
);

    localparam int SLOT_W  = `BOOK_SLOT_W;
    localparam int SHARE_W = `BOOK_LEVEL_SHARES_W;
    localparam int ORDER_W = `BOOK_LEVEL_ORDERS_W;
    localparam int LEVEL_W = SHARE_W + ORDER_W;

    // Occupancy is a square bitmap, COLS slots per row, with one summary bit
    // per row. shortcut: assumes SLOT_W is even, revisit if slot_width is odd.
    localparam int COL_W = SLOT_W / 2;
    localparam int COLS  = 1 << COL_W;

    localparam logic [2:0] S_IDLE  = 3'd0;
    localparam logic [2:0] S_CLEAR = 3'd1;
    localparam logic [2:0] S_UPD   = 3'd2;
    localparam logic [2:0] S_SCAN  = 3'd3;
    localparam logic [2:0] S_PICK  = 3'd4;
    localparam logic [2:0] S_LVL   = 3'd5;
    localparam logic [2:0] S_LOAD  = 3'd6;

    // The most competitive set bit: highest for bids, lowest for asks.
    function automatic logic [COL_W-1:0] pick(input logic [COLS-1:0] v);
        pick = '0;
        for (int i = 0; i < COLS; i++)
            if (!SELL && v[i]) pick = i[COL_W-1:0];
        for (int i = COLS - 1; i >= 0; i--)
            if (SELL && v[i]) pick = i[COL_W-1:0];
    endfunction

    logic [2:0] state;

    assign ready = state == S_IDLE;

    wire clearing = state == S_CLEAR;
    wire wr_ok    = wr_valid && ready;
    wire rd_ok    = rd_valid && ready;
    wire occupied = wr_orders != '0;

    wire better = SELL ? wr_slot < best_slot : wr_slot > best_slot;

    logic [SLOT_W-1:0] clear_slot;

    // Write latched for the occupancy update.
    logic [SLOT_W-1:0] p_slot;
    logic              p_occupied;
    logic              p_rescan;

    // ---------------------------------------------------------------
    // Levels. Plain vector memory, one read and one write port.
    // ---------------------------------------------------------------
    logic [LEVEL_W-1:0] level [0:(1<<SLOT_W)-1];
    logic [LEVEL_W-1:0] level_q;

    wire               level_we    = clearing || wr_ok;
    wire [SLOT_W-1:0]  level_waddr = clearing ? clear_slot : wr_slot;
    wire [LEVEL_W-1:0] level_wdata = clearing ? '0 : {wr_shares, wr_orders};
    wire [SLOT_W-1:0]  level_raddr = state == S_LVL ? best_slot : rd_slot;

    always_ff @(posedge clk) begin
        if (level_we) level[level_waddr] <= level_wdata;
        level_q <= level[level_raddr];
    end

    assign rd_shares = level_q[LEVEL_W-1:ORDER_W];
    assign rd_orders = level_q[ORDER_W-1:0];

    // ---------------------------------------------------------------
    // Occupancy bitmap.
    // ---------------------------------------------------------------
    logic [COLS-1:0]  occ [0:COLS-1];
    logic [COLS-1:0]  occ_q;
    logic [COLS-1:0]  summary;
    logic [COL_W-1:0] scan_row;

    wire [COL_W-1:0] p_row = p_slot[SLOT_W-1:COL_W];
    wire [COL_W-1:0] p_col = p_slot[COL_W-1:0];

    logic [COLS-1:0] occ_next;
    always_comb begin
        occ_next        = occ_q;
        occ_next[p_col] = p_occupied;
    end

    wire             occ_we    = clearing || state == S_UPD;
    wire [COL_W-1:0] occ_waddr = clearing ? clear_slot[COL_W-1:0] : p_row;
    wire [COLS-1:0]  occ_wdata = clearing ? '0 : occ_next;
    wire [COL_W-1:0] occ_raddr = state == S_SCAN ? pick(summary)
                                                 : wr_slot[SLOT_W-1:COL_W];

    always_ff @(posedge clk) begin
        if (occ_we) occ[occ_waddr] <= occ_wdata;
        occ_q <= occ[occ_raddr];
    end

    // ---------------------------------------------------------------
    // Control. Golden walks away from the old best to find the next one,
    // but nothing occupied lies beyond the best slot, so the most competitive
    // occupied slot overall is the same answer.
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= S_CLEAR;
            clear_slot   <= '0;
            summary      <= '0;
            rd_rsp_valid <= 1'b0;
            best_valid   <= 1'b0;
            best_slot    <= '0;
            best_shares  <= '0;
            best_orders  <= '0;
        end else begin
            rd_rsp_valid <= rd_ok;

            case (state)
                S_CLEAR: begin
                    clear_slot <= clear_slot + 1'b1;
                    if (&clear_slot) state <= S_IDLE;
                end

                S_IDLE: if (wr_ok) begin
                    state      <= S_UPD;
                    p_slot     <= wr_slot;
                    p_occupied <= occupied;
                    p_rescan   <= !occupied && best_valid && wr_slot == best_slot;

                    if (occupied && (!best_valid || better || wr_slot == best_slot)) begin
                        best_valid  <= 1'b1;
                        best_slot   <= wr_slot;
                        best_shares <= wr_shares;
                        best_orders <= wr_orders;
                    end
                end

                S_UPD: begin
                    summary[p_row] <= |occ_next;
                    state          <= p_rescan ? S_SCAN : S_IDLE;
                end

                S_SCAN: begin
                    if (|summary) begin
                        scan_row <= pick(summary);
                        state    <= S_PICK;
                    end else begin
                        best_valid  <= 1'b0;
                        best_slot   <= '0;
                        best_shares <= '0;
                        best_orders <= '0;
                        state       <= S_IDLE;
                    end
                end

                S_PICK: begin
                    best_slot <= {scan_row, pick(occ_q)};
                    state     <= S_LVL;
                end

                S_LVL: state <= S_LOAD;

                S_LOAD: begin
                    best_shares <= level_q[LEVEL_W-1:ORDER_W];
                    best_orders <= level_q[ORDER_W-1:0];
                    state       <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
