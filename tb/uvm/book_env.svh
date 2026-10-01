// Environment and tests.

class book_env extends uvm_env;
    `uvm_component_utils(book_env)

    book_agent      agent;
    book_scoreboard sb;
    book_coverage   cov;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        agent = book_agent::type_id::create("agent", this);
        sb    = book_scoreboard::type_id::create("sb", this);
        cov   = book_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        agent.mon.ap.connect(sb.analysis_export);
        agent.mon.ap.connect(cov.analysis_export);
    endfunction
endclass


class book_base_test extends uvm_test;
    `uvm_component_utils(book_base_test)

    book_env env;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        env = book_env::type_id::create("env", this);
        // One mismatch usually cascades; stop before the log drowns.
        uvm_report_server::get_server().set_max_quit_count(10);
    endfunction

    virtual task run_seqs();
    endtask

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        run_seqs();
        #100ns;  // let the last command commit and reach the scoreboard
        phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server rs = uvm_report_server::get_server();
        if (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL) == 0)
            `uvm_info("TEST", "*** PASSED ***", UVM_NONE)
        else
            `uvm_info("TEST", "*** FAILED ***", UVM_NONE)
    endfunction
endclass


// Directed full-book corners only.
class book_fill_test extends book_base_test;
    `uvm_component_utils(book_fill_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_seqs();
        book_fill_seq seq = book_fill_seq::type_id::create("fill");
        seq.start(env.agent.sqr);
    endtask
endclass


// Regression: directed corners, then a long constrained-random run.
class book_random_test extends book_base_test;
    `uvm_component_utils(book_random_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_seqs();
        book_fill_seq   fill = book_fill_seq::type_id::create("fill");
        book_random_seq rnd  = book_random_seq::type_id::create("rnd");
        fill.start(env.agent.sqr);
        rnd.start(env.agent.sqr);
    endtask
endclass
