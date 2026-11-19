`timescale 1ns / 1ps

module tb_top;
  import uvm_pkg::*;
  import book_tb_pkg::*;

  bit clk;
  always #4 clk = ~clk;

  book_if vif (clk);
  assign vif.base_price = BASE;

  book dut (
      .clk              (clk),
      .rst              (vif.rst),
      .base_price       (vif.base_price),
      .cmd_ready        (vif.cmd_ready),
      .cmd_valid        (vif.cmd_valid),
      .cmd_type         (vif.cmd_type),
      .cmd_side         (vif.cmd_side),
      .cmd_orn          (vif.cmd_orn),
      .cmd_new_orn      (vif.cmd_new_orn),
      .cmd_shares       (vif.cmd_shares),
      .cmd_price        (vif.cmd_price),
      .done             (vif.done),
      .order_dropped    (vif.order_dropped),
      .price_rejected   (vif.price_rejected),
      .unknown_order_ref(vif.unknown_order_ref),
      .bid_valid        (vif.bid_valid),
      .bid_slot         (vif.bid_slot),
      .bid_shares       (vif.bid_shares),
      .bid_orders       (vif.bid_orders),
      .ask_valid        (vif.ask_valid),
      .ask_slot         (vif.ask_slot),
      .ask_shares       (vif.ask_shares),
      .ask_orders       (vif.ask_orders)
  );

  initial begin
    uvm_config_db#(virtual book_if)::set(null, "*", "vif", vif);
    uvm_config_db#(virtual book_wr_if)::set(null, "*", "wr", dut.u_wr);
    run_test("book_random_test");
  end
endmodule
