// tb.cpp -- rtl/order_table.sv against the golden order table.
//
// Every lookup is checked against TableFind / TableFindFree, on the cycle
// the response is due. Writes go to both the RTL and the golden table.
//
// Contract the RTL is held to:
//   - a lookup accepted at posedge t responds after posedge t+1, and
//     lookups may issue back to back;
//   - a write at posedge t is seen by a lookup at posedge t+1;
//   - no write while a lookup is in flight (the book FSM never does this),
//     nor in the same cycle as a lookup;
//   - after rst, ready rises within SETS + READY_SLACK cycles and the
//     table is empty.
//
// Entry packing (book_pkg::entry_t), MSB first, in spec/book.yaml order:
//   {valid[111], orn[110:47], side[46], slot[45:32], shares[31:0]}

#include <array>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <random>
#include <vector>

#include "Vorder_table.h"
#include "verilated.h"

#include "ordertable.h"

using u128 = unsigned __int128;

static constexpr uint32_t READY_SLACK = 16;

static Vorder_table* dut;
static OrderTable gold;
static std::mt19937_64 rng;
static uint64_t cycle;

struct Expect {
	uint64_t orn;
	TableLoc hit;
	TableEntry entry;
	TableLoc free;
};

static std::optional<Expect> stage;   // accepted last posedge
static bool checking;                 // off through reset

// Reached-state counters; a run that misses one proves nothing about it.
static uint64_t covHitWay[WAYS], covHitCam[CAM_DEPTH];
static uint64_t covFreeWay[WAYS], covFreeCam, covFull, covMiss, covStale, covReuse;

[[noreturn]] static void Fail(const char* what, uint64_t orn) {
	std::printf("FAIL cycle %llu orn %016llx: %s\n", (unsigned long long)cycle,
	            (unsigned long long)orn, what);
	std::exit(1);
}

static u128 Pack(const TableEntry& e) {
	return (u128)e.valid << 111 | (u128)e.orderId << 47 |
	       (u128)(e.side == Side::Sell) << 46 | (u128)e.slot << 32 | e.shares;
}

static void Check(const Expect& x) {
	if (dut->rsp_set != x.hit.set) Fail("rsp_set", x.orn);

	if (dut->rsp_hit != x.hit.found) Fail("rsp_hit", x.orn);
	if (x.hit.found) {
		if (dut->rsp_hit_cam != x.hit.inCam) Fail("rsp_hit_cam", x.orn);
		if (dut->rsp_hit_idx != x.hit.index) Fail("rsp_hit_idx", x.orn);
		u128 got = 0;
		for (int i = 3; i >= 0; i--) got = got << 32 | dut->rsp_hit_entry[i];
		if (got != Pack(x.entry)) Fail("rsp_hit_entry", x.orn);
		(x.hit.inCam ? covHitCam : covHitWay)[x.hit.index]++;
	} else {
		covMiss++;
	}

	if (dut->rsp_free != x.free.found) Fail("rsp_free", x.orn);
	if (x.free.found) {
		if (dut->rsp_free_cam != x.free.inCam) Fail("rsp_free_cam", x.orn);
		if (dut->rsp_free_idx != x.free.index) Fail("rsp_free_idx", x.orn);
		if (x.free.inCam) covFreeCam++; else covFreeWay[x.free.index]++;
	} else {
		covFull++;
	}
}

// One clock. Idle inputs carry noise, so a port that ignores its valid
// shows up as a mismatch.
static void Tick(std::optional<Expect> accepted = std::nullopt) {
	if (!dut->req_valid) dut->req_orn = rng();
	if (!dut->wr_valid) {
		dut->wr_cam = rng() & 1;
		dut->wr_set = rng() % SETS;
		dut->wr_idx = rng() % WAYS;
		for (int i = 0; i < 4; i++) dut->wr_entry[i] = (uint32_t)rng();
		dut->wr_entry[3] &= 0xFFFF;
	}
	dut->eval();
	dut->clk = 1;
	dut->eval();
	dut->clk = 0;
	dut->eval();
	cycle++;

	if (checking) {
		if (dut->rsp_valid != stage.has_value())
			Fail("rsp_valid not exactly 2 cycles after req_valid",
			     stage ? stage->orn : 0);
		if (stage) Check(*stage);
	}
	stage = accepted;
}

static void Idle(int n = 1) {
	dut->req_valid = 0;
	dut->wr_valid = 0;
	while (n--) Tick();
}

static void Drain() {
	if (stage) Idle();
}

static Expect Golden(uint64_t orn) {
	Expect x{orn, TableFind(gold, orn), {}, TableFindFree(gold, orn)};
	if (x.hit.found) x.entry = TableAt(gold, x.hit);
	return x;
}

