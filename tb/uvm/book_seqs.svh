// Sequence library.
//
// Order refs are allocated from one counter shared by every sequence, so
// refs stay unique across a whole test -- the feed guarantee the book relies
// on. `live` is a best-effort pool of recently added refs: evictions and
// full fills leave stale entries in it, which simply become misses.

class book_base_seq extends uvm_sequence #(book_txn);
    `uvm_object_utils(book_base_seq)

    static bit [63:0] next_ref = 1;
    static bit [63:0] live[$];

    function new(string name = "book_base_seq");
        super.new(name);
    endfunction

    function bit [63:0] fresh_ref();
        return next_ref++;
    endfunction

    // A live ref hit_pct% of the time, otherwise one that was never issued
    // (top bit set; the counter never gets there).
    function bit [63:0] pick_ref(int hit_pct);
        if (live.size() != 0 && $urandom_range(99) < hit_pct)
            return live[$urandom_range(live.size() - 1)];
        return {1'b1, 31'($urandom), 32'($urandom)};
    endfunction

    function void forget(bit [63:0] r);
        foreach (live[i])
            if (live[i] == r) begin
                live.delete(i);
                return;
            end
    endfunction

    function void remember(bit [63:0] r);
        live.push_back(r);
        // Keep roughly one book's worth: older entries are mostly evicted.
        if (live.size() > 2 * `BOOK_MAX) void'(live.pop_front());
    endfunction

    // Bookkeeping after a command is sent.
    function void track(book_txn t);
        case (t.typ)
            T_ADD: remember(t.oref);
            T_DEL: forget(t.oref);
            T_REP: begin forget(t.oref); remember(t.new_ref); end
            default: ;
        endcase
    endfunction

    // Send one directed command; unspecified fields stay randomized.
    task send(bit [7:0] typ, bit side, bit [63:0] oref, bit [31:0] price,
              bit [31:0] shares = 100, bit [31:0] exe = 0);
        book_txn t = book_txn::type_id::create("t");
        start_item(t);
        if (!t.randomize() with { gap == 0; })
            `uvm_fatal("RAND", "directed txn randomize failed")
        t.typ     = typ;
        t.side    = side;
        t.oref    = oref;
        t.new_ref = fresh_ref();
        t.price   = price;
        t.shares  = shares;
        t.exe     = exe;
        finish_item(t);
        track(t);
    endtask
endclass


// Constrained-random mix of A/D/E/U, back-to-back.
class book_random_seq extends book_base_seq;
    `uvm_object_utils(book_random_seq)

    int unsigned n_cmds = 5000;
    int unsigned hit_pct = 90;

    function new(string name = "book_random_seq");
        super.new(name);
    endfunction

    task body();
        repeat (n_cmds) begin
            book_txn t = book_txn::type_id::create("t");
            start_item(t);
            if (!t.randomize())
                `uvm_fatal("RAND", "randomize failed")
            t.new_ref = fresh_ref();
            t.oref = (t.typ == T_ADD) ? t.new_ref : pick_ref(hit_pct);
            finish_item(t);
            track(t);
        end
    endtask
endclass


// Directed corner cases per side: fill to capacity, then exercise every
// full-book outcome, then drain.
class book_fill_seq extends book_base_seq;
    `uvm_object_utils(book_fill_seq)

    function new(string name = "book_fill_seq");
        super.new(name);
    endfunction

    task body();
        bit [63:0] refs[$];
        bit [63:0] r;
        int base;

        for (int s = 0; s < 2; s++) begin
            refs.delete();
            // Prices 1000..1063: the worst bid is 1000, the worst ask 1063.
            for (int i = 0; i < `BOOK_MAX; i++) begin
                r = fresh_ref();
                send(T_ADD, s, r, 1000 + i);
                refs.push_back(r);
            end

            base = s ? 1063 : 1000;  // current worst price on this side
            // Equal to the worst: tie keeps the resting order -> discarded.
            send(T_ADD, s, fresh_ref(), base);
            // Worse than the worst -> discarded.
            send(T_ADD, s, fresh_ref(), s ? base + 5 : base - 5);
            // Better than the worst -> evicts it.
            r = fresh_ref();
            send(T_ADD, s, r, s ? 900 : 2000);
            refs.push_back(r);

            // Partial then full execution of one order.
            send(T_EXE, s, refs[10], 0, 0, 40);
            send(T_EXE, s, refs[10], 0, 0, 60);
            // Execution larger than the resting quantity removes it too.
            send(T_EXE, s, refs[11], 0, 0, 1000);
            // Replace keeps the side even though U carries none.
            send(T_REP, !s, refs[12], 1500);   // wrong side bit must be ignored
            // Unknown refs on every lookup command.
            send(T_DEL, s, 64'hFFFF_FFFF_FFFF_FFFF, 0);
            send(T_EXE, s, 64'hFFFF_FFFF_FFFF_FFFE, 0, 0, 1);
            send(T_REP, s, 64'hFFFF_FFFF_FFFF_FFFD, 1000);

            // Drain everything that might still be resting. send() edits
            // `live`, so iterate a copy.
            refs = {refs, live};
            foreach (refs[i]) send(T_DEL, s, refs[i], 0);
            live.delete();
        end
    endtask
endclass
