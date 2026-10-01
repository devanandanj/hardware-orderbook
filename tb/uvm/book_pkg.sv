`include "book_defs.svh"

package book_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    localparam bit [7:0] T_ADD = "A", T_DEL = "D", T_EXE = "E", T_REP = "U";

    // golden_dpi.cpp return codes.
    localparam int G_OK = 0, G_UNKNOWN = 1, G_EVICTED = 2, G_DISCARDED = 3;

    import "DPI-C" function void golden_reset();
    import "DPI-C" function int  golden_apply(byte unsigned typ, byte unsigned side,
                                              longint unsigned oref, longint unsigned new_ref,
                                              int unsigned shares, int unsigned price,
                                              int unsigned exe);
    import "DPI-C" function int  golden_count(byte unsigned side);
    import "DPI-C" function void golden_get(byte unsigned side, int idx,
                                            output longint unsigned oref,
                                            output int unsigned price,
                                            output int unsigned qty);

    `include "book_txn.svh"
    `include "book_seqs.svh"
    `include "book_agent.svh"
    `include "book_scoreboard.svh"
    `include "book_env.svh"
endpackage
