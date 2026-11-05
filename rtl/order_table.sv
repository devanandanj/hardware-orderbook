`include "book_pkg.sv"

`default_nettype none

module order_table (
    input  logic                    clk,
    input  logic                    rst,
    output logic                    ready,         // low during the post-reset clear

    // Lookup: fixed 2-cycle latency, no backpressure
    input  logic                    req_valid,
    input  logic [63:0]             req_orn,
    output logic                    rsp_valid,
    output logic [`BOOK_HASH_W-1:0] rsp_set,

    output logic                    rsp_hit,       // TableFind: ways, then CAM
    output logic                    rsp_hit_cam,
    output logic [3:0]              rsp_hit_idx,   // way or CAM entry
    output book_pkg::entry_t        rsp_hit_entry,

    output logic                    rsp_free,      // TableFindFree: empty way, then CAM
    output logic                    rsp_free_cam,
    output logic [3:0]              rsp_free_idx,

    // Write: the book FSM supplies the location and the whole entry
    input  logic                    wr_valid,
    input  logic                    wr_cam,
    input  logic [`BOOK_HASH_W-1:0] wr_set,
    input  logic [3:0]              wr_idx,
    input  book_pkg::entry_t        wr_entry
);



endmodule
