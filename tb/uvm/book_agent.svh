// Active agent: sequencer + driver + monitor on book_if.

typedef uvm_sequencer #(book_txn) book_sequencer;


class book_driver extends uvm_driver #(book_txn);
    `uvm_component_utils(book_driver)

    virtual book_if vif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        if (!uvm_config_db #(virtual book_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "book_if not set")
    endfunction

    task run_phase(uvm_phase phase);
        // Directly, not via the clocking block: reset must be valid before
        // the first edge, or the interface assertions see rst == X.
        vif.rst = 1'b1;
        vif.drv_cb.cmd_valid <= 1'b0;
        vif.drv_cb.mold_gap  <= 1'b0;
        repeat (4) @(vif.drv_cb);
        vif.drv_cb.rst <= 1'b0;
        @(vif.drv_cb);

        // One command per cycle while the sequence has them; idle otherwise.
        forever begin
            seq_item_port.try_next_item(req);
            if (req == null) begin
                vif.drv_cb.cmd_valid <= 1'b0;
                vif.drv_cb.mold_gap  <= 1'b0;
                @(vif.drv_cb);
                continue;
            end
            vif.drv_cb.cmd_valid         <= 1'b1;
            vif.drv_cb.cmd_type          <= req.typ;
            vif.drv_cb.cmd_side          <= req.side;
            vif.drv_cb.cmd_order_ref     <= req.oref;
            vif.drv_cb.cmd_new_order_ref <= req.new_ref;
            vif.drv_cb.cmd_shares        <= req.shares;
            vif.drv_cb.cmd_price         <= req.price;
            vif.drv_cb.cmd_exec_shares   <= req.exe;
            vif.drv_cb.mold_gap          <= req.gap;
            // book.v is always ready; waiting on cmd_ready keeps the driver
            // correct if that ever changes.
            do @(vif.drv_cb); while (!vif.drv_cb.cmd_ready);
            seq_item_port.item_done();
        end
    endtask
endclass


// Pairs each accepted command with the state at its commit one cycle later.
class book_monitor extends uvm_monitor;
    `uvm_component_utils(book_monitor)

    virtual book_if vif;
    uvm_analysis_port #(book_txn) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        if (!uvm_config_db #(virtual book_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "book_if not set")
    endfunction

    function void read_side(bit [`BOOK_MAX-1:0] valid,
                            bit [64*`BOOK_MAX-1:0] refs,
                            bit [32*`BOOK_MAX-1:0] prices,
                            bit [32*`BOOK_MAX-1:0] qtys,
                            ref order_t out[$]);
        out.delete();
        for (int i = 0; i < `BOOK_MAX; i++)
            if (valid[i])
                out.push_back('{refs[64*i +: 64], prices[32*i +: 32], qtys[32*i +: 32]});
        out.sort() with (item.oref);
    endfunction

    task run_phase(uvm_phase phase);
        book_txn pending;
        forever begin
            @(vif.mon_cb);
            if (vif.mon_cb.rst) begin
                pending = null;
                continue;
            end

            if (vif.mon_cb.commit) begin
                if (pending == null)
                    `uvm_error("MON", "commit with no accepted command")
                else begin
                    pending.unknown   = vif.mon_cb.unknown_order_ref;
                    pending.gap_seen  = vif.mon_cb.mold_gap_seen;
                    pending.full_bid  = vif.mon_cb.book_full_bid;
                    pending.full_ask  = vif.mon_cb.book_full_ask;
                    pending.bid_count = vif.mon_cb.bid_count;
                    pending.ask_count = vif.mon_cb.ask_count;
                    read_side(vif.mon_cb.slot_valid_bid, vif.mon_cb.slot_ref_bid_flat,
                              vif.mon_cb.slot_price_bid_flat, vif.mon_cb.slot_qty_bid_flat,
                              pending.bids);
                    read_side(vif.mon_cb.slot_valid_ask, vif.mon_cb.slot_ref_ask_flat,
                              vif.mon_cb.slot_price_ask_flat, vif.mon_cb.slot_qty_ask_flat,
                              pending.asks);
                    ap.write(pending);
                end
                pending = null;
            end

            if (vif.mon_cb.cmd_valid && vif.mon_cb.cmd_ready) begin
                pending = book_txn::type_id::create("observed");
                pending.typ     = vif.mon_cb.cmd_type;
                pending.side    = vif.mon_cb.cmd_side;
                pending.oref    = vif.mon_cb.cmd_order_ref;
                pending.new_ref = vif.mon_cb.cmd_new_order_ref;
                pending.shares  = vif.mon_cb.cmd_shares;
                pending.price   = vif.mon_cb.cmd_price;
                pending.exe     = vif.mon_cb.cmd_exec_shares;
                pending.gap     = vif.mon_cb.mold_gap;
            end
        end
    endtask
endclass


class book_agent extends uvm_agent;
    `uvm_component_utils(book_agent)

    book_sequencer sqr;
    book_driver    drv;
    book_monitor   mon;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        sqr = book_sequencer::type_id::create("sqr", this);
        drv = book_driver::type_id::create("drv", this);
        mon = book_monitor::type_id::create("mon", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass
