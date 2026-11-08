/*
 *
 *   Async FIFO
 *   github/devanandanj
 *
 *
 */

`default_nettype none

module async_fifo #(
    parameter int W = 64,
    parameter int A = 7,
    parameter int L = 3
) (
    input  logic         wclk,
    input  logic         wrst,
    input  logic         w_en,
    input  logic [L-1:0] w_word,
    input  logic [W-1:0] w_data,
    input  logic         w_push,
    output logic         w_room,

    input  logic         rclk,
    input  logic         rrst,
    input  logic [L-1:0] r_word,
    output logic [W-1:0] r_data,
    output logic         r_avail,
    input  logic         r_pop
);

  localparam int DEPTH = 1 << (A + L);

  function automatic logic [A:0] to_gray(input logic [A:0] b);
    to_gray = b ^ (b >> 1);
  endfunction

  logic [W-1:0] mem[0:DEPTH-1];

  logic [A:0] wbin, wgray, rgray_w1, rgray_w2;
  logic [A:0] rbin, rgray, wgray_r1, wgray_r2;

  assign w_room  = wgray != {~rgray_w2[A:A-1], rgray_w2[A-2:0]};
  assign r_avail = rgray != wgray_r2;

  always_ff @(posedge wclk) begin
    if (w_en) mem[{wbin[A-1:0], w_word}] <= w_data;
  end

  always_ff @(posedge wclk) begin
    if (wrst) begin
      wbin     <= '0;
      wgray    <= '0;
      rgray_w1 <= '0;
      rgray_w2 <= '0;
    end else begin
      rgray_w1 <= rgray;
      rgray_w2 <= rgray_w1;
      if (w_push) begin
        wbin  <= wbin + 1'b1;
        wgray <= to_gray(wbin + 1'b1);
      end
    end
  end

  always_ff @(posedge rclk) begin
    r_data <= mem[{rbin[A-1:0], r_word}];
  end

  always_ff @(posedge rclk) begin
    if (rrst) begin
      rbin     <= '0;
      rgray    <= '0;
      wgray_r1 <= '0;
      wgray_r2 <= '0;
    end else begin
      wgray_r1 <= wgray;
      wgray_r2 <= wgray_r1;
      if (r_pop) begin
        rbin  <= rbin + 1'b1;
        rgray <= to_gray(rbin + 1'b1);
      end
    end
  end

endmodule

`default_nettype wire
