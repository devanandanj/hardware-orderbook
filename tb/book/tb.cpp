// tb.cpp -- rtl/book.sv against golden's ApplyCommand.
//
// Every command is applied to both. After each done the testbench checks:
//   - the status bits against golden's Outcome;
//   - every table, CAM and level write, in order, against golden's
//     WriteLog (the RTL's write ports are tapped, so this covers memory
//     contents too);
//   - the BBO against golden's price books;
//   - the cycles from accept to done against the arrival budget.
//
// Contract the RTL is held to:
//   - one command at a time, accepted only while cmd_ready;
//   - exactly one done per command, none at any other time;
//   - after rst, cmd_ready rises within SLOTS + INIT_SLACK cycles.

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

#include "Vbook.h"
#include "Vbook___024root.h"
#include "verilated.h"

#include "book.h"
#include "command.h"
#include "snapshot.h"

// Cycles each command takes to arrive at one byte a clock: its ITCH length
// plus the 2-byte Mold length prefix. The book must finish within it.
static uint32_t Budget(char type) {
	switch (type) {
	case 'A': return 38;
	case 'F': return 42;
	case 'E': return 33;
	case 'C': return 38;
	case 'X': return 25;
	case 'D': return 21;
	case 'U': return 37;
	default:  return 8;
	}
}

static constexpr uint32_t INIT_SLACK = 16;

static Vbook* dut;
static Vbook___024root* root;
static Book gold;
static std::mt19937_64 rng;
static uint64_t cycle;
static bool inCommand;
static std::vector<WriteRecord> writes;
static uint32_t worst[256];

// Reached-state counters; a run that misses one proves nothing about it.
static uint64_t covInsert, covDropped, covRejected, covUnknown, covPartial, covFull,
                covDelete, covReplace, covReplaceDropped, covReplaceRejected,
                covReplaceSameSet, covReplaceSameSlot, covCam, covOther, covEmptied;

[[noreturn]] static void Fail(const char* what) {
	std::printf("FAIL cycle %llu: %s\n", (unsigned long long)cycle, what);
	std::exit(1);
}

static uint64_t Bits(const VlWide<4>& w, int lo, int n) {
	uint64_t v = 0;
	for (int i = 0; i < n; i++) v |= (uint64_t)((w[(lo + i) / 32] >> ((lo + i) % 32)) & 1) << i;
	return v;
}

// Writes the RTL presents this cycle, table before level as in golden.
static void Capture() {
	if (root->book__DOT__tw_valid) {
		const VlWide<4>& e = root->book__DOT__tw_entry;
		WriteRecord r{};
		const bool cam = root->book__DOT__tw_cam;
		r.target = cam ? WriteTarget::Cam : WriteTarget::Table;
		r.index = cam ? root->book__DOT__tw_idx
		              : root->book__DOT__tw_set * WAYS + root->book__DOT__tw_idx;
		r.entry = TableEntry{Bits(e, 111, 1) != 0, Bits(e, 47, 64),
		                     Bits(e, 46, 1) ? Side::Sell : Side::Buy,
		                     (Slot)Bits(e, 32, SLOT_W), (Quantity)Bits(e, 0, 32)};
		writes.push_back(r);
	}
	if (root->book__DOT__lw_valid) {
		WriteRecord r{};
		r.target = root->book__DOT__lw_side ? WriteTarget::Ask : WriteTarget::Bid;
		r.index = root->book__DOT__lw_slot;
		r.level = Level{root->book__DOT__lw_shares, root->book__DOT__lw_orders};
		writes.push_back(r);
	}
}

// One clock. Idle command inputs carry noise, so a port read without its
// valid shows up as a mismatch.
static void Tick() {
	if (!dut->cmd_valid) {
		dut->cmd_type = (uint8_t)rng();
		dut->cmd_side = rng() & 1;
		dut->cmd_orn = rng();
		dut->cmd_new_orn = rng();
		dut->cmd_shares = (uint32_t)rng();
		dut->cmd_price = (uint32_t)rng();
	}
	dut->eval();
	if (!dut->rst) Capture();
	dut->clk = 1;
	dut->eval();
	dut->clk = 0;
	dut->eval();
	cycle++;
	if (dut->done && !inCommand) Fail("done without a command");
}

static bool Same(const WriteRecord& a, const WriteRecord& b) {
	if (a.target != b.target || a.index != b.index) return false;
	if (a.target == WriteTarget::Bid || a.target == WriteTarget::Ask)
		return a.level.shares == b.level.shares && a.level.orders == b.level.orders;
	const TableEntry &x = a.entry, &y = b.entry;
	return x.valid == y.valid && x.orderId == y.orderId && x.side == y.side &&
	       x.slot == y.slot && x.shares == y.shares;
}

