/*
 *
 *   Orderbook top
 *   github/devanandanj
 *
 *
 */

`include "itch_defs.vh"

`default_nettype none

module orderbook_top #(
    parameter logic [47:0] MAC        = 48'h02_00_00_00_00_01,
    parameter logic [31:0] IP         = 32'hC0A8_0A02,
    parameter logic [15:0] PORT       = 16'd26400,
    parameter logic [47:0] HOST_MAC   = 48'h02_00_00_00_00_02,
    parameter logic [31:0] HOST_IP    = 32'hC0A8_0A01,
    parameter logic [15:0] HOST_PORT  = 16'd26401,
    parameter logic        FILTER_EN  = 1'b1,
    parameter logic [15:0] LOCATE     = 16'd1,
    parameter logic [31:0] BASE_PRICE = 32'd1_000_000
) (
    input logic gmii_rx_clk,
    input logic gtx_clk,
    input logic rst_async,

    input logic [7:0] gmii_rxd,
    input logic       gmii_rx_dv,
    input logic       gmii_rx_er,

    output logic [7:0] gmii_txd,
    output logic       gmii_tx_en,
    output logic       gmii_tx_er,

    output logic mold_gap_seen,
    output logic cmd_overrun,
    output logic snap_overflow
);

  logic [1:0] rx_rst_q, tx_rst_q;

  always_ff @(posedge gmii_rx_clk or posedge rst_async) begin
    if (rst_async) rx_rst_q <= 2'b11;
    else rx_rst_q <= {rx_rst_q[0], 1'b0};
  end

  always_ff @(posedge gtx_clk or posedge rst_async) begin
    if (rst_async) tx_rst_q <= 2'b11;
    else tx_rst_q <= {tx_rst_q[0], 1'b0};
  end

  wire rst = rx_rst_q[1];
  wire tx_rst = tx_rst_q[1];

  logic [31:0] cycle;

  always_ff @(posedge gmii_rx_clk) begin
    if (rst) cycle <= '0;
    else cycle <= cycle + 1'b1;
  end

  logic [7:0] m_data, s_data;
  logic m_valid, m_eof, m_bad, s_valid, s_last, s_ready;

  // shortcut: eth_stack has one reset for both clocks, so its transmit side sees rst; split it in the ethernet repo before hardware.
  eth_stack u_eth (
      .gmii_rx_clk,
      .gtx_clk,
      .reset    (rst),
      .cfg_mac  (MAC),
      .cfg_ip   (IP),
      .cfg_port (PORT),
      .gmii_rxd,
      .gmii_rx_dv,
      .gmii_rx_er,
      .m_data,
      .m_valid,
      .m_eof,
      .m_bad,
      .s_data,
      .s_valid,
      .s_last,
      .s_ready,
      .gmii_txd,
      .gmii_tx_en,
      .gmii_tx_er
  );

  logic cmd_valid, cmd_ready, cmd_side;
  logic [7:0] cmd_type;
  logic [63:0] cmd_orn, cmd_new_orn, cmd_mold_seq;
  logic [31:0] cmd_shares, cmd_price, cmd_msg_index, cmd_t_arrive;

  ingress u_ingress (
      .clk          (gmii_rx_clk),
      .rst,
      .cfg_filter_en(FILTER_EN),
      .cfg_locate   (LOCATE),
      .cycle,
      .m_data,
      .m_valid,
      .m_eof,
      .m_bad,
      .cmd_valid,
      .cmd_ready,
      .cmd_type,
      .cmd_side,
      .cmd_orn,
      .cmd_new_orn,
      .cmd_shares,
      .cmd_price,
      .cmd_mold_seq,
      .cmd_msg_index,
      .cmd_t_arrive,
      .mold_gap_seen,
      .cmd_overrun
  );

  logic done, order_dropped, price_rejected, unknown_order_ref;
  logic bid_valid, ask_valid;
  logic [`BOOK_SLOT_W-1:0] bid_slot, ask_slot;
  logic [31:0] bid_shares, ask_shares;
  logic [15:0] bid_orders, ask_orders;

  book u_book (
      .clk       (gmii_rx_clk),
      .rst,
      .base_price(BASE_PRICE),
      .cmd_ready,
      .cmd_valid,
      .cmd_type,
      .cmd_side,
      .cmd_orn,
      .cmd_new_orn,
      .cmd_shares,
      .cmd_price,
      .done,
      .order_dropped,
      .price_rejected,
      .unknown_order_ref,
      .bid_valid,
      .bid_slot,
      .bid_shares,
      .bid_orders,
      .ask_valid,
      .ask_slot,
      .ask_shares,
      .ask_orders
  );

  egress u_egress (
      .clk         (gmii_rx_clk),
      .rst,
      .base_price  (BASE_PRICE),
      .cycle,
      .cmd_accept  (cmd_valid && cmd_ready),
      .cmd_mold_seq,
      .cmd_msg_index,
      .cmd_t_arrive,
      .done,
      .order_dropped,
      .price_rejected,
      .unknown_order_ref,
      .mold_gap_seen,
      .bid_valid,
      .bid_slot,
      .bid_shares,
      .bid_orders,
      .ask_valid,
      .ask_slot,
      .ask_shares,
      .ask_orders,
      .snap_overflow,
      .tx_clk      (gtx_clk),
      .tx_rst,
      .cfg_src_mac (MAC),
      .cfg_dst_mac (HOST_MAC),
      .cfg_src_ip  (IP),
      .cfg_dst_ip  (HOST_IP),
      .cfg_src_port(PORT),
      .cfg_dst_port(HOST_PORT),
      .s_data,
      .s_valid,
      .s_last,
      .s_ready
  );

endmodule

`default_nettype wire
