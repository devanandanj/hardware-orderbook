typedef uvm_sequencer #(book_txn) book_sequencer;

class book_driver extends uvm_driver #(book_txn);
  `uvm_component_utils(book_driver)

  virtual book_if vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual book_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "book_if not set")
  endfunction

  // Idle command inputs carry noise, so a port read without its valid shows up as a mismatch.
  function void noise();
    vif.drv_cb.cmd_type    <= 8'($urandom);
    vif.drv_cb.cmd_side    <= 1'($urandom);
    vif.drv_cb.cmd_orn     <= {$urandom, $urandom};
    vif.drv_cb.cmd_new_orn <= {$urandom, $urandom};
    vif.drv_cb.cmd_shares  <= $urandom;
    vif.drv_cb.cmd_price   <= $urandom;
  endfunction

  task run_phase(uvm_phase phase);
    vif.rst       = 1'b1;
    vif.cmd_valid = 1'b0;
    repeat (4) @(vif.drv_cb);
    vif.rst = 1'b0;

    forever begin
      seq_item_port.get_next_item(req);
      repeat ($urandom_range(2)) begin
        noise();
        @(vif.drv_cb);
      end
      vif.drv_cb.cmd_valid   <= 1'b1;
      vif.drv_cb.cmd_type    <= req.typ;
      vif.drv_cb.cmd_side    <= req.side;
      vif.drv_cb.cmd_orn     <= req.orn;
      vif.drv_cb.cmd_new_orn <= req.new_orn;
      vif.drv_cb.cmd_shares  <= req.shares;
      vif.drv_cb.cmd_price   <= req.price;
      do @(vif.drv_cb); while (!vif.drv_cb.cmd_ready);
      vif.drv_cb.cmd_valid <= 1'b0;
      noise();
      do begin
        @(vif.drv_cb);
        noise();
      end while (!vif.drv_cb.done);
      req.dropped  = vif.drv_cb.order_dropped;
      req.rejected = vif.drv_cb.price_rejected;
      req.unknown  = vif.drv_cb.unknown_order_ref;
      seq_item_port.item_done();
    end
  endtask
endclass

class book_monitor extends uvm_monitor;
  `uvm_component_utils(book_monitor)

  virtual book_if    vif;
  virtual book_wr_if wr;
  uvm_analysis_port #(book_txn) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual book_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "book_if not set")
    if (!uvm_config_db#(virtual book_wr_if)::get(this, "", "wr", wr)) `uvm_fatal("NOVIF", "book_wr_if not set")
  endfunction

  function void capture(book_txn t);
    wr_t w;
    if (wr.mon_cb.tw_valid) begin
      w = '{default: 0, target: W_TABLE};
      w.target = wr.mon_cb.tw_cam ? W_CAM : W_TABLE;
      w.index  = wr.mon_cb.tw_cam ? wr.mon_cb.tw_idx : wr.mon_cb.tw_set * WAYS + wr.mon_cb.tw_idx;
      w.valid  = wr.mon_cb.tw_entry.valid;
      w.orn    = wr.mon_cb.tw_entry.orn;
      w.side   = wr.mon_cb.tw_entry.side;
      w.slot   = wr.mon_cb.tw_entry.slot;
      w.shares = wr.mon_cb.tw_entry.shares;
      if (t == null) `uvm_error("MON", {"write outside a command: ", wr_str(w)})
      else t.writes.push_back(w);
    end
    if (wr.mon_cb.lw_valid) begin
      w = '{default: 0, target: W_TABLE};
      w.target = wr.mon_cb.lw_side ? W_ASK : W_BID;
      w.index  = wr.mon_cb.lw_slot;
      w.shares = wr.mon_cb.lw_shares;
      w.orders = wr.mon_cb.lw_orders;
      if (t == null) `uvm_error("MON", {"write outside a command: ", wr_str(w)})
      else t.writes.push_back(w);
    end
  endfunction

  task run_phase(uvm_phase phase);
    book_txn t;
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.rst) begin
        t = null;
        continue;
      end
      if (t != null) t.cycles++;
      capture(t);
      if (vif.mon_cb.done) begin
        if (t == null) `uvm_error("MON", "done without a command")
        else begin
          t.dropped    = vif.mon_cb.order_dropped;
          t.rejected   = vif.mon_cb.price_rejected;
          t.unknown    = vif.mon_cb.unknown_order_ref;
          t.bid_valid  = vif.mon_cb.bid_valid;
          t.bid_slot   = vif.mon_cb.bid_slot;
          t.bid_shares = vif.mon_cb.bid_shares;
          t.bid_orders = vif.mon_cb.bid_orders;
          t.ask_valid  = vif.mon_cb.ask_valid;
          t.ask_slot   = vif.mon_cb.ask_slot;
          t.ask_shares = vif.mon_cb.ask_shares;
          t.ask_orders = vif.mon_cb.ask_orders;
          ap.write(t);
        end
        t = null;
      end
      if (vif.mon_cb.cmd_valid && vif.mon_cb.cmd_ready) begin
        if (t != null) `uvm_error("MON", "command accepted while busy")
        t         = book_txn::type_id::create("observed");
        t.typ     = vif.mon_cb.cmd_type;
        t.side    = vif.mon_cb.cmd_side;
        t.orn     = vif.mon_cb.cmd_orn;
        t.new_orn = vif.mon_cb.cmd_new_orn;
        t.shares  = vif.mon_cb.cmd_shares;
        t.price   = vif.mon_cb.cmd_price;
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
