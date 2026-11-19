`include "itch_defs.vh"

// Bound into book: its order table and price book write ports, for the scoreboard.
interface book_wr_if (
    input logic                    clk,
    input logic                    rst,
    input logic                    tw_valid,
    input logic                    tw_cam,
    input logic [`BOOK_HASH_W-1:0] tw_set,
    input logic [             3:0] tw_idx,
    input book_pkg::entry_t        tw_entry,
    input logic                    lw_valid,
    input logic                    lw_side,
    input logic [`BOOK_SLOT_W-1:0] lw_slot,
    input logic [            31:0] lw_shares,
    input logic [            15:0] lw_orders
);
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst, tw_valid, tw_cam, tw_set, tw_idx, tw_entry, lw_valid, lw_side, lw_slot, lw_shares, lw_orders;
  endclocking
endinterface

bind book book_wr_if u_wr (.*);
