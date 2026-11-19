class book_base_test extends uvm_test;
  `uvm_component_utils(book_base_test)

  book_env env;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    env = book_env::type_id::create("env", this);
    uvm_report_server::get_server().set_max_quit_count(10);
  endfunction

  virtual task body();
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    body();
    phase.drop_objection(this);
  endtask

  function void check_phase(uvm_phase phase);
    if (env.sb.cam_writes == 0 || env.sb.drops == 0 || env.sb.rejects == 0 || env.sb.unknowns == 0)
      `uvm_error("TEST", "a corner never happened: CAM writes, drops, rejects and unknowns must all be nonzero")
  endfunction

  function void report_phase(uvm_phase phase);
    uvm_report_server rs = uvm_report_server::get_server();
    if (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL) == 0)
      `uvm_info("TEST", "*** PASSED ***", UVM_NONE)
    else `uvm_info("TEST", "*** FAILED ***", UVM_NONE)
  endfunction
endclass

class book_corner_test extends book_base_test;
  `uvm_component_utils(book_corner_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task body();
    book_corner_seq corner = book_corner_seq::type_id::create("corner");
    corner.start(env.agent.sqr);
  endtask
endclass

class book_random_test extends book_base_test;
  `uvm_component_utils(book_random_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task body();
    book_corner_seq corner = book_corner_seq::type_id::create("corner");
    book_random_seq rnd = book_random_seq::type_id::create("rnd");
    void'($value$plusargs("COUNT=%d", rnd.count));
    corner.start(env.agent.sqr);
    rnd.start(env.agent.sqr);
  endtask
endclass