static void CheckSide(const PriceBook& pb, bool valid, uint32_t slot, uint32_t shares,
                      uint32_t orders, const char* what) {
	const Level l = pb.hasBest ? pb.levels[pb.best] : Level{};
	if (valid != pb.hasBest || (pb.hasBest && slot != pb.best) || shares != l.shares ||
	    orders != l.orders)
		Fail(what);
}

static void Apply(const Command& c) {
	for (uint32_t n = 0; !dut->cmd_ready; Tick())
		if (++n > 64) Fail("cmd_ready stuck low");

	const bool wasBid = gold.bids.hasBest, wasAsk = gold.asks.hasBest;
	dut->cmd_valid = 1;
	dut->cmd_type = (uint8_t)c.type;
	dut->cmd_side = c.side == Side::Sell;
	dut->cmd_orn = c.orderId;
	dut->cmd_new_orn = c.newOrderId;
	dut->cmd_shares = c.shares;
	dut->cmd_price = c.price;
	writes.clear();
	inCommand = true;
	Tick();
	dut->cmd_valid = 0;

	uint32_t n = 1;
	while (!dut->done) {
		if (++n > Budget(c.type)) {
			std::printf("type %c\n", c.type);
			Fail("over the arrival budget");
		}
		Tick();
	}
	inCommand = false;
	worst[(uint8_t)c.type] = std::max(worst[(uint8_t)c.type], n);

	const Outcome o = ApplyCommand(&gold, c);
	if (dut->order_dropped != ((o.status >> SNAP_STATUS_ORDER_DROPPED) & 1)) Fail("order_dropped");
	if (dut->price_rejected != ((o.status >> SNAP_STATUS_PRICE_REJECTED) & 1)) Fail("price_rejected");
	if (dut->unknown_order_ref != ((o.status >> SNAP_STATUS_UNKNOWN_ORDER_REF) & 1))
		Fail("unknown_order_ref");

	if (writes.size() != gold.log.count) {
		std::printf("type %c: rtl %zu writes, golden %u\n", c.type, writes.size(), gold.log.count);
		Fail("write count");
	}
	for (uint32_t i = 0; i < gold.log.count; i++)
		if (!Same(writes[i], gold.log.records[i])) {
			for (uint32_t j = 0; j < gold.log.count; j++) {
				const WriteRecord &a = writes[j], &b = gold.log.records[j];
				std::printf("  %u rtl t%d i%u v%d o%llx s%d sl%u sh%u L%u/%u | gold t%d i%u v%d o%llx s%d sl%u sh%u L%u/%u\n", j,
				    (int)a.target, a.index, a.entry.valid, (unsigned long long)a.entry.orderId, (int)a.entry.side, a.entry.slot, a.entry.shares, a.level.shares, a.level.orders,
				    (int)b.target, b.index, b.entry.valid, (unsigned long long)b.entry.orderId, (int)b.entry.side, b.entry.slot, b.entry.shares, b.level.shares, b.level.orders);
			}
			std::printf("type %c write %u\n", c.type, i);
			Fail("write mismatch");
		}

	CheckSide(gold.bids, dut->bid_valid, dut->bid_slot, dut->bid_shares, dut->bid_orders, "bid");
	CheckSide(gold.asks, dut->ask_valid, dut->ask_slot, dut->ask_shares, dut->ask_orders, "ask");

	for (const WriteRecord& w : writes)
		if (w.target == WriteTarget::Cam) covCam++;
	if ((wasBid && !gold.bids.hasBest) || (wasAsk && !gold.asks.hasBest)) covEmptied++;
	const bool bad = o.status != 0;
	switch (c.type) {
	case 'A': case 'F':
		if (o.status & (1 << SNAP_STATUS_ORDER_DROPPED)) covDropped++;
		else if (o.status & (1 << SNAP_STATUS_PRICE_REJECTED)) covRejected++;
		else covInsert++;
		break;
	case 'U':
		if (o.status & (1 << SNAP_STATUS_ORDER_DROPPED)) covReplaceDropped++;
		else if (o.status & (1 << SNAP_STATUS_PRICE_REJECTED)) covReplaceRejected++;
		else if (!bad) covReplace++;
		break;
	case 'D':
		if (!bad) covDelete++;
		break;
	case 'E': case 'C': case 'X':
		if (!bad) (gold.log.count && !gold.log.records[0].entry.valid ? covFull : covPartial)++;
		break;
	default:
		covOther++;
	}
	if (o.status & (1 << SNAP_STATUS_UNKNOWN_ORDER_REF)) covUnknown++;
}

