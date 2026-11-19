class book_base_seq extends uvm_sequence #(book_txn);
  `uvm_object_utils(book_base_seq)

  // Shared by every sequence in a test: ORNs stay unique, as the feed guarantees.
  static longint unsigned next_orn = 1;
  static int unsigned     live[longint unsigned];

  function new(string name = "book_base_seq");
    super.new(name);
  endfunction

  function longint unsigned fresh();
    return next_orn++;
  endfunction

  function longint unsigned fresh_in(int unsigned set);
    while (set_of(next_orn) != set) next_orn++;
    return next_orn++;
  endfunction

  function longint unsigned never_added();
    return {1'b1, 31'($urandom), 32'($urandom)};
  endfunction

  function longint unsigned any_live();
    longint unsigned k;
    int i = $urandom_range(live.num() - 1);
    void'(live.first(k));
    repeat (i) void'(live.next(k));
    return k;
  endfunction

  task send(byte unsigned typ, bit side, longint unsigned orn, int unsigned shares = 100,
            int unsigned price = 0, longint unsigned new_orn = 0);
    book_txn t = book_txn::type_id::create("t");
    start_item(t);
    t.typ     = typ;
    t.side    = side;
    t.orn     = orn;
    t.new_orn = new_orn;
    t.shares  = shares;
    t.price   = price;
    finish_item(t);
    case (typ)
      "A", "F": if (!t.dropped && !t.rejected) live[orn] = shares;
      "E", "C", "X":
      if (live.exists(orn)) begin
        if (shares >= live[orn]) live.delete(orn);
        else live[orn] -= shares;
      end
      "D": live.delete(orn);
      "U": begin
        live.delete(orn);
        if (!t.unknown && !t.dropped && !t.rejected) live[new_orn] = shares;
      end
      default: ;
    endcase
  endtask

  task add(bit side, longint unsigned orn, int k, int unsigned shares = 100);
    send("A", side, orn, shares, price_of(BASE, k));
  endtask
endclass

class book_corner_seq extends book_base_seq;
  `uvm_object_utils(book_corner_seq)

  function new(string name = "book_corner_seq");
    super.new(name);
  endfunction

  task body();
    string rm = "ECX", miss = "ECXDU";
    longint unsigned o[$], a, b;
    int k = CENTER;

    // A set's ways, then the CAM, then drops; freed entries are reused.
    repeat (WAYS + CAM_N + 2) o.push_back(fresh_in(5));
    foreach (o[i]) add(i % 2, o[i], k + i % 4, 10 + i);
    send("D", 0, o[0]);
    send("X", 1, o[WAYS + 1], 1000);
    add(0, fresh_in(5), k);
    add(1, fresh_in(5), k + 1);
    add(0, fresh_in(5), k);
    foreach (o[i]) send("D", 0, o[i]);

    // Price range edges and the tick grid.
    add(0, fresh(), 0);
    add(1, fresh(), SLOTS - 1);
    add(0, fresh(), -1);
    add(1, fresh(), SLOTS);
    send("A", 0, fresh(), 100, price_of(BASE, k) + 1);
    send("F", 1, fresh(), 100, price_of(BASE, k) - TICK / 2);
    send("A", 0, fresh(), 100, 0);
    send("A", 0, fresh(), 0, price_of(BASE, k));

    // Partial, exact and over-size removes.
    foreach (rm[i]) begin
      a = fresh();
      add(0, a, k - 3, 300);
      send(rm[i], 0, a, 100);
      send(rm[i], 0, a, 200);
      a = fresh();
      add(1, a, k + 3, 300);
      send(rm[i], 1, a, 301);
    end

    // References to orders that are not on the book.
    foreach (miss[i]) send(miss[i], 0, never_added(), 50, price_of(BASE, k), fresh());

    // Replace: same level, new level, into a full set, to an off-grid price.
    a = fresh();
    add(0, a, k - 1, 100);
    b = fresh();
    send("U", 0, a, 150, price_of(BASE, k - 1), b);
    a = fresh();
    send("U", 0, b, 150, price_of(BASE, k + 2), a);
    o.delete();
    repeat (WAYS + CAM_N) o.push_back(fresh_in(9));
    foreach (o[i]) add(1, o[i], k + 10, 5);
    send("U", 0, a, 70, price_of(BASE, k + 1), fresh_in(9));
    a = fresh();
    add(0, a, k - 2);
    send("U", 0, a, 70, price_of(BASE, k) + 7, fresh());
    a = fresh();
    add(1, a, k + 4);
    send("U", 0, a, 70, price_of(BASE, SLOTS), fresh());
    foreach (o[i]) send("D", 0, o[i]);

    // Stacked levels: remove the best and the book rescans to the next; then empty each side.
    o.delete();
    for (int i = 0; i < 6; i++) begin
      o.push_back(fresh());
      add(i % 2, o[$], i % 2 ? k + 20 + i / 2 * 300 : k - 20 - i / 2 * 300);
    end
    o.push_back(fresh());
    add(0, o[$], k - 20);
    foreach (o[i]) send("D", 0, o[i]);
    while (live.num() != 0) send("D", 0, any_live());
  endtask
endclass

class book_random_seq extends book_base_seq;
  `uvm_object_utils(book_random_seq)

  int unsigned count = 20000;

  function new(string name = "book_random_seq");
    super.new(name);
  endfunction

  function longint unsigned new_orn();
    return $urandom_range(9) < 2 ? fresh_in($urandom_range(3)) : fresh();
  endfunction

  function int unsigned rand_price();
    int k = CENTER + $urandom_range(80) - 40;
    case ($urandom_range(49))
      0: return price_of(BASE, k) + 1;
      1: return price_of(BASE, $urandom_range(1) ? -1 - $urandom_range(5) : SLOTS + $urandom_range(5));
      2: return price_of(BASE, $urandom_range(SLOTS - 1));
      default: return price_of(BASE, k);
    endcase
  endfunction

  function longint unsigned old_orn();
    return live.num() == 0 || $urandom_range(9) == 0 ? never_added() : any_live();
  endfunction

  task body();
    string rm = "ECX";
    longint unsigned o;
    repeat (count) begin
      int r = $urandom_range(99);
      if (r < 35 || live.num() < 20)
        send($urandom_range(3) ? "A" : "F", $urandom_range(1), new_orn(), $urandom_range(1000, 1),
             rand_price());
      else if (r < 75) begin
        o = old_orn();
        send(rm[$urandom_range(2)], 0, o,
             live.exists(o) && $urandom_range(1) ? live[o] + $urandom_range(2) - 1 : $urandom_range(500, 1));
      end else if (r < 90) send("D", 0, old_orn());
      else send("U", 0, old_orn(), $urandom_range(1000, 1), rand_price(), new_orn());
    end
  endtask
endclass
