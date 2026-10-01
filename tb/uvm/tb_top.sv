`timescale 1ns / 1ps
`include "book_defs.svh"

module tb_top;
    import uvm_pkg::*;
    import book_pkg::*;

    bit clk;
    always #5 clk = ~clk;   // 100 MHz

    book_if vif (clk);

    book #(.MAX(`BOOK_MAX)) dut (
        .clk                 (clk),
        .rst                 (vif.rst),
        .cmd_valid           (vif.cmd_valid),
        .cmd_ready           (vif.cmd_ready),
        .cmd_type            (vif.cmd_type),
        .cmd_side            (vif.cmd_side),
        .cmd_order_ref       (vif.cmd_order_ref),
        .cmd_new_order_ref   (vif.cmd_new_order_ref),
        .cmd_shares          (vif.cmd_shares),
        .cmd_price           (vif.cmd_price),
        .cmd_exec_shares     (vif.cmd_exec_shares),
        .mold_gap            (vif.mold_gap),
        .commit              (vif.commit),
        .bid_count           (vif.bid_count),
        .ask_count           (vif.ask_count),
        .book_full_bid       (vif.book_full_bid),
        .book_full_ask       (vif.book_full_ask),
        .unknown_order_ref   (vif.unknown_order_ref),
        .mold_gap_seen       (vif.mold_gap_seen),
        .slot_valid_bid      (vif.slot_valid_bid),
        .slot_valid_ask      (vif.slot_valid_ask),
        .slot_ref_bid_flat   (vif.slot_ref_bid_flat),
        .slot_ref_ask_flat   (vif.slot_ref_ask_flat),
        .slot_price_bid_flat (vif.slot_price_bid_flat),
        .slot_price_ask_flat (vif.slot_price_ask_flat),
        .slot_qty_bid_flat   (vif.slot_qty_bid_flat),
        .slot_qty_ask_flat   (vif.slot_qty_ask_flat)
    );

    initial begin
        uvm_config_db #(virtual book_if)::set(null, "*", "vif", vif);
        run_test("book_random_test");
    end
endmodule
