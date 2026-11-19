class book_scoreboard extends uvm_subscriber #(book_txn);
  `uvm_component_utils(book_scoreboard)

  int unsigned n, cam_writes, drops, rejects, unknowns;

  typedef enum {O_OK, O_DROPPED, O_REJECTED, O_UNKNOWN} outcome_e;
  outcome_e outcome;
  bit       cam_hit, full_remove, bbo_moved;
  byte unsigned typ;

  covergroup cg;
    cp_type: coverpoint typ {bins t[] = {"A", "F", "E", "C", "X", "D", "U"};}
    cp_outcome: coverpoint outcome;
    cp_cam: coverpoint cam_hit;
    cp_remove: coverpoint full_remove iff (typ inside {"E", "C", "X"});
    cp_bbo: coverpoint bbo_moved;
    type_x_outcome: cross cp_type, cp_outcome {
      ignore_bins add_unknown = binsof(cp_type) intersect {"A", "F"} && binsof(cp_outcome) intersect {O_UNKNOWN};
      ignore_bins rem_drop = binsof(cp_type) intersect {"E", "C", "X", "D"} &&
                             binsof(cp_outcome) intersect {O_DROPPED, O_REJECTED};
    }
  endgroup

  int unsigned last_bid, last_ask;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg = new();
  endfunction

  function void start_of_simulation_phase(uvm_phase phase);
    if (golden_sets() != SETS || golden_ways() != WAYS || golden_cam_depth() != CAM_N ||
        golden_slots() != SLOTS || golden_tick() != TICK)
      `uvm_fatal("GEOM", "golden and itch_defs.vh disagree on the book geometry")
    golden_reset(BASE);
  endfunction

  function void check_side(string name, bit valid, int unsigned slot, int unsigned shares,
                           int unsigned orders, int unsigned g_price, int unsigned g_shares,
                           int unsigned g_orders, book_txn t);
    bit g_valid = g_orders != 0;
    int unsigned price = valid ? price_of(BASE, slot) : 0;
    if (valid != g_valid || price != g_price || shares != g_shares || orders != g_orders)
      `uvm_error("BBO", $sformatf("%s after %s: rtl valid %0d price %0d %0d/%0d, golden %0d %0d/%0d",
                                  name, t.convert2string(), valid, price, shares, orders, g_price,
                                  g_shares, g_orders))
  endfunction

  function void write(book_txn t);
    int status = golden_apply(t.typ, t.side, t.orn, t.new_orn, t.shares, t.price);
    int unsigned bp, bs, bo, ap, as, ao;
    wr_t g;
    int unsigned target, valid, side;

    n++;
    if (status < 0) `uvm_fatal("GOLD", {"golden rejected ", t.convert2string()})
    if ({t.unknown, t.rejected, t.dropped} != {status[3], status[1], status[0]})
      `uvm_error("STATUS", $sformatf("%s: rtl dropped %0d rejected %0d unknown %0d, golden status %b",
                                     t.convert2string(), t.dropped, t.rejected, t.unknown, status))

    if (t.writes.size() != golden_write_count())
      `uvm_error("WRITES", $sformatf("%s: rtl wrote %0d times, golden %0d", t.convert2string(),
                                     t.writes.size(), golden_write_count()))
    for (int i = 0; i < golden_write_count() && i < t.writes.size(); i++) begin
      golden_write_get(i, target, g.index, valid, g.orn, side, g.slot, g.shares, g.orders);
      g.target = wr_target_e'(target);
      g.valid  = valid;
      g.side   = side;
      if (t.writes[i] != g)
        `uvm_error("WRITES", $sformatf("%s write %0d: rtl %s, golden %s", t.convert2string(), i,
                                       wr_str(t.writes[i]), wr_str(g)))
    end

    golden_bbo(bp, bs, bo, ap, as, ao);
    check_side("bid", t.bid_valid, t.bid_slot, t.bid_shares, t.bid_orders, bp, bs, bo, t);
    check_side("ask", t.ask_valid, t.ask_slot, t.ask_shares, t.ask_orders, ap, as, ao, t);

    if (t.cycles > budget(t.typ))
      `uvm_error("LATENCY", $sformatf("%s took %0d cycles, budget %0d", t.convert2string(), t.cycles,
                                      budget(t.typ)))

    typ         = t.typ;
    outcome     = t.dropped ? O_DROPPED : t.rejected ? O_REJECTED : t.unknown ? O_UNKNOWN : O_OK;
    cam_hit     = 0;
    full_remove = 0;
    foreach (t.writes[i]) begin
      if (t.writes[i].target == W_CAM) cam_hit = 1;
      if (t.writes[i].target inside {W_TABLE, W_CAM} && !t.writes[i].valid) full_remove = 1;
    end
    bbo_moved = {bp, ap} != {last_bid, last_ask};
    {last_bid, last_ask} = {bp, ap};
    cg.sample();

    cam_writes += cam_hit;
    drops      += t.dropped;
    rejects    += t.rejected;
    unknowns   += t.unknown;
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("%0d commands: %0d with CAM writes, %0d dropped, %0d rejected, %0d unknown; coverage %.1f%%",
                              n, cam_writes, drops, rejects, unknowns, cg.get_inst_coverage()), UVM_NONE)
  endfunction
endclass
