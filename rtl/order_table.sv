/*
 *
 *   Order Table
 *   github/devanandanj
 *
 *
 */

`include "book_pkg.sv"

`default_nettype none

module order_table (
    input wire logic clk,
    input wire logic rst,
    output logic ready,

    input  wire logic                    req_valid,
    input  wire logic [            63:0] req_orn,
    output logic                         rsp_valid,
    output logic      [`BOOK_HASH_W-1:0] rsp_set,

    output logic                   rsp_hit,
    output logic                   rsp_hit_cam,
    output logic             [3:0] rsp_hit_idx,
    output book_pkg::entry_t       rsp_hit_entry,

    output logic       rsp_free,
    output logic       rsp_free_cam,
    output logic [3:0] rsp_free_idx,

    input wire logic                                wr_valid,
    input wire logic                                wr_cam,
    input wire logic             [`BOOK_HASH_W-1:0] wr_set,
    input wire logic             [             3:0] wr_idx,
    input wire book_pkg::entry_t                    wr_entry
);

  localparam int HASH_W  = `BOOK_HASH_W;
  localparam int SETS    = `BOOK_SETS;
  localparam int WAYS    = `BOOK_WAYS;
  localparam int CAM_N   = `BOOK_CAM_DEPTH;
  localparam int ENTRY_W = `BOOK_ENTRY_W;

  function automatic logic [HASH_W-1:0] hash(input logic [63:0] orn);
    hash = '0;
    for (int i = 0; i < 64; i++) hash[i%HASH_W] ^= orn[i];
  endfunction

  // Plain vectors and bit positions, in entry_t's order: Yosys accepts
  // neither a struct in a generate block nor a struct function argument.
  localparam int VALID = ENTRY_W - 1;
  localparam int ORN_L = VALID - 64;

  function automatic logic is_hit(input logic [ENTRY_W-1:0] e, input logic [63:0] orn);
    is_hit = e[VALID] && e[VALID-1:ORN_L] == orn;
  endfunction

  function automatic logic is_free(input logic [ENTRY_W-1:0] e);
    is_free = !e[VALID];
  endfunction

  logic              clearing;
  logic [HASH_W-1:0] clear_set;

  assign ready = !clearing;

  always_ff @(posedge clk) begin
    if (rst) begin
      clearing  <= 1'b1;
      clear_set <= '0;
    end else if (clearing) begin
      clear_set <= clear_set + 1'b1;
      if (&clear_set) clearing <= 1'b0;
    end
  end

  wire               wr_ok = wr_valid && !clearing;

  wire  [HASH_W-1:0] req_set = hash(req_orn);

  logic              s1_valid;
  logic [      63:0] s1_orn;
  logic [HASH_W-1:0] s1_set;

  always_ff @(posedge clk) begin
    s1_valid <= req_valid && !clearing && !rst;
    s1_orn   <= req_orn;
    s1_set   <= req_set;
  end

  logic [WAYS*ENTRY_W-1:0] way_rd;
  logic [        WAYS-1:0] way_hit;
  logic [        WAYS-1:0] way_free;

  wire  [      HASH_W-1:0] bank_addr = clearing ? clear_set : wr_set;
  wire  [     ENTRY_W-1:0] bank_data = clearing ? '0 : wr_entry;

  genvar w;
  generate
    for (w = 0; w < WAYS; w = w + 1) begin : g_way
      // Plain vector: Yosys drops a memory declared as an array of structs.
      logic [ENTRY_W-1:0] mem                                                [0:SETS-1];

      wire                we = clearing || (wr_ok && !wr_cam && wr_idx == w);

      always_ff @(posedge clk) begin
        if (we) mem[bank_addr] <= bank_data;
        way_rd[w*ENTRY_W+:ENTRY_W] <= mem[req_set];
      end

      assign way_hit[w]  = is_hit(way_rd[w*ENTRY_W+:ENTRY_W], s1_orn);
      assign way_free[w] = is_free(way_rd[w*ENTRY_W+:ENTRY_W]);
    end
  endgenerate

  logic [CAM_N*ENTRY_W-1:0] cam;
  logic [        CAM_N-1:0] cam_hit, cam_hit_nx;
  logic [        CAM_N-1:0] cam_free, cam_free_nx;

  always_ff @(posedge clk) begin
    if (rst) cam <= '0;
    else
      for (int k = 0; k < CAM_N; k++)
        if (wr_ok && wr_cam && wr_idx == k) cam[k*ENTRY_W+:ENTRY_W] <= wr_entry;
  end

  genvar c;
  generate
    for (c = 0; c < CAM_N; c = c + 1) begin : g_cam
      assign cam_hit_nx[c]  = is_hit(cam[c*ENTRY_W+:ENTRY_W], req_orn);
      assign cam_free_nx[c] = is_free(cam[c*ENTRY_W+:ENTRY_W]);
    end
  endgenerate

  always_ff @(posedge clk) begin
    cam_hit  <= cam_hit_nx;
    cam_free <= cam_free_nx;
  end

  logic                     s2_valid;
  logic [       HASH_W-1:0] s2_set;
  logic [WAYS*ENTRY_W-1:0]  s2_way;
  logic [         WAYS-1:0] s2_way_hit, s2_way_free;
  logic [        CAM_N-1:0] s2_cam_hit, s2_cam_free;

  always_ff @(posedge clk) begin
    s2_valid    <= s1_valid && !rst;
    s2_set      <= s1_set;
    s2_way      <= way_rd;
    s2_way_hit  <= way_hit;
    s2_way_free <= way_free;
    s2_cam_hit  <= cam_hit;
    s2_cam_free <= cam_free;
  end

  logic hit, hit_cam, free, free_cam;
  logic [3:0] hit_idx, free_idx;
  book_pkg::entry_t hit_entry;

  always_comb begin
    hit       = 1'b0;
    hit_cam   = 1'b0;
    hit_idx   = '0;
    hit_entry = '0;
    free      = 1'b0;
    free_cam  = 1'b0;
    free_idx  = '0;

    for (int i = CAM_N - 1; i >= 0; i--) begin
      if (s2_cam_hit[i]) begin
        hit       = 1'b1;
        hit_cam   = 1'b1;
        hit_idx   = i[3:0];
        hit_entry = cam[i*ENTRY_W+:ENTRY_W];
      end
      if (s2_cam_free[i]) begin
        free     = 1'b1;
        free_cam = 1'b1;
        free_idx = i[3:0];
      end
    end

    for (int i = WAYS - 1; i >= 0; i--) begin
      if (s2_way_hit[i]) begin
        hit       = 1'b1;
        hit_cam   = 1'b0;
        hit_idx   = i[3:0];
        hit_entry = s2_way[i*ENTRY_W+:ENTRY_W];
      end
      if (s2_way_free[i]) begin
        free     = 1'b1;
        free_cam = 1'b0;
        free_idx = i[3:0];
      end
    end
  end

  always_ff @(posedge clk) begin
    rsp_valid     <= s2_valid && !rst;
    rsp_set       <= s2_set;
    rsp_hit       <= hit;
    rsp_hit_cam   <= hit_cam;
    rsp_hit_idx   <= hit_idx;
    rsp_hit_entry <= hit_entry;
    rsp_free      <= free;
    rsp_free_cam  <= free_cam;
    rsp_free_idx  <= free_idx;
  end

endmodule

`default_nettype wire