static void Lookup(uint64_t orn) {
	dut->wr_valid = 0;
	dut->req_valid = 1;
	dut->req_orn = orn;
	Tick(Golden(orn));
	dut->req_valid = 0;
}

// Writes through the DUT and the model. The caller goes straight on to the
// next operation, so a following Lookup lands on the very next cycle.
static void Write(const TableLoc& loc, const TableEntry& e) {
	Drain();
	dut->req_valid = 0;
	dut->wr_valid = 1;
	dut->wr_cam = loc.inCam;
	dut->wr_set = loc.set;
	dut->wr_idx = loc.index;
	const u128 v = Pack(e);
	for (int i = 0; i < 4; i++) dut->wr_entry[i] = (uint32_t)(v >> (32 * i));
	Tick();
	dut->wr_valid = 0;
	TableAt(gold, loc) = e;
}

static void Reset() {
	checking = false;
	stage.reset();
	dut->req_valid = 0;
	dut->wr_valid = 0;
	dut->rst = 1;
	for (int i = 0; i < 4; i++) Tick();
	if (dut->ready) Fail("ready high in reset", 0);
	dut->rst = 0;
	checking = true;
	uint32_t n = 0;
	for (Tick(); !dut->ready; Tick())
		if (++n > SETS + READY_SLACK) Fail("ready never rose after reset", 0);
	gold = OrderTable{};
}

static uint64_t OrnInSet(uint32_t set) {
	const uint64_t orn = rng();
	return orn ^ (HashOrn(orn) ^ set);   // low bits feed the hash one to one
}

static TableEntry MakeEntry(uint64_t orn) {
	return {true, orn, rng() & 1 ? Side::Sell : Side::Buy,
	        (Slot)(rng() % SLOTS), (Quantity)rng()};
}

static bool Insert(uint64_t orn) {
	const TableLoc loc = TableFindFree(gold, orn);
	Lookup(orn);
	if (loc.found) Write(loc, MakeEntry(orn));
	return loc.found;
}

static void Clear(uint64_t orn) {
	Lookup(orn);
	Write(TableFind(gold, orn), TableEntry{});
}

// ---- Directed: the corners random traffic reaches only by luck ----

static void TestEmpty() {
	Reset();
	Lookup(0);   // an all-zero entry must not match ORN 0
	Lookup(~0ull);
	Drain();
}

static void TestOverflow() {
	Reset();
	const uint32_t a = 5, b = SETS - 1;
	std::vector<uint64_t> orns;
	for (uint32_t i = 0; i < WAYS + CAM_DEPTH; i++) {
		orns.push_back(OrnInSet(a));
		if (!Insert(orns.back())) Fail("golden refused an insert", orns.back());
	}
	for (uint64_t orn : orns) Lookup(orn);
	Lookup(OrnInSet(a));        // set and CAM full
	Lookup(OrnInSet(b));        // other set: a way, though the CAM is full
	Clear(orns[1]);             // a way beats the free CAM entries below
	Clear(orns[WAYS + 7]);
	Clear(orns[WAYS + 2]);
	Lookup(OrnInSet(a));
	Clear(orns[0]);
	Lookup(orns[WAYS]);
	Drain();
}

// A 'U' whose new ORN lands in the old order's set must see the slot it
// just freed, on the very next cycle.
static void TestReplaceSameSet() {
	Reset();
	const uint32_t s = 77;
	const uint64_t o0 = OrnInSet(s), o1 = OrnInSet(s), o2 = OrnInSet(s);
	Insert(o0);
	Insert(o1);
	Insert(o2);
	Lookup(o1);
	Drain();
	Write(TableFind(gold, o1), TableEntry{});
	Lookup(OrnInSet(s));
	covReuse++;
	Drain();
}

// ITCH says this never happens, but golden defines the winner.
static void TestDuplicate() {
	Reset();
	const uint32_t s = 300;
	const uint64_t orn = OrnInSet(s);
	const TableEntry e0 = MakeEntry(orn), e1 = MakeEntry(orn), e2 = MakeEntry(orn);
	Write({true, false, s, 2}, e2);
	Write({true, true, s, 9}, e1);
	Lookup(orn);                       // way over CAM
	Write({true, false, s, 0}, e0);
	Lookup(orn);                       // lowest way
	Write({true, false, s, 0}, TableEntry{});
	Write({true, false, s, 2}, TableEntry{});
	Write({true, true, s, 3}, e0);
	Lookup(orn);                       // lowest CAM entry
	Drain();
}