static void Reset(Price base) {
	dut->cmd_valid = 0;
	dut->base_price = base;
	dut->rst = 1;
	for (int i = 0; i < 4; i++) Tick();
	if (dut->cmd_ready) Fail("cmd_ready high in reset");
	dut->rst = 0;
	uint32_t n = 0;
	for (Tick(); !dut->cmd_ready; Tick())
		if (++n > SLOTS + INIT_SLACK) Fail("cmd_ready never rose after reset");
	ResetBook(&gold, base);
}

// ---- Command builders ----

static Price At(int32_t ticks) { return gold.basePrice + (Price)(ticks * (int32_t)PRICE_TICK); }

static void Add(OrderId orn, Side side, Price price, Quantity q) {
	Apply(Command{'A', side, orn, 0, q, price});
}
static void Reduce(char type, OrderId orn, Quantity q) { Apply(Command{type, Side::Buy, orn, 0, q, 0}); }
static void Delete(OrderId orn) { Apply(Command{'D', Side::Buy, orn, 0, 0, 0}); }
static void Replace(OrderId orn, OrderId neu, Price price, Quantity q) {
	Apply(Command{'U', Side::Buy, orn, neu, q, price});
}

// Same set as orn: flipping bit k and bit k+HASH_W cancels in the fold.
static OrderId Twin(OrderId orn, uint32_t k) { return orn ^ ((uint64_t)k * ((1u << HASH_W) | 1u)); }

// ---- Directed ----

static void TestBasic() {
	Reset(1000000);
	Add(1, Side::Buy, At(-1), 100);
	Add(2, Side::Sell, At(1), 200);
	Add(3, Side::Buy, At(-1), 50);
	Reduce('X', 1, 30);              // partial
	Reduce('E', 3, 50);              // exactly all
	Reduce('C', 2, 500);             // more than all
	Delete(1);                       // bids empty
	Delete(1);                       // unknown
	Reduce('E', 99, 1);              // unknown
	Replace(99, 100, At(0), 1);      // unknown
	Apply(Command{'S', Side::Buy, 5, 6, 7, 8});
	Apply(Command{'F', Side::Sell, 7, 0, 10, At(3)});
	Delete(7);
}

// U onto the same level, the same set, and the same entry the old order held.
static void TestReplace() {
	Reset(5000000);
	Add(10, Side::Sell, At(4), 100);
	Replace(10, 11, At(4), 70);               // level empties, refills
	covReplaceSameSlot++;
	Replace(11, Twin(11, 5), At(4), 60);      // same set, reuses the way
	covReplaceSameSet++;
	Add(20, Side::Buy, At(-2), 5);
	Add(21, Side::Buy, At(-2), 5);
	Replace(20, 22, At(-3), 9);               // best level loses one order
	Replace(21, 23, At(-2) + 1, 9);           // off tick: rejected, old gone
	Replace(22, 24, At(-9000), 9);            // out of window: rejected
	Add(30, Side::Buy, 0, 1);                 // price below the window
	Add(31, Side::Buy, 0xFFFFFFFF, 1);
}

// Fill one set and the whole CAM, then free and reuse entries.
static void TestFull() {
	Reset(2000000);
	const OrderId base = 0x123456789ABCDEFull;
	const uint32_t n = WAYS + CAM_DEPTH;
	for (uint32_t k = 0; k < n; k++) Add(Twin(base, k), (Side)(k & 1), At((int32_t)k - 5), k + 1);
	Add(Twin(base, n), Side::Buy, At(0), 1);              // dropped
	Replace(Twin(base, 0), Twin(base, n + 1), At(0), 3);  // reuses way 0
	Add(Twin(base, n + 2), Side::Buy, At(0), 1);          // dropped again
	Delete(Twin(base, WAYS + 3));                         // frees a CAM entry
	Replace(Twin(base, 1), Twin(base, n + 3), At(1), 3);  // way 1 freed then reused
	Add(Twin(base, n + 4), Side::Sell, At(2), 4);         // takes the CAM entry
	for (uint32_t k = 0; k < n + 5; k++) Delete(Twin(base, k));
}

static void TestZeroShares() {
	Reset(3000000);
	Add(40, Side::Buy, At(0), 0);
	Reduce('X', 40, 0);              // 0 >= 0 removes it
	Add(41, Side::Sell, At(0), 5);
	Reduce('X', 41, 0);              // reduce by nothing
	Replace(41, 42, At(0), 0);
}

