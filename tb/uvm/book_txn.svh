class book_txn extends uvm_sequence_item;
  rand byte unsigned     typ;
  rand bit               side;
  rand longint unsigned  orn;
  rand longint unsigned  new_orn;
  rand int unsigned      shares;
  rand int unsigned      price;

  bit                    dropped;
  bit                    rejected;
  bit                    unknown;
  bit                    bid_valid, ask_valid;
  int unsigned           bid_slot, bid_shares, bid_orders;
  int unsigned           ask_slot, ask_shares, ask_orders;
  int unsigned           cycles;
  wr_t                   writes[$];

  constraint c_type { typ inside {"A", "F", "E", "C", "X", "D", "U"}; }

  `uvm_object_utils(book_txn)

  function new(string name = "book_txn");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("%c side %0d orn %0d new_orn %0d shares %0d price %0d",
                     typ, side, orn, new_orn, shares, price);
  endfunction
endclass
