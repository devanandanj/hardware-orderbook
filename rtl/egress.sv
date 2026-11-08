/*
 *
 *   Egress
 *   github/devanandanj
 *
 *
 */

`include "itch_defs.vh"

`default_nettype none

module egress (
    input logic clk,
    input logic rst,

    input logic [31:0] base_price,
    input logic [31:0] cycle,

    input logic        cmd_accept,
    input logic [63:0] cmd_mold_seq,
    input logic [31:0] cmd_msg_index,
    input logic [31:0] cmd_t_arrive,

    input logic done,
    input logic order_dropped,
    input logic price_rejected,
    input logic unknown_order_ref,
    input logic mold_gap_seen,

    input logic                    bid_valid,
    input logic [`BOOK_SLOT_W-1:0] bid_slot,
    input logic [            31:0] bid_shares,
    input logic [            15:0] bid_orders,
    input logic                    ask_valid,
    input logic [`BOOK_SLOT_W-1:0] ask_slot,
    input logic [            31:0] ask_shares,
    input logic [            15:0] ask_orders,

    output logic snap_overflow,

    input logic tx_clk,
    input logic tx_rst,

    input logic [47:0] cfg_src_mac,
    input logic [47:0] cfg_dst_mac,
    input logic [31:0] cfg_src_ip,
    input logic [31:0] cfg_dst_ip,
    input logic [15:0] cfg_src_port,
    input logic [15:0] cfg_dst_port,

    output logic [7:0] s_data,
    output logic       s_valid,
    output logic       s_last,
    input  logic       s_ready
);

  localparam logic [31:0] TICK = `BOOK_PRICE_TICK;
  localparam logic [31:0] ORIGIN = `BOOK_SLOT_CENTER * `BOOK_PRICE_TICK;

  localparam logic [15:0] UDP_LEN = 8 + `SNAP_PACKET_LEN;
  localparam logic [15:0] IP_LEN = 20 + UDP_LEN;
  localparam logic [6:0] HDR_LEN = 42;
  localparam logic [6:0] LAST = HDR_LEN + `SNAP_PACKET_LEN - 1;
  localparam logic [2:0] LAST_WORD = `SNAP_PACKET_LEN / 8 - 1;

  logic [63:0] a_mold_seq;
  logic [31:0] a_msg_index, a_t_arrive;

  always_ff @(posedge clk) begin
    if (cmd_accept) begin
      a_mold_seq  <= cmd_mold_seq;
      a_msg_index <= cmd_msg_index;
      a_t_arrive  <= cmd_t_arrive;
    end
  end

  logic [7:0] status;

  always_comb begin
    status = '0;
    status[`SNAP_STATUS_ORDER_DROPPED] = order_dropped;
    status[`SNAP_STATUS_PRICE_REJECTED] = price_rejected;
    status[`SNAP_STATUS_MOLD_GAP_SEEN] = mold_gap_seen;
    status[`SNAP_STATUS_UNKNOWN_ORDER_REF] = unknown_order_ref;
  end

  logic w_room, writing;
  logic [2:0] wcnt;
  logic [31:0] snap_seq;
  wire take = done && w_room && !writing;

  logic [7:0] h_status;
  logic [31:0] h_seq, h_msg_index, h_t_arrive, h_t_commit;
  logic [63:0] h_mold_seq;
  logic h_bid_valid, h_ask_valid;
  logic [`BOOK_SLOT_W-1:0] h_bid_slot, h_ask_slot;
  logic [31:0] h_bid_shares, h_ask_shares;
  logic [15:0] h_bid_orders, h_ask_orders;
  logic [31:0] origin_price, bid_price, ask_price;

  always_ff @(posedge clk) begin
    if (take) begin
      h_status     <= status;
      h_seq        <= snap_seq;
      h_mold_seq   <= a_mold_seq;
      h_msg_index  <= a_msg_index;
      h_t_arrive   <= a_t_arrive;
      h_t_commit   <= cycle;
      h_bid_valid  <= bid_valid;
      h_bid_slot   <= bid_slot;
      h_bid_shares <= bid_shares;
      h_bid_orders <= bid_orders;
      h_ask_valid  <= ask_valid;
      h_ask_slot   <= ask_slot;
      h_ask_shares <= ask_shares;
      h_ask_orders <= ask_orders;
    end
    origin_price <= base_price - ORIGIN;
    bid_price    <= h_bid_valid ? origin_price + h_bid_slot * TICK : '0;
    ask_price    <= h_ask_valid ? origin_price + h_ask_slot * TICK : '0;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      snap_seq      <= '0;
      snap_overflow <= 1'b0;
      writing       <= 1'b0;
      wcnt          <= '0;
    end else begin
      if (done) snap_seq <= snap_seq + 1'b1;
      if (done && !take) snap_overflow <= 1'b1;
      if (take) begin
        writing <= 1'b1;
        wcnt    <= '0;
      end else if (writing) begin
        wcnt <= wcnt + 1'b1;
        if (wcnt == LAST_WORD) writing <= 1'b0;
      end
    end
  end

  logic [63:0] w_data;

  always_comb begin
    case (wcnt)
      3'd0:    w_data = {`SNAP_MAGIC, `SNAP_VERSION, h_status, h_seq};
      3'd1:    w_data = h_mold_seq;
      3'd2:    w_data = {h_msg_index, h_t_arrive};
      3'd3:    w_data = {h_t_commit, bid_price};
      3'd4:    w_data = {h_bid_shares, ask_price};
      default: w_data = {h_ask_shares, h_bid_orders, h_ask_orders};
    endcase
  end

  logic [6:0] cnt, cnt_nx, pay, pay_nx;
  logic [2:0] r_word;
  logic [63:0] r_data;
  logic r_avail;
  wire beat = s_valid && s_ready;

  async_fifo #(
      .W(64),
      .A(7),
      .L(3)
  ) u_fifo (
      .wclk   (clk),
      .wrst   (rst),
      .w_en   (writing),
      .w_word (wcnt),
      .w_data (w_data),
      .w_push (writing && wcnt == LAST_WORD),
      .w_room (w_room),
      .rclk   (tx_clk),
      .rrst   (tx_rst),
      .r_word (r_word),
      .r_data (r_data),
      .r_avail(r_avail),
      .r_pop  (beat && s_last)
  );

  logic [19:0] csum_sum;
  logic [16:0] csum_fold;
  logic [15:0] csum;

  always_ff @(posedge tx_clk) begin
    csum_sum <= 16'h4500 + IP_LEN + 16'h4000 + 16'h4011 +
        cfg_src_ip[31:16] + cfg_src_ip[15:0] + cfg_dst_ip[31:16] + cfg_dst_ip[15:0];
    csum_fold <= csum_sum[15:0] + csum_sum[19:16];
    csum <= ~(csum_fold[15:0] + csum_fold[16]);
  end

  wire [8*HDR_LEN-1:0] hdr = {
    cfg_dst_mac, cfg_src_mac, 16'h0800,
    16'h4500, IP_LEN, 16'h0000, 16'h4000, 8'd64, 8'd17, csum, cfg_src_ip, cfg_dst_ip,
    cfg_src_port, cfg_dst_port, UDP_LEN, 16'h0000
  };

  assign s_valid = r_avail;
  assign s_last  = cnt == LAST;
  assign cnt_nx  = beat ? (s_last ? 7'd0 : cnt + 1'b1) : cnt;
  assign pay     = cnt - HDR_LEN;
  assign pay_nx  = cnt_nx - HDR_LEN;
  assign r_word  = cnt_nx < HDR_LEN ? 3'd0 : pay_nx[5:3];
  assign s_data  = cnt < HDR_LEN ? hdr[8*(HDR_LEN-cnt)-1-:8] : r_data[8*(8-pay[2:0])-1-:8];

  always_ff @(posedge tx_clk) begin
    if (tx_rst) cnt <= '0;
    else cnt <= cnt_nx;
  end

endmodule

`default_nettype wire
