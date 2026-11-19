`include "itch_defs.vh"
`include "uvm_macros.svh"

package book_tb_pkg;
  import uvm_pkg::*;

  import "DPI-C" function void golden_reset(int unsigned base_price);
  import "DPI-C" function int golden_apply(byte unsigned typ, byte unsigned side, longint unsigned oref,
                                           longint unsigned new_ref, int unsigned shares, int unsigned price);
  import "DPI-C" function void golden_bbo(output int unsigned bid_price, output int unsigned bid_shares,
                                          output int unsigned bid_orders, output int unsigned ask_price,
                                          output int unsigned ask_shares, output int unsigned ask_orders);
  import "DPI-C" function int golden_write_count();
  import "DPI-C" function void golden_write_get(int i, output int unsigned target, output int unsigned index,
                                                output int unsigned valid, output longint unsigned oref,
                                                output int unsigned side, output int unsigned slot,
                                                output int unsigned shares, output int unsigned orders);
  import "DPI-C" function int unsigned golden_sets();
  import "DPI-C" function int unsigned golden_ways();
  import "DPI-C" function int unsigned golden_cam_depth();
  import "DPI-C" function int unsigned golden_slots();
  import "DPI-C" function int unsigned golden_tick();

  localparam int unsigned TICK   = `BOOK_PRICE_TICK;
  localparam int unsigned SLOTS  = `BOOK_SLOTS;
  localparam int unsigned CENTER = `BOOK_SLOT_CENTER;
  localparam int unsigned SETS   = `BOOK_SETS;
  localparam int unsigned WAYS   = `BOOK_WAYS;
  localparam int unsigned CAM_N  = `BOOK_CAM_DEPTH;
  localparam int unsigned BASE   = 3_000_000;

  typedef enum int unsigned {W_TABLE = 0, W_CAM = 1, W_BID = 2, W_ASK = 3} wr_target_e;

  typedef struct packed {
    wr_target_e      target;
    int unsigned     index;
    bit              valid;
    longint unsigned orn;
    bit              side;
    int unsigned     slot;
    int unsigned     shares;
    int unsigned     orders;
  } wr_t;

  function automatic int unsigned set_of(longint unsigned orn);
    bit [`BOOK_HASH_W-1:0] h = '0;
    for (int i = 0; i < 64; i++) h[i % `BOOK_HASH_W] ^= orn[i];
    return h;
  endfunction

  function automatic int unsigned price_of(int unsigned base, int k);
    return int'(base) + (k - int'(CENTER)) * int'(TICK);
  endfunction

  function automatic int unsigned budget(byte unsigned t);
    case (t)
      "A": return 38;
      "F": return 42;
      "E": return 33;
      "C": return 38;
      "X": return 25;
      "D": return 21;
      "U": return 37;
      default: return 8;
    endcase
  endfunction

  function automatic string wr_str(wr_t w);
    if (w.target inside {W_BID, W_ASK})
      return $sformatf("%s[%0d] = %0d shares, %0d orders", w.target.name(), w.index, w.shares, w.orders);
    return $sformatf("%s[%0d] = valid %0d orn %0d side %0d slot %0d shares %0d",
                     w.target.name(), w.index, w.valid, w.orn, w.side, w.slot, w.shares);
  endfunction

  `include "book_txn.svh"
  `include "book_agent.svh"
  `include "book_scoreboard.svh"
  `include "book_env.svh"
  `include "book_seqs.svh"
  `include "book_tests.svh"
endpackage
