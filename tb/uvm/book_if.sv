// book_if.sv -- pin-level interface to rtl/book.v, plus protocol assertions
// that hold on every cycle of every test.

`include "book_defs.svh"

interface book_if (input bit clk);

    localparam int MAX = `BOOK_MAX;

    logic                rst;

    logic                cmd_valid;
    logic                cmd_ready;
    logic [7:0]          cmd_type;
    logic                cmd_side;
    logic [63:0]         cmd_order_ref;
    logic [63:0]         cmd_new_order_ref;
    logic [31:0]         cmd_shares;
    logic [31:0]         cmd_price;
    logic [31:0]         cmd_exec_shares;
    logic                mold_gap;

    logic                commit;
    logic [7:0]          bid_count;
    logic [7:0]          ask_count;
    logic                book_full_bid;
    logic                book_full_ask;
    logic                unknown_order_ref;
    logic                mold_gap_seen;

    logic [MAX-1:0]      slot_valid_bid,      slot_valid_ask;
    logic [64*MAX-1:0]   slot_ref_bid_flat,   slot_ref_ask_flat;
    logic [32*MAX-1:0]   slot_price_bid_flat, slot_price_ask_flat;
    logic [32*MAX-1:0]   slot_qty_bid_flat,   slot_qty_ask_flat;

    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output rst, cmd_valid, cmd_type, cmd_side, cmd_order_ref,
               cmd_new_order_ref, cmd_shares, cmd_price, cmd_exec_shares,
               mold_gap;
        input  cmd_ready;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input rst, cmd_valid, cmd_ready, cmd_type, cmd_side, cmd_order_ref,
              cmd_new_order_ref, cmd_shares, cmd_price, cmd_exec_shares,
              mold_gap, commit, bid_count, ask_count, book_full_bid,
              book_full_ask, unknown_order_ref, mold_gap_seen,
              slot_valid_bid, slot_valid_ask,
              slot_ref_bid_flat, slot_ref_ask_flat,
              slot_price_bid_flat, slot_price_ask_flat,
              slot_qty_bid_flat, slot_qty_ask_flat;
    endclocking

    // ---- protocol assertions -------------------------------------------

    // Every accepted command commits exactly one cycle later, and nothing
    // else does.
    a_commit_follows_accept: assert property (@(posedge clk) disable iff (rst)
        (cmd_valid && cmd_ready) |=> commit);
    a_no_spurious_commit: assert property (@(posedge clk) disable iff (rst)
        !(cmd_valid && cmd_ready) |=> !commit);

    a_bid_count_bound: assert property (@(posedge clk) disable iff (rst)
        bid_count <= MAX);
    a_ask_count_bound: assert property (@(posedge clk) disable iff (rst)
        ask_count <= MAX);

    a_full_bid_iff_cap: assert property (@(posedge clk) disable iff (rst)
        book_full_bid == (bid_count == MAX));
    a_full_ask_iff_cap: assert property (@(posedge clk) disable iff (rst)
        book_full_ask == (ask_count == MAX));

    a_gap_sticky: assert property (@(posedge clk) disable iff (rst)
        mold_gap_seen |=> mold_gap_seen);

endinterface
