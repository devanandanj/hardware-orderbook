/*
 *
 *   Ingress
 *   github/devanandanj
 *
 *
 */

`include "itch_defs.vh"

`default_nettype none

module ingress (
    input logic clk,
    input logic rst,

    input logic        cfg_filter_en,
    input logic [15:0] cfg_locate,
    input logic [31:0] cycle,

    input logic [7:0] m_data,
    input logic       m_valid,
    input logic       m_eof,
    input logic       m_bad,

    output logic        cmd_valid,
    input  logic        cmd_ready,
    output logic [ 7:0] cmd_type,
    output logic        cmd_side,
    output logic [63:0] cmd_orn,
    output logic [63:0] cmd_new_orn,
    output logic [31:0] cmd_shares,
    output logic [31:0] cmd_price,
    output logic [63:0] cmd_mold_seq,
    output logic [31:0] cmd_msg_index,
    output logic [31:0] cmd_t_arrive,

    output logic mold_gap_seen,
    output logic cmd_overrun
);

  localparam logic [7:0] T_A = `ITCH_ADD_ORDER_TYPE;
  localparam logic [7:0] T_F = `ITCH_ADD_ORDER_MPID_TYPE;
  localparam logic [7:0] T_E = `ITCH_ORDER_EXECUTED_TYPE;
  localparam logic [7:0] T_C = `ITCH_ORDER_EXECUTED_WITH_PRICE_TYPE;
  localparam logic [7:0] T_X = `ITCH_ORDER_CANCEL_TYPE;
  localparam logic [7:0] T_D = `ITCH_ORDER_DELETE_TYPE;
  localparam logic [7:0] T_U = `ITCH_ORDER_REPLACE_TYPE;

  localparam logic [7:0] NONE = 8'd255;

  function automatic logic [7:0] book_len(input logic [7:0] t);
    case (t)
      T_A:     book_len = `ITCH_ADD_ORDER_LEN;
      T_F:     book_len = `ITCH_ADD_ORDER_MPID_LEN;
      T_E:     book_len = `ITCH_ORDER_EXECUTED_LEN;
      T_C:     book_len = `ITCH_ORDER_EXECUTED_WITH_PRICE_LEN;
      T_X:     book_len = `ITCH_ORDER_CANCEL_LEN;
      T_D:     book_len = `ITCH_ORDER_DELETE_LEN;
      T_U:     book_len = `ITCH_ORDER_REPLACE_LEN;
      default: book_len = 8'd0;
    endcase
  endfunction

  function automatic logic [7:0] locate_off(input logic [7:0] t);
    case (t)
      T_A:     locate_off = `ITCH_ADD_ORDER_STOCK_LOCATE_OFF;
      T_F:     locate_off = `ITCH_ADD_ORDER_MPID_STOCK_LOCATE_OFF;
      T_E:     locate_off = `ITCH_ORDER_EXECUTED_STOCK_LOCATE_OFF;
      T_C:     locate_off = `ITCH_ORDER_EXECUTED_WITH_PRICE_STOCK_LOCATE_OFF;
      T_X:     locate_off = `ITCH_ORDER_CANCEL_STOCK_LOCATE_OFF;
      T_D:     locate_off = `ITCH_ORDER_DELETE_STOCK_LOCATE_OFF;
      T_U:     locate_off = `ITCH_ORDER_REPLACE_STOCK_LOCATE_OFF;
      default: locate_off = NONE;
    endcase
  endfunction

  function automatic logic [7:0] orn_off(input logic [7:0] t);
    case (t)
      T_A:     orn_off = `ITCH_ADD_ORDER_ORDER_REF_OFF;
      T_F:     orn_off = `ITCH_ADD_ORDER_MPID_ORDER_REF_OFF;
      T_E:     orn_off = `ITCH_ORDER_EXECUTED_ORDER_REF_OFF;
      T_C:     orn_off = `ITCH_ORDER_EXECUTED_WITH_PRICE_ORDER_REF_OFF;
      T_X:     orn_off = `ITCH_ORDER_CANCEL_ORDER_REF_OFF;
      T_D:     orn_off = `ITCH_ORDER_DELETE_ORDER_REF_OFF;
      T_U:     orn_off = `ITCH_ORDER_REPLACE_ORIGINAL_ORDER_REF_OFF;
      default: orn_off = NONE;
    endcase
  endfunction

  function automatic logic [7:0] shares_off(input logic [7:0] t);
    case (t)
      T_A:     shares_off = `ITCH_ADD_ORDER_SHARES_OFF;
      T_F:     shares_off = `ITCH_ADD_ORDER_MPID_SHARES_OFF;
      T_E:     shares_off = `ITCH_ORDER_EXECUTED_EXECUTED_SHARES_OFF;
      T_C:     shares_off = `ITCH_ORDER_EXECUTED_WITH_PRICE_EXECUTED_SHARES_OFF;
      T_X:     shares_off = `ITCH_ORDER_CANCEL_CANCELLED_SHARES_OFF;
      T_U:     shares_off = `ITCH_ORDER_REPLACE_SHARES_OFF;
      default: shares_off = NONE;
    endcase
  endfunction

  // C's execution price is not the order's and the book ignores it.
  function automatic logic [7:0] price_off(input logic [7:0] t);
    case (t)
      T_A:     price_off = `ITCH_ADD_ORDER_PRICE_OFF;
      T_F:     price_off = `ITCH_ADD_ORDER_MPID_PRICE_OFF;
      T_U:     price_off = `ITCH_ORDER_REPLACE_PRICE_OFF;
      default: price_off = NONE;
    endcase
  endfunction

  function automatic logic [7:0] side_off(input logic [7:0] t);
    case (t)
      T_A:     side_off = `ITCH_ADD_ORDER_SIDE_OFF;
      T_F:     side_off = `ITCH_ADD_ORDER_MPID_SIDE_OFF;
      default: side_off = NONE;
    endcase
  endfunction

  function automatic logic in_field(input logic [15:0] i, input logic [7:0] off, input int w);
    in_field = off != NONE && i >= {8'd0, off} && i < {8'd0, off} + w[15:0];
  endfunction

  localparam logic [4:0] HDR_LEN  = `MOLD_HDR_LEN;
  localparam logic [4:0] SEQ_LO   = `MOLD_SEQUENCE_OFF;
  localparam logic [4:0] SEQ_HI   = `MOLD_SEQUENCE_OFF + `MOLD_SEQUENCE_W;
  localparam logic [4:0] CNT_OFF  = `MOLD_MESSAGE_COUNT_OFF;

  localparam logic [1:0] P_LEN_HI = 2'd0;
  localparam logic [1:0] P_LEN_LO = 2'd1;
  localparam logic [1:0] P_BODY   = 2'd2;

  wire         byte_in = m_valid && !m_eof;

  logic [ 4:0] hdr_cnt;
  logic [63:0] seq;
  logic [ 7:0] cnt_hi;
  wire         in_hdr = hdr_cnt != HDR_LEN;

  logic [ 1:0] phase;
  logic [15:0] msgs_left;
  logic [ 7:0] len_hi;
  logic [15:0] mlen, bidx;

  logic        pkt_take;
  logic        pkt_commit;
  logic [63:0] pkt_next;

  logic        have_expected;
  logic [63:0] expected;
  logic [31:0] msg_cnt;

  wire  [15:0] cnt_full = {cnt_hi, m_data};
  wire         hdr_last = byte_in && hdr_cnt == HDR_LEN - 5'd1;
  wire         eos = cnt_full == `MOLD_END_OF_SESSION;
  wire         retrans = have_expected && seq < expected;

  logic [ 7:0] f_type;
  logic [15:0] f_locate;
  logic        f_side;
  logic [63:0] f_orn, f_new_orn;
  logic [31:0] f_shares, f_price;

  logic [ 7:0] type_nx;
  logic [15:0] locate_nx;
  logic        side_nx;
  logic [63:0] orn_nx, new_orn_nx;
  logic [31:0] shares_nx, price_nx;

  wire body = byte_in && !in_hdr && phase == P_BODY;

  always_comb begin
    type_nx    = f_type;
    locate_nx  = f_locate;
    side_nx    = f_side;
    orn_nx     = f_orn;
    new_orn_nx = f_new_orn;
    shares_nx  = f_shares;
    price_nx   = f_price;
    if (body) begin
      if (bidx == 16'd0) type_nx = m_data;
      if (in_field(bidx, locate_off(f_type), 2)) locate_nx = {f_locate[7:0], m_data};
      if (in_field(bidx, side_off(f_type), 1)) side_nx = m_data != `ITCH_SIDE_BUY_CHAR;
      if (in_field(bidx, orn_off(f_type), 8)) orn_nx = {f_orn[55:0], m_data};
      if (f_type == T_U && in_field(bidx, `ITCH_ORDER_REPLACE_NEW_ORDER_REF_OFF, 8))
        new_orn_nx = {f_new_orn[55:0], m_data};
      if (in_field(bidx, shares_off(f_type), 4)) shares_nx = {f_shares[23:0], m_data};
      if (in_field(bidx, price_off(f_type), 4)) price_nx = {f_price[23:0], m_data};
    end
  end

  wire zero_len = byte_in && !in_hdr && phase == P_LEN_LO && {len_hi, m_data} == 16'd0;
  wire last = body && bidx == mlen - 16'd1;
  wire msg_done = last || zero_len;
  wire selected = last && pkt_take && book_len(
      type_nx
  ) != 8'd0 && mlen >= {8'd0, book_len(
      type_nx
  )} && (!cfg_filter_en || locate_nx == cfg_locate);

  always_ff @(posedge clk) begin
    if (rst) begin
      hdr_cnt       <= '0;
      phase         <= P_LEN_HI;
      msgs_left     <= '0;
      pkt_take      <= 1'b0;
      pkt_commit    <= 1'b0;
      have_expected <= 1'b0;
      msg_cnt       <= '0;
      mold_gap_seen <= 1'b0;
    end else if (m_eof) begin
      if (!in_hdr && pkt_commit && !m_bad) begin
        expected      <= pkt_next;
        have_expected <= 1'b1;
      end
      hdr_cnt    <= '0;
      phase      <= P_LEN_HI;
      msgs_left  <= '0;
      pkt_take   <= 1'b0;
      pkt_commit <= 1'b0;
    end else if (byte_in) begin
      if (in_hdr) begin
        hdr_cnt <= hdr_cnt + 5'd1;
        if (hdr_cnt >= SEQ_LO && hdr_cnt < SEQ_HI) seq <= {seq[55:0], m_data};
        if (hdr_cnt == CNT_OFF) cnt_hi <= m_data;
        if (hdr_last) begin
          msgs_left  <= eos ? 16'd0 : cnt_full;
          pkt_take   <= !eos && !retrans;
          pkt_commit <= !eos && !retrans;
          pkt_next   <= seq + {48'd0, cnt_full};
          if (!eos && have_expected && seq > expected) mold_gap_seen <= 1'b1;
        end
      end else if (msgs_left != 16'd0) begin
        case (phase)
          P_LEN_HI: begin
            len_hi <= m_data;
            phase  <= P_LEN_LO;
          end
          P_LEN_LO: begin
            mlen  <= {len_hi, m_data};
            bidx  <= '0;
            phase <= zero_len ? P_LEN_HI : P_BODY;
          end
          default: begin
            bidx <= bidx + 16'd1;
            if (last) phase <= P_LEN_HI;
          end
        endcase
        if (msg_done) begin
          msgs_left <= msgs_left - 16'd1;
          msg_cnt   <= msg_cnt + 32'd1;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    f_type    <= type_nx;
    f_locate  <= locate_nx;
    f_side    <= side_nx;
    f_orn     <= orn_nx;
    f_new_orn <= new_orn_nx;
    f_shares  <= shares_nx;
    f_price   <= price_nx;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      cmd_valid   <= 1'b0;
      cmd_overrun <= 1'b0;
    end else begin
      if (cmd_valid && cmd_ready) cmd_valid <= 1'b0;
      if (selected) begin
        if (cmd_valid && !cmd_ready) begin
          cmd_overrun <= 1'b1;
        end else begin
          cmd_valid     <= 1'b1;
          cmd_type      <= type_nx;
          cmd_side      <= side_nx;
          cmd_orn       <= orn_nx;
          cmd_new_orn   <= new_orn_nx;
          cmd_shares    <= shares_nx;
          cmd_price     <= price_nx;
          cmd_mold_seq  <= seq;
          cmd_msg_index <= msg_cnt;
          cmd_t_arrive  <= cycle;
        end
      end
    end
  end

endmodule

`default_nettype wire