// valid clear, ORN left in place: must miss, and the slot must read free.
static void TestStale() {
	Reset();
	const uint64_t orn = OrnInSet(9), cam = OrnInSet(10);
	TableEntry e = MakeEntry(orn), c = MakeEntry(cam);
	e.valid = c.valid = false;
	Write({true, false, 9, 0}, e);
	Write({true, true, 10, 0}, c);
	Lookup(orn);
	Lookup(cam);
	covStale++;
	Drain();
}

// ORNs that nearly match. Two ORNs in one set always differ in at least two
// bits of the same hash residue, so ways are probed with such pairs; the
// CAM compares across sets, so there every single bit counts.
static void TestNearMiss() {
	Reset();
	const uint32_t s = 123;
	std::vector<uint64_t> orns;
	for (uint32_t i = 0; i < WAYS + 1; i++) {
		orns.push_back(OrnInSet(s));
		Insert(orns.back());
	}
	for (uint32_t w = 0; w < WAYS; w++)
		for (uint32_t i = 0; i < 64; i++)
			for (uint32_t j = i + HASH_W; j < 64; j += HASH_W)
				Lookup(orns[w] ^ 1ull << i ^ 1ull << j);
	for (uint32_t i = 0; i < 64; i++) Lookup(orns[WAYS] ^ 1ull << i);
	Drain();
}

static void TestResetClears() {
	Reset();
	for (uint32_t i = 0; i < WAYS + CAM_DEPTH; i++) Insert(OrnInSet(SETS / 2));
	const uint64_t last = OrnInSet(0);
	Insert(last);
	Drain();
	Reset();
	Lookup(last);
	Lookup(OrnInSet(SETS / 2));
	Drain();
}

// ---- Random ----

static void Round(bool hot) {
	Reset();
	uint32_t hotSets[4];
	for (uint32_t& s : hotSets) s = rng() % SETS;
	auto pick = [&] { return hot ? OrnInSet(hotSets[rng() % 4]) : rng(); };

	std::vector<uint64_t> live;
	auto takeLive = [&] {
		const size_t i = rng() % live.size();
		const uint64_t orn = live[i];
		live[i] = live.back();
		live.pop_back();
		return orn;
	};
	auto insert = [&](uint64_t orn) { if (Insert(orn)) live.push_back(orn); };

	// Wide rounds run the table near full, so a skewed mix toward inserts.
	const uint32_t insertPct = hot ? 50 : 65;
	for (uint32_t op = 0; op < 20000; op++) {
		const uint32_t r = rng() % 100;
		if (live.empty() || r < insertPct) {
			insert(pick());
		} else if (r < insertPct + 15) {
			Clear(takeLive());
		} else if (r < insertPct + 20) {          // reduce: rewrite shares
			const uint64_t orn = live[rng() % live.size()];
			Lookup(orn);
			const TableLoc loc = TableFind(gold, orn);
			TableEntry e = TableAt(gold, loc);
			e.shares = (Quantity)rng();
			Write(loc, e);
		} else if (r < insertPct + 25) {          // replace, often same set
			const uint64_t old = takeLive();
			Clear(old);
			insert(rng() & 1 ? OrnInSet(HashOrn(old)) : pick());
		} else {                                  // back-to-back lookups
			for (uint32_t n = 1 + rng() % 8; n--;)
				Lookup(rng() & 1 ? live[rng() % live.size()] : pick());
		}
		if (rng() % 16 == 0) Idle(1 + rng() % 3);
	}
	Drain();
}

static void RequireCovered() {
	bool ok = covMiss && covFull && covFreeCam && covStale && covReuse;
	for (uint32_t i = 0; i < WAYS; i++) ok = ok && covHitWay[i] && covFreeWay[i];
	for (uint32_t i = 0; i < CAM_DEPTH; i++) ok = ok && covHitCam[i];
	if (!ok) Fail("coverage hole: a required case was never reached", 0);
}

int main(int argc, char** argv) {
	const uint64_t seed = argc > 1 ? std::strtoull(argv[1], nullptr, 0) : 1;
	const uint32_t rounds = argc > 2 ? std::strtoul(argv[2], nullptr, 0) : 40;
	rng.seed(seed);

	Verilated::commandArgs(argc, argv);
	dut = new Vorder_table;

	TestEmpty();
	TestOverflow();
	TestReplaceSameSet();
	TestDuplicate();
	TestStale();
	TestNearMiss();
	TestResetClears();
	for (uint32_t i = 0; i < rounds; i++) Round(i & 1);

	RequireCovered();
	std::printf("PASS seed %llu: %llu cycles, %llu misses, %llu full\n",
	            (unsigned long long)seed, (unsigned long long)cycle,
	            (unsigned long long)covMiss, (unsigned long long)covFull);
	dut->final();
	delete dut;
	return 0;
}
