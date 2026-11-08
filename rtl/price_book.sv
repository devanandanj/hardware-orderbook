/*
 *
 *   Price Book
 *   github/devanandanj
 *
 *
 */

`include "itch_defs.vh"

`default_nettype none

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
    localparam int LO_W  = COL_W / 2;
    localparam int HI_W  = COL_W - LO_W;
    localparam int LO_N  = 1 << LO_W;
    localparam int HI_N  = 1 << HI_W;

    localparam logic [3:0] S_IDLE  = 4'd0;
    localparam logic [3:0] S_CLEAR = 4'd1;
    localparam logic [3:0] S_WR    = 4'd2;
    localparam logic [3:0] S_UPD   = 4'd3;
    localparam logic [3:0] S_SCAN  = 4'd4;
    localparam logic [3:0] S_ROW   = 4'd5;
    localparam logic [3:0] S_HOLD  = 4'd6;
    localparam logic [3:0] S_PICK  = 4'd7;
    localparam logic [3:0] S_LVL   = 4'd8;
    localparam logic [3:0] S_LOAD  = 4'd9;

    function automatic logic [COL_W-1:0] pick(input logic [COLS-1:0] v);
        logic [HI_N-1:0] any;
        logic [LO_N-1:0] grp;
        logic [HI_W-1:0] hi;
        logic [LO_W-1:0] lo;
        for (int g = 0; g < HI_N; g++) any[g] = |v[g*LO_N +: LO_N];
        hi = '0;
        for (int g = 0; g < HI_N; g++)
            if (!SELL && any[g]) hi = g[HI_W-1:0];
        for (int g = HI_N - 1; g >= 0; g--)
            if (SELL && any[g]) hi = g[HI_W-1:0];
        grp = v[hi*LO_N +: LO_N];
        lo = '0;
        for (int i = 0; i < LO_N; i++)
            if (!SELL && grp[i]) lo = i[LO_W-1:0];
        for (int i = LO_N - 1; i >= 0; i--)
            if (SELL && grp[i]) lo = i[LO_W-1:0];
        pick = {hi, lo};
    endfunction

    logic [3:0] state;

    assign ready = state == S_IDLE;

    wire clearing = state == S_CLEAR;
    wire wr_ok    = wr_valid && ready;
    wire rd_ok    = rd_valid && ready;

    logic [SLOT_W-1:0] clear_slot;

    logic [SLOT_W-1:0]  p_slot;
    logic [SHARE_W-1:0] p_shares;
    logic [ORDER_W-1:0] p_orders;
    logic               p_rescan;

    wire occupied = p_orders != '0;
    wire better   = SELL ? p_slot < best_slot : p_slot > best_slot;

    logic [LEVEL_W-1:0] level [0:(1<<SLOT_W)-1];
    logic [LEVEL_W-1:0] level_q;

    wire               level_we    = clearing || state == S_WR;
    wire [SLOT_W-1:0]  level_waddr = clearing ? clear_slot : p_slot;
    wire [LEVEL_W-1:0] level_wdata = clearing ? '0 : {p_shares, p_orders};
    wire [SLOT_W-1:0]  level_raddr = state == S_LVL ? best_slot : rd_slot;

    always_ff @(posedge clk) begin
        if (level_we) level[level_waddr] <= level_wdata;
        level_q <= level[level_raddr];
    end

    assign rd_shares = level_q[LEVEL_W-1:ORDER_W];
    assign rd_orders = level_q[ORDER_W-1:0];

    logic [COLS-1:0]  occ [0:COLS-1];
    logic [COLS-1:0]  occ_q;
    logic [COLS-1:0]  occ_r;
    logic [COLS-1:0]  summary;
    logic [COL_W-1:0] scan_row;

    wire [COL_W-1:0] p_row = p_slot[SLOT_W-1:COL_W];
    wire [COL_W-1:0] p_col = p_slot[COL_W-1:0];

    logic [COLS-1:0] occ_next;
    always_comb begin
        occ_next        = occ_q;
        occ_next[p_col] = occupied;
    end

    wire             occ_we    = clearing || state == S_UPD;
    wire [COL_W-1:0] occ_waddr = clearing ? clear_slot[COL_W-1:0] : p_row;
    wire [COLS-1:0]  occ_wdata = clearing ? '0 : occ_next;
    wire [COL_W-1:0] occ_raddr = state == S_ROW ? scan_row : p_row;

    always_ff @(posedge clk) begin
        if (occ_we) occ[occ_waddr] <= occ_wdata;
        occ_q <= occ[occ_raddr];
    end

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
                    state    <= S_WR;
                    p_slot   <= wr_slot;
                    p_shares <= wr_shares;
                    p_orders <= wr_orders;
                end

                S_WR: begin
                    state    <= S_UPD;
                    p_rescan <= !occupied && best_valid && p_slot == best_slot;

                    if (occupied && (!best_valid || better || p_slot == best_slot)) begin
                        best_valid  <= 1'b1;
                        best_slot   <= p_slot;
                        best_shares <= p_shares;
                        best_orders <= p_orders;
                    end
                end

                S_UPD: begin
                    summary[p_row] <= |occ_next;
                    state          <= p_rescan ? S_SCAN : S_IDLE;
                end

                S_SCAN: begin
                    if (|summary) begin
                        scan_row <= pick(summary);
                        state    <= S_ROW;
                    end else begin
                        best_valid  <= 1'b0;
                        best_slot   <= '0;
                        best_shares <= '0;
                        best_orders <= '0;
                        state       <= S_IDLE;
                    end
                end

                S_ROW: state <= S_HOLD;

                S_HOLD: begin
                    occ_r <= occ_q;
                    state <= S_PICK;
                end

                S_PICK: begin
                    best_slot <= {scan_row, pick(occ_r)};
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
