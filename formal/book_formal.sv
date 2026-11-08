// book_formal.sv -- formal top for rtl/book.sv.
//
// Every input is free, so the solver chooses the stimulus. The properties
// live in book.sv under `ifdef FORMAL: they need its internal signals,
// which Yosys cannot reach from a wrapper. Run at the small geometry in
// book_small.yaml; see README.md.

`default_nettype none

module book_formal (
    input wire        clk,
    input wire        rst,
    input wire [31:0] base_price,
    input wire        cmd_valid,
    input wire [7:0]  cmd_type,
    input wire        cmd_side,
    input wire [63:0] cmd_orn,
    input wire [63:0] cmd_new_orn,
    input wire [31:0] cmd_shares,
    input wire [31:0] cmd_price
);

    book dut (
        .clk               (clk),
        .rst               (rst),
        .base_price        (base_price),
        .cmd_ready         (),
        .cmd_valid         (cmd_valid),
        .cmd_type          (cmd_type),
        .cmd_side          (cmd_side),
        .cmd_orn           (cmd_orn),
        .cmd_new_orn       (cmd_new_orn),
        .cmd_shares        (cmd_shares),
        .cmd_price         (cmd_price),
        .done              (),
        .order_dropped     (),
        .price_rejected    (),
        .unknown_order_ref (),
        .bid_valid         (),
        .bid_slot          (),
        .bid_shares        (),
        .bid_orders        (),
        .ask_valid         (),
        .ask_slot          (),
        .ask_shares        (),
        .ask_orders        ()
    );

endmodule

`default_nettype wire