static void TestEnds() {
	Reset(100 * SLOT_CENTER);        // window starts at price 0
	Add(50, Side::Buy, 0, 1);
	Add(51, Side::Sell, At(SLOTS - SLOT_CENTER - 1), 1);
	Add(52, Side::Sell, At(SLOTS - SLOT_CENTER), 1);   // one past the top
	Delete(50);
	Delete(51);
}

// ---- Random ----

static void Round(bool hot) {
	Reset((Price)(rng() % 400000) * PRICE_TICK);
	const OrderId hotBase[2] = {rng(), rng()};
	OrderId next = rng() & 0xFFFFFFFFFFFull;
	std::vector<OrderId> live;

	auto fresh = [&]() -> OrderId {
		if (hot && rng() % 4) return Twin(hotBase[rng() & 1], (uint32_t)(rng() % 1024));
		return next++;
	};
	auto price = [&]() -> Price {
		const uint32_t r = rng() % 100;
		if (r < 90) return At((int32_t)(rng() % 64) - 32);
		if (r < 95) return At((int32_t)(rng() % 64) - 32) + 1 + rng() % (PRICE_TICK - 1);
		if (r < 98) return At((int32_t)(rng() % 2 ? SLOTS : -(int32_t)SLOTS));
		return (Price)rng();
	};
	// A live ORN, dropping ones golden no longer holds.
	auto pick = [&](OrderId* orn) -> bool {
		while (!live.empty()) {
			const size_t i = rng() % live.size();
			if (TableFind(gold.table, live[i]).found) { *orn = live[i]; return true; }
			live[i] = live.back();
			live.pop_back();
		}
		return false;
	};

	for (uint32_t op = 0; op < 4000; op++) {
		const uint32_t r = rng() % 100;
		OrderId orn;
		if (r < 40 || !pick(&orn)) {
			const OrderId o = fresh();
			Apply(Command{rng() & 1 ? 'A' : 'F', (Side)(rng() & 1), o, 0,
			              (Quantity)(rng() % 1000), price()});
			live.push_back(o);
		} else if (r < 62) {
			const Quantity have = TableAt(gold.table, TableFind(gold.table, orn)).shares;
			const char t = "ECX"[rng() % 3];
			Reduce(t, orn, (Quantity)(rng() % (have + have / 2 + 2)));
		} else if (r < 77) {
			Delete(orn);
		} else if (r < 94) {
			const OrderId o = rng() % 4 ? fresh() : Twin(orn, (uint32_t)(rng() % 1024));
			Replace(orn, o, price(), (Quantity)(rng() % 1000));
			live.push_back(o);
		} else if (r < 97) {
			const OrderId o = rng();
			Apply(Command{"EXDU"[rng() % 4], Side::Buy, o, o + 1, 1, price()});
		} else {
			Apply(Command{"SRHYLPQBI"[rng() % 9], (Side)(rng() & 1), rng(), rng(),
			              (Quantity)rng(), (Price)rng()});
		}
		if (rng() % 8 == 0) Tick();
	}
}

int main(int argc, char** argv) {
	const uint64_t seed = argc > 1 ? std::strtoull(argv[1], nullptr, 0) : 1;
	const uint32_t rounds = argc > 2 ? std::strtoul(argv[2], nullptr, 0) : 6;
	rng.seed(seed);

	Verilated::commandArgs(argc, argv);
	dut = new Vbook;
	root = dut->rootp;

	TestBasic();
	TestReplace();
	TestFull();
	TestZeroShares();
	TestEnds();
	for (uint32_t i = 0; i < rounds; i++) Round(i & 1);

	if (!(covInsert && covDropped && covRejected && covUnknown && covPartial && covFull &&
	      covDelete && covReplace && covReplaceDropped && covReplaceRejected &&
	      covReplaceSameSet && covReplaceSameSlot && covCam && covOther && covEmptied))
		Fail("coverage hole: a required case was never reached");

	std::printf("PASS seed %llu: %llu cycles; worst cycles A %u F %u E %u C %u X %u D %u U %u\n",
	            (unsigned long long)seed, (unsigned long long)cycle, worst['A'], worst['F'],
	            worst['E'], worst['C'], worst['X'], worst['D'], worst['U']);
	std::printf("  inserts %llu dropped %llu rejected %llu unknown %llu replaces %llu/%llu/%llu cam writes %llu\n",
	            (unsigned long long)covInsert, (unsigned long long)covDropped,
	            (unsigned long long)covRejected, (unsigned long long)covUnknown,
	            (unsigned long long)covReplace, (unsigned long long)covReplaceDropped,
	            (unsigned long long)covReplaceRejected, (unsigned long long)covCam);
	dut->final();
	delete dut;
	return 0;
}
