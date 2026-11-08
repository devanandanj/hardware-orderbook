/*
 *
 *   Book
 *   github/devanandanj
 *
 *
 */

`include "book_pkg.sv"

`default_nettype none

// Applies one book command at a time to the order table and the two price
// books, as golden's ApplyCommand:
//   A/F      insert: price check, then a free slot, then entry and level
//   E/C/X    reduce by shares; reducing to zero or below removes the order
//   D        remove
//   U        remove the old order, then insert the new ORN on its side
//   other    nothing, status 0
// done pulses once per accepted command, after both price books have
// settled, so the status bits and the BBO are valid with it.
module book (
    input logic        clk,
    input logic        rst,
    input logic [31:0] base_price, // session register

    output logic        cmd_ready,
    input  logic        cmd_valid,
    input  logic [ 7:0] cmd_type,     // ITCH message type
    input  logic        cmd_side,     // 1 = sell, A/F only
    input  logic [63:0] cmd_orn,
    input  logic [63:0] cmd_new_orn,  // U only
    input  logic [31:0] cmd_shares,
    input  logic [31:0] cmd_price,

    output logic done,
    output logic order_dropped,
    output logic price_rejected,
    output logic unknown_order_ref,

    output logic                    bid_valid,
    output logic [`BOOK_SLOT_W-1:0] bid_slot,
    output logic [            31:0] bid_shares,
    output logic [            15:0] bid_orders,
    output logic                    ask_valid,
    output logic [`BOOK_SLOT_W-1:0] ask_slot,
    output logic [            31:0] ask_shares,
    output logic [            15:0] ask_orders
);

  localparam int SLOT_W = `BOOK_SLOT_W;
  localparam int HASH_W = `BOOK_HASH_W;

  localparam logic [3:0] S_INIT   = 4'd0;
  localparam logic [3:0] S_IDLE   = 4'd1;
  localparam logic [3:0] S_LOOK   = 4'd2;   // wait for the table lookup
  localparam logic [3:0] S_REM_RD = 4'd3;   // read the order's level
  localparam logic [3:0] S_REM_WR = 4'd4;   // write entry and level
  localparam logic [3:0] S_LOOK2  = 4'd5;   // U: look up the new ORN
  localparam logic [3:0] S_INS    = 4'd6;   // check price and room, read level
  localparam logic [3:0] S_INS_WR = 4'd7;   // write entry and level
  localparam logic [3:0] S_SETTLE = 4'd8;   // wait for both price books

  logic [3:0] state;

  // Latched command. c_side is the insert side: the command's for A/F,
  // the removed order's for U.
  logic [7:0] c_type;
  logic       c_side;
  logic [63:0] c_orn, c_new_orn;
  logic [31:0] c_shares;
  logic phase2;  // U's insert half

  wire is_insert = c_type == "A" || c_type == "F" || phase2;

  wire accept = cmd_valid && cmd_ready;
  wire is_book = cmd_type == "A" || cmd_type == "F" || cmd_type == "E" ||
                   cmd_type == "C" || cmd_type == "X" || cmd_type == "D" ||
                   cmd_type == "U";

  assign cmd_ready = state == S_IDLE;

  // ---------------------------------------------------------------
  // Order table
  // ---------------------------------------------------------------
  logic ot_ready, ot_rsp_valid;
  logic [HASH_W-1:0] ot_rsp_set;
  logic ot_rsp_hit, ot_rsp_hit_cam, ot_rsp_free, ot_rsp_free_cam;
  logic [3:0] ot_rsp_hit_idx, ot_rsp_free_idx;
  book_pkg::entry_t        ot_rsp_hit_entry;

  wire                     ot_req_valid = (accept && is_book) || state == S_LOOK2;
  wire              [63:0] ot_req_orn = state == S_LOOK2 ? c_new_orn : cmd_orn;

  // The one table write port; tb/book taps tw_* and lw_*.
  logic tw_valid, tw_cam;
  logic             [HASH_W-1:0] tw_set;
  logic             [       3:0] tw_idx;
  book_pkg::entry_t              tw_entry;

  order_table u_ot (
      .clk          (clk),
      .rst          (rst),
      .ready        (ot_ready),
      .req_valid    (ot_req_valid),
      .req_orn      (ot_req_orn),
      .rsp_valid    (ot_rsp_valid),
      .rsp_set      (ot_rsp_set),
      .rsp_hit      (ot_rsp_hit),
      .rsp_hit_cam  (ot_rsp_hit_cam),
      .rsp_hit_idx  (ot_rsp_hit_idx),
      .rsp_hit_entry(ot_rsp_hit_entry),
      .rsp_free     (ot_rsp_free),
      .rsp_free_cam (ot_rsp_free_cam),
      .rsp_free_idx (ot_rsp_free_idx),
      .wr_valid     (tw_valid),
      .wr_cam       (tw_cam),
      .wr_set       (tw_set),
      .wr_idx       (tw_idx),
      .wr_entry     (tw_entry)
  );

  // Last lookup, held for the states after S_LOOK.
  logic [HASH_W-1:0] lk_set;
  logic lk_hit_cam, lk_free, lk_free_cam;
  logic [3:0] lk_hit_idx, lk_free_idx;
  book_pkg::entry_t lk_entry;

  always_ff @(posedge clk) begin
    if (ot_rsp_valid) begin
      lk_set      <= ot_rsp_set;
      lk_hit_cam  <= ot_rsp_hit_cam;
      lk_hit_idx  <= ot_rsp_hit_idx;
      lk_entry    <= ot_rsp_hit_entry;
      lk_free     <= ot_rsp_free;
      lk_free_cam <= ot_rsp_free_cam;
      lk_free_idx <= ot_rsp_free_idx;
    end
  end

  // ---------------------------------------------------------------
  // Price to slot, started at accept for every command; only inserts
  // use the answer. One request in flight at most.
  // ---------------------------------------------------------------
  logic ps_rsp_valid, ps_rsp_ok;
  logic [SLOT_W-1:0] ps_rsp_slot;
  logic ps_pending, sl_ok;
  logic [SLOT_W-1:0] sl_slot;

  price_slot u_ps (
      .clk       (clk),
      .base_price(base_price),
      .req_valid (accept),
      .req_price (cmd_price),
      .rsp_valid (ps_rsp_valid),
      .rsp_ok    (ps_rsp_ok),
      .rsp_slot  (ps_rsp_slot)
  );

  always_ff @(posedge clk) begin
    if (rst) ps_pending <= 1'b0;
    else if (accept) ps_pending <= 1'b1;
    else if (ps_rsp_valid) ps_pending <= 1'b0;

    if (ps_rsp_valid) begin
      sl_ok   <= ps_rsp_ok;
      sl_slot <= ps_rsp_slot;
    end
  end

  // ---------------------------------------------------------------
  // Price books. One level read and one level write at a time, shared
  // by both sides (side 1 = ask).
  // ---------------------------------------------------------------
  logic rd_go, rd_side;
  logic [SLOT_W-1:0] rd_slot;
  logic lw_valid, lw_side;
  logic [SLOT_W-1:0] lw_slot;
  logic [      31:0] lw_shares;
  logic [      15:0] lw_orders;

  logic bid_ready, ask_ready;
  logic [31:0] bid_rd_shares, ask_rd_shares;
  logic [15:0] bid_rd_orders, ask_rd_orders;

  price_book #(
      .SELL(1'b0)
  ) u_bid (
      .clk         (clk),
      .rst         (rst),
      .ready       (bid_ready),
      .rd_valid    (rd_go && !rd_side),
      .rd_slot     (rd_slot),
      .rd_rsp_valid(),
      .rd_shares   (bid_rd_shares),
      .rd_orders   (bid_rd_orders),
      .wr_valid    (lw_valid && !lw_side),
      .wr_slot     (lw_slot),
      .wr_shares   (lw_shares),
      .wr_orders   (lw_orders),
      .best_valid  (bid_valid),
      .best_slot   (bid_slot),
      .best_shares (bid_shares),
      .best_orders (bid_orders)
  );

  price_book #(
      .SELL(1'b1)
  ) u_ask (
      .clk         (clk),
      .rst         (rst),
      .ready       (ask_ready),
      .rd_valid    (rd_go && rd_side),
      .rd_slot     (rd_slot),
      .rd_rsp_valid(),
      .rd_shares   (ask_rd_shares),
      .rd_orders   (ask_rd_orders),
      .wr_valid    (lw_valid && lw_side),
      .wr_slot     (lw_slot),
      .wr_shares   (lw_shares),
      .wr_orders   (lw_orders),
      .best_valid  (ask_valid),
      .best_slot   (ask_slot),
      .best_shares (ask_shares),
      .best_orders (ask_orders)
  );

  // In S_REM_WR / S_INS_WR this is the read issued the cycle before.
  wire [31:0] lvl_shares = lw_side ? ask_rd_shares : bid_rd_shares;
  wire [15:0] lvl_orders = lw_side ? ask_rd_orders : bid_rd_orders;

  // ---------------------------------------------------------------
  // Datapath: what each state presents to the memories.
  // ---------------------------------------------------------------
  // U carries the new order's shares, not an amount to take off.
  wire        full_remove = c_type == "D" || c_type == "U" || c_shares >= lk_entry.shares;
  wire        rem_ready = lk_entry.side ? ask_ready : bid_ready;
  wire        ins_ready = c_side ? ask_ready : bid_ready;
  wire        ins_go = state == S_INS && !ps_pending && sl_ok && lk_free && ins_ready;

  always_comb begin
    rd_go   = 1'b0;
    rd_side = c_side;
    rd_slot = sl_slot;
    if (state == S_REM_RD) begin
      rd_go   = rem_ready;
      rd_side = lk_entry.side;
      rd_slot = lk_entry.slot;
    end else if (ins_go) begin
      rd_go = 1'b1;
    end

    tw_valid  = 1'b0;
    tw_cam    = lk_hit_cam;
    tw_set    = lk_set;
    tw_idx    = lk_hit_idx;
    tw_entry  = '0;
    lw_valid  = 1'b0;
    lw_side   = c_side;
    lw_slot   = sl_slot;
    lw_shares = lvl_shares + c_shares;
    lw_orders = lvl_orders + 16'd1;

    if (state == S_REM_WR) begin
      tw_valid = 1'b1;
      if (!full_remove) begin
        tw_entry        = lk_entry;
        tw_entry.shares = lk_entry.shares - c_shares;
      end
      lw_valid  = 1'b1;
      lw_side   = lk_entry.side;
      lw_slot   = lk_entry.slot;
      lw_shares = lvl_shares - (full_remove ? lk_entry.shares : c_shares);
      lw_orders = lvl_orders - {15'd0, full_remove};
    end else if (state == S_INS_WR) begin
      tw_valid        = 1'b1;
      tw_cam          = lk_free_cam;
      tw_idx          = lk_free_idx;
      tw_entry.valid  = 1'b1;
      tw_entry.orn    = phase2 ? c_new_orn : c_orn;
      tw_entry.side   = c_side;
      tw_entry.slot   = sl_slot;
      tw_entry.shares = c_shares;
      lw_valid        = 1'b1;
    end
  end

  // ---------------------------------------------------------------
  // Control
  // ---------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      state             <= S_INIT;
      done              <= 1'b0;
      order_dropped     <= 1'b0;
      price_rejected    <= 1'b0;
      unknown_order_ref <= 1'b0;
    end else begin
      done <= 1'b0;

      case (state)
        S_INIT: if (ot_ready && bid_ready && ask_ready) state <= S_IDLE;

        S_IDLE:
        if (accept) begin
          c_type            <= cmd_type;
          c_side            <= cmd_side;
          c_orn             <= cmd_orn;
          c_new_orn         <= cmd_new_orn;
          c_shares          <= cmd_shares;
          phase2            <= 1'b0;
          order_dropped     <= 1'b0;
          price_rejected    <= 1'b0;
          unknown_order_ref <= 1'b0;
          state             <= is_book ? S_LOOK : S_SETTLE;
        end

        S_LOOK:
        if (ot_rsp_valid) begin
          if (is_insert) state <= S_INS;
          else if (ot_rsp_hit) state <= S_REM_RD;
          else begin
            unknown_order_ref <= 1'b1;
            state             <= S_SETTLE;
          end
        end

        S_REM_RD: if (rd_go) state <= S_REM_WR;

        S_REM_WR: begin
          c_side <= lk_entry.side;
          state  <= c_type == "U" ? S_LOOK2 : S_SETTLE;
        end

        // The remove's table write landed last cycle, so this
        // lookup sees it.
        S_LOOK2: begin
          phase2 <= 1'b1;
          state  <= S_LOOK;
        end

        // Price first, then room, as golden's InsertOrder.
        S_INS:
        if (!ps_pending) begin
          if (!sl_ok) begin
            price_rejected <= 1'b1;
            state          <= S_SETTLE;
          end else if (!lk_free) begin
            order_dropped <= 1'b1;
            state         <= S_SETTLE;
          end else if (ins_go) begin
            state <= S_INS_WR;
          end
        end

        S_INS_WR: state <= S_SETTLE;

        // Also wait out the price lookup, so its answer can never
        // land in the next command.
        S_SETTLE:
        if (bid_ready && ask_ready && !ps_pending) begin
          done  <= 1'b1;
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

`ifdef FORMAL
    // ---------------------------------------------------------------
    // Properties, proved by formal/ at a small geometry. Here rather than
    // in the wrapper because they need internal signals, which Yosys
    // cannot reach from outside. sv2v, ISE and Verilator never see this.
    // ---------------------------------------------------------------
    logic [2:0] f_age = '0;           // cycles since start, saturating
    logic       f_ot1, f_ot2;         // table lookup 1 and 2 edges ago
    logic       f_ps1, f_ps2, f_ps3;  // price_slot request 1..3 edges ago
    logic       f_busy;               // accepted, done not yet seen
    logic [5:0] f_cycles;             // since accept
    logic       f_had_bid = 1'b0;     // the bid side has been occupied
    logic       f_wrote;              // this command has written a level
    logic [4:0] f_lw_age;             // cycles since the last level write
    logic       f_lw_side;            // and the side it went to

    always_ff @(posedge clk) begin
        if (f_age != 3'd7) f_age <= f_age + 3'd1;
        f_ot1 <= ot_req_valid && ot_ready && !rst;
        f_ot2 <= f_ot1 && !rst;
        f_ps1 <= accept;
        f_ps2 <= f_ps1;
        f_ps3 <= f_ps2;
        if (rst || done) f_busy <= 1'b0;
        if (accept && !rst) f_busy <= 1'b1;
        if (bid_valid && f_age != 3'd0) f_had_bid <= 1'b1;
        if (accept)        f_wrote <= 1'b0;
        else if (lw_valid) f_wrote <= 1'b1;
        f_lw_age <= lw_valid ? 5'd1 : f_lw_age + {4'd0, f_lw_age != 5'd31};
        if (lw_valid) f_lw_side <= lw_side;
        f_cycles <= accept ? 6'd1 : f_cycles + {5'd0, f_busy && f_cycles != 6'd63};
    end

    // Cycles a message takes to arrive, one byte a clock with its 2-byte
    // Mold length; the book must be done within it (tb/book's Budget).
    function automatic logic [5:0] budget(input logic [7:0] t);
        case (t)
            "A": budget = 6'd38;
            "F": budget = 6'd42;
            "E": budget = 6'd33;
            "C": budget = 6'd38;
            "X": budget = 6'd25;
            "D": budget = 6'd21;
            "U": budget = 6'd37;
            default: budget = 6'd8;
        endcase
    endfunction

    wire f_run    = f_age != 3'd0;  // past the reset cycle
    wire f_pipe   = f_age > 3'd3;   // and past the unreset pipelines
    wire f_active = state != S_IDLE && state != S_INIT;
    wire f_add    = c_type == "A" || c_type == "F";
    wire f_rem    = c_type == "E" || c_type == "C" || c_type == "X" ||
                    c_type == "D" || c_type == "U";

    always_comb begin
        // Reset is applied once, at the start.
        assume (rst == (f_age == 3'd0));

        if (f_pipe) begin
            // Sub-block pipelines, pinned to their requests.
            assert (ot_rsp_valid == f_ot2);
            assert (ps_rsp_valid == f_ps3);
            assert (ps_pending == (f_ps1 || f_ps2 || f_ps3));
        end

        if (f_run) begin
            // The price books clear for SLOTS cycles after reset, so the
            // unpinned cycles above are always spent in S_INIT.
            if (!f_pipe) assert (state == S_INIT);
            assert (state <= S_SETTLE);
            if (state != S_INIT) assert (ot_ready);
            if (state == S_LOOK) assert (f_ot1 || f_ot2);
            if (state == S_IDLE) assert (!ps_pending && !f_ot1 && !f_ot2 && bid_ready && ask_ready);
            if (state == S_INIT) assert (!f_busy && !done);

            // Handshake: one done per command, busy in between.
            assert (f_busy == (f_active || done));
            if (done) assert (state == S_IDLE);
            if (f_busy) assert (f_cycles <= budget(c_type));

            // Where each state sits in the command's timeline, so k-induction
            // closes in a few steps instead of a whole command. Cycle k of a
            // command is f_cycles == k; the remove writes its level at k = 4.
            // A price book is ready again within 5 cycles of a write.
            // A command writes one side only; the other stays ready.
            if (f_active && !f_wrote) assert (bid_ready && ask_ready);
            if (f_active && f_wrote)
                assert ((f_lw_side ? bid_ready : ask_ready) &&
                        (f_lw_age < 5'd6 || (f_lw_side ? ask_ready : bid_ready)));
            if (f_active) begin
                assert (f_ps1 == (f_cycles == 6'd1));
                assert (f_ps2 == (f_cycles == 6'd2));
                assert (f_ps3 == (f_cycles == 6'd3));
                if (phase2) assert (c_type == "U" && f_wrote);
                if (phase2 && state != S_SETTLE) assert (f_lw_age == f_cycles - 6'd4);
            end
            // Which commands reach which states.
            if (f_active && state != S_SETTLE) assert (f_add || f_rem);
            if (state == S_REM_RD || state == S_REM_WR) assert (f_rem && !phase2);
            if (state == S_LOOK2) assert (c_type == "U" && !phase2);
            if ((state == S_INS || state == S_INS_WR) && !phase2) assert (f_add);
            if (state == S_SETTLE && !f_add && !f_rem) assert (!f_wrote && f_cycles <= 6'd4);

            case (state)
                S_LOOK: if (!phase2) assert (!f_wrote && f_ot1 == (f_cycles == 6'd1) &&
                                             f_ot2 == (f_cycles == 6'd2));
                        else         assert (f_ot1 == (f_cycles == 6'd6) &&
                                             f_ot2 == (f_cycles == 6'd7));
                S_REM_RD: assert (!f_wrote && f_cycles == 6'd3);
                S_REM_WR: assert (!f_wrote && f_cycles == 6'd4);
                S_LOOK2:  assert (f_cycles == 6'd5);
                S_INS:    if (!phase2) assert (!f_wrote && (f_cycles == 6'd3 || f_cycles == 6'd4));
                          else         assert (f_cycles >= 6'd8 && f_cycles <= 6'd10);
                S_INS_WR: assert (phase2 ? f_cycles <= 6'd11 : (!f_wrote && f_cycles == 6'd5));
                S_SETTLE: begin
                    assert (f_cycles <= 6'd17);
                    if (f_wrote) assert (f_cycles <= f_lw_age + 6'd11);
                    else         assert (f_cycles <= 6'd5);
                end
                default: ;
            endcase
            if (done) assert (f_cycles <= 6'd18);

            // Memory rules of the blocks below.
            if (tw_valid) assert (!ot_req_valid && !f_ot1);
            if (rd_go)    assert (rd_side ? ask_ready : bid_ready);
            if (lw_valid) assert (lw_side ? ask_ready : bid_ready);

            // Status: one cause, from a command that can raise it, decided
            // only on the way into S_SETTLE.
            if (f_active && state != S_SETTLE)
                assert (!order_dropped && !price_rejected && !unknown_order_ref);
            assert ($countones({order_dropped, price_rejected, unknown_order_ref}) <= 1);
            if (unknown_order_ref)
                assert (c_type == "E" || c_type == "C" || c_type == "X" ||
                        c_type == "D" || c_type == "U");
            if (order_dropped || price_rejected)
                assert (c_type == "A" || c_type == "F" || c_type == "U");

            // An empty side reports zeros.
            if (!bid_valid) assert (bid_slot == '0 && bid_shares == '0 && bid_orders == '0);
            if (!ask_valid) assert (ask_slot == '0 && ask_shares == '0 && ask_orders == '0);
        end
    end

    // Reachability, so no property above holds only vacuously.
    always_comb if (f_run && done) begin
        cover (c_type == "A" && !order_dropped && !price_rejected);
        cover (c_type == "A" && order_dropped);
        cover (c_type == "A" && price_rejected);
        cover (c_type == "X" && !unknown_order_ref);
        cover (c_type == "D" && !unknown_order_ref);
        cover (c_type == "D" && unknown_order_ref);
        cover (c_type == "U" && !order_dropped && !price_rejected && !unknown_order_ref);
        cover (c_type == "U" && price_rejected);
        cover (c_type == "S");
        cover (c_type == "A" && bid_valid && ask_valid);
        cover (f_had_bid && !bid_valid);           // the bid side emptied
    end
`endif

endmodule

`default_nettype wire
