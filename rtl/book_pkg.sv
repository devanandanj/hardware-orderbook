// book_pkg.sv -- types shared by the v3 book RTL.
//
// Geometry comes from spec/book.yaml through itch_defs.vh. Keep memories
// plain vectors and assign them to and from entry_t directly: Yosys 0.33
// silently drops a memory declared as an array of structs, and rejects
// the entry_t'(x) cast.

`ifndef BOOK_PKG_SV
`define BOOK_PKG_SV

`include "itch_defs.vh"

package book_pkg;

    // Field order is spec/book.yaml's, MSB first.
    typedef struct packed {
        logic                    valid;
        logic [63:0]             orn;
        logic                    side;
        logic [`BOOK_SLOT_W-1:0] slot;
        logic [31:0]             shares;
    } entry_t;

endpackage

`endif // BOOK_PKG_SV
