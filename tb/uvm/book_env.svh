class book_env extends uvm_env;
  `uvm_component_utils(book_env)

  book_agent      agent;
  book_scoreboard sb;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    agent = book_agent::type_id::create("agent", this);
    sb    = book_scoreboard::type_id::create("sb", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    agent.mon.ap.connect(sb.analysis_export);
  endfunction
endclass
