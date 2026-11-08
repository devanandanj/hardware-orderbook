/*
 *
 *   XUPV5 top
 *   github/devanandanj
 *
 *
 */

`default_nettype none

module xupv5_top #(
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
    input logic sys_clk,
    input logic cpu_reset_n,

    input logic       phy_rxclk,
    input logic [7:0] phy_rxd,
    input logic       phy_rxdv,
    input logic       phy_rxer,

    output logic       phy_gtxclk,
    output logic [7:0] phy_txd,
    output logic       phy_txen,
    output logic       phy_txer,
    output logic       phy_reset_n,

    output logic [7:0] led
);

  logic pll_fb, pll_clk, pll_locked, gtx_clk, rx_clk_ibuf, gmii_rx_clk;

  PLL_BASE #(
      .CLKIN_PERIOD  (10.0),
      .CLKFBOUT_MULT (10),
      .DIVCLK_DIVIDE (1),
      .CLKOUT0_DIVIDE(8)
  ) u_pll (
      .CLKIN   (sys_clk),
      .CLKFBIN (pll_fb),
      .CLKFBOUT(pll_fb),
      .CLKOUT0 (pll_clk),
      .CLKOUT1 (),
      .CLKOUT2 (),
      .CLKOUT3 (),
      .CLKOUT4 (),
      .CLKOUT5 (),
      .LOCKED  (pll_locked),
      .RST     (!cpu_reset_n)
  );

  BUFG u_gtx_bufg (
      .I(pll_clk),
      .O(gtx_clk)
  );

  IBUFG u_rx_ibufg (
      .I(phy_rxclk),
      .O(rx_clk_ibuf)
  );

  BUFG u_rx_bufg (
      .I(rx_clk_ibuf),
      .O(gmii_rx_clk)
  );

  ODDR #(
      .DDR_CLK_EDGE("OPPOSITE_EDGE")
  ) u_gtxclk_oddr (
      .Q (phy_gtxclk),
      .C (gtx_clk),
      .CE(1'b1),
      .D1(1'b0),
      .D2(1'b1),
      .R (1'b0),
      .S (1'b0)
  );

  logic [21:0] phy_rst_cnt;
  wire phy_ready = phy_rst_cnt[21];

  always_ff @(posedge gtx_clk or negedge pll_locked) begin
    if (!pll_locked) phy_rst_cnt <= '0;
    else if (!phy_ready) phy_rst_cnt <= phy_rst_cnt + 1'b1;
  end

  assign phy_reset_n = phy_ready;

  (* IOB = "TRUE" *) logic [7:0] rxd_q;
  (* IOB = "TRUE" *) logic rxdv_q, rxer_q;
  (* IOB = "TRUE" *) logic [7:0] txd_q;
  (* IOB = "TRUE" *) logic txen_q, txer_q;
  logic [7:0] gmii_txd;
  logic gmii_tx_en, gmii_tx_er;

  always_ff @(posedge gmii_rx_clk) begin
    rxd_q  <= phy_rxd;
    rxdv_q <= phy_rxdv;
    rxer_q <= phy_rxer;
  end

  always_ff @(posedge gtx_clk) begin
    txd_q  <= gmii_txd;
    txen_q <= gmii_tx_en;
    txer_q <= gmii_tx_er;
  end

  assign phy_txd  = txd_q;
  assign phy_txen = txen_q;
  assign phy_txer = txer_q;

  logic mold_gap_seen, cmd_overrun, snap_overflow;

  orderbook_top #(
      .MAC       (MAC),
      .IP        (IP),
      .PORT      (PORT),
      .HOST_MAC  (HOST_MAC),
      .HOST_IP   (HOST_IP),
      .HOST_PORT (HOST_PORT),
      .FILTER_EN (FILTER_EN),
      .LOCATE    (LOCATE),
      .BASE_PRICE(BASE_PRICE)
  ) u_core (
      .gmii_rx_clk,
      .gtx_clk,
      .rst_async (!phy_ready),
      .gmii_rxd  (rxd_q),
      .gmii_rx_dv(rxdv_q),
      .gmii_rx_er(rxer_q),
      .gmii_txd,
      .gmii_tx_en,
      .gmii_tx_er,
      .mold_gap_seen,
      .cmd_overrun,
      .snap_overflow
  );

  logic [25:0] rx_beat, rx_seen, tx_seen;

  always_ff @(posedge gmii_rx_clk) begin
    rx_beat <= rx_beat + 1'b1;
    rx_seen <= rxdv_q ? '1 : rx_seen - (rx_seen != 0);
  end

  always_ff @(posedge gtx_clk) begin
    tx_seen <= txen_q ? '1 : tx_seen - (tx_seen != 0);
  end

  assign led = {
    snap_overflow,
    cmd_overrun,
    mold_gap_seen,
    tx_seen != 0,
    rx_seen != 0,
    rx_beat[25],
    phy_ready,
    pll_locked
  };

endmodule

`default_nettype wire
