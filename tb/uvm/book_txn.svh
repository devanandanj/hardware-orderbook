// One ITCH command, plus the book state the monitor observed at its commit.

typedef struct {
    bit [63:0] oref;
    bit [31:0] price;
    bit [31:0] qty;
} order_t;

class book_txn extends uvm_sequence_item;
    `uvm_object_utils(book_txn)

    // ---- command (driven) ----
    rand bit [7:0]  typ;
    rand bit        side;      // A only
    rand bit [63:0] oref;      // A, D, E; U: original
    rand bit [63:0] new_ref;   // U
    rand bit [31:0] shares;
    rand bit [31:0] price;
    rand bit [31:0] exe;
    rand bit        gap;       // pulse mold_gap alongside this command

    constraint c_typ    { typ inside {T_ADD, T_DEL, T_EXE, T_REP}; }
    constraint c_mix    { typ dist {T_ADD := 6, T_DEL := 1, T_EXE := 2, T_REP := 1}; }
    // A 20-tick band so price ties and evictions happen constantly.
    constraint c_price  { price inside {[1000:1019]}; }
    constraint c_shares { shares inside {[1:499]}; exe inside {[1:599]}; }
    constraint c_gap    { gap dist {1'b0 := 199, 1'b1 := 1}; }

    // ---- observed at commit (monitor) ----
    bit     unknown;
    bit     gap_seen;
    bit     full_bid, full_ask;
    int     bid_count, ask_count;
    order_t bids[$];           // sorted ascending by oref
    order_t asks[$];

    function new(string name = "book_txn");
        super.new(name);
    endfunction

    function string convert2string();
        return $sformatf("%c side=%0d ref=%0d new_ref=%0d shares=%0d price=%0d exe=%0d gap=%0d",
                         typ, side, oref, new_ref, shares, price, exe, gap);
    endfunction
endclass
