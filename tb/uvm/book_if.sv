`include "itch_defs.vh"

interface book_if (input logic clk);
  logic                    rst;
  logic [            31:0] base_price;

  logic                    cmd_ready;
  logic                    cmd_valid;
  logic [             7:0] cmd_type;
  logic                    cmd_side;
  logic [            63:0] cmd_orn;
  logic [            63:0] cmd_new_orn;
  logic [            31:0] cmd_shares;
  logic [            31:0] cmd_price;

  logic                    done;
  logic                    order_dropped;
  logic                    price_rejected;
  logic                    unknown_order_ref;

  logic                    bid_valid;
  logic [`BOOK_SLOT_W-1:0] bid_slot;
  logic [            31:0] bid_shares;
  logic [            15:0] bid_orders;
  logic                    ask_valid;
  logic [`BOOK_SLOT_W-1:0] ask_slot;
  logic [            31:0] ask_shares;
  logic [            15:0] ask_orders;

  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    input cmd_ready, done, order_dropped, price_rejected, unknown_order_ref;
    output cmd_valid, cmd_type, cmd_side, cmd_orn, cmd_new_orn, cmd_shares, cmd_price;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst, cmd_ready, cmd_valid, cmd_type, cmd_side, cmd_orn, cmd_new_orn, cmd_shares, cmd_price;
    input done, order_dropped, price_rejected, unknown_order_ref;
    input bid_valid, bid_slot, bid_shares, bid_orders, ask_valid, ask_slot, ask_shares, ask_orders;
  endclocking

  wire accept = cmd_valid && cmd_ready;

  logic busy;
  always_ff @(posedge clk)
    if (rst || done) busy <= 1'b0;
    else if (accept) busy <= 1'b1;

  a_hold: assert property (@(posedge clk) disable iff (rst)
      cmd_valid && !cmd_ready |=> cmd_valid && $stable({cmd_type, cmd_side, cmd_orn, cmd_new_orn, cmd_shares, cmd_price}));
  a_ready: assert property (@(posedge clk) disable iff (rst) busy && !done |-> !cmd_ready);
  a_done: assert property (@(posedge clk) disable iff (rst) done |-> busy);
  a_finish: assert property (@(posedge clk) disable iff (rst) accept |-> ##[1:42] done);
  a_status: assert property (@(posedge clk) disable iff (rst)
      done |-> $onehot0({order_dropped, price_rejected, unknown_order_ref}));
  a_empty: assert property (@(posedge clk) disable iff (rst)
      (bid_valid || {bid_slot, bid_shares, bid_orders} == '0) &&
      (ask_valid || {ask_slot, ask_shares, ask_orders} == '0));
endinterface
