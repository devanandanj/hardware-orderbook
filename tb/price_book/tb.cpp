// tb.cpp -- rtl/price_book.sv against golden's PriceBookNoteWrite.
//
// Built once per side (-GSELL). After every write the best slot and level
// are compared with the golden book, and reads are checked against its
// levels. Each round ends by reading all SLOTS levels back.
//
// Contract the RTL is held to:
//   - one operation at a time, and only while ready is high;
//   - a read accepted at posedge t responds after that same edge;
//   - ready drops after a write and returns within MAX_BUSY cycles, with
//     best_* correct;
//   - after rst, ready rises within SLOTS + READY_SLACK cycles with every
//     level zero and the side empty.

#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

#include "Vprice_book.h"
#include "verilated.h"

#include "pricebook.h"

static constexpr uint32_t READY_SLACK = 16;
static constexpr uint32_t MAX_BUSY = 8;

static Vprice_book* dut;
static PriceBook gold;
static Side side;
static std::mt19937_64 rng;
static uint64_t cycle;
static bool expectRead;

// Reached-state counters; a run that misses one proves nothing about it.
static uint64_t covBetter, covWorse, covSame, covRescan, covEmptied, covRowKept,
                covBestMin, covBestMax, covReads;

[[noreturn]] static void Fail(const char* what, uint32_t slot) {
	std::printf("FAIL %s cycle %llu slot %u: %s\n", side == Side::Sell ? "ask" : "bid",
	            (unsigned long long)cycle, slot, what);
	std::exit(1);
}

// One clock. Idle inputs carry noise, so a port that ignores its valid
// shows up as a mismatch.
static void Tick() {
	if (!dut->rd_valid) dut->rd_slot = rng() % SLOTS;
	if (!dut->wr_valid) {
		dut->wr_slot = rng() % SLOTS;
		dut->wr_shares = (uint32_t)rng();
		dut->wr_orders = (uint16_t)rng();
	}
	dut->eval();
	dut->clk = 1;
	dut->eval();
	dut->clk = 0;
	dut->eval();
	cycle++;
	if (!dut->rst && dut->rd_rsp_valid != expectRead) Fail("rd_rsp_valid", dut->rd_slot);
	expectRead = false;
}

static void CheckBest() {
	if (dut->best_valid != gold.hasBest) Fail("best_valid", gold.best);
	if (dut->best_slot != gold.best) Fail("best_slot", gold.best);
	const Level l = gold.hasBest ? gold.levels[gold.best] : Level{};
	if (dut->best_shares != l.shares) Fail("best_shares", gold.best);
	if (dut->best_orders != l.orders) Fail("best_orders", gold.best);
	if (gold.hasBest && gold.best == 0) covBestMin++;
	if (gold.hasBest && gold.best == SLOTS - 1) covBestMax++;
}

static void Write(uint32_t slot, Quantity shares, uint16_t orders) {
	const bool wasBest = gold.hasBest && gold.best == slot;
	const bool beats = !gold.hasBest || IsBetter(side, (Slot)slot, gold.best);
	if (orders == 0 && wasBest) covRescan++;
	else if (orders != 0 && wasBest) covSame++;
	else if (orders != 0 && beats) covBetter++;
	else if (orders != 0) covWorse++;

	dut->wr_valid = 1;
	dut->wr_slot = slot;
	dut->wr_shares = shares;
	dut->wr_orders = orders;
	Tick();
	dut->wr_valid = 0;
	gold.levels[slot] = Level{shares, orders};
	PriceBookNoteWrite(gold, side, (Slot)slot);
	if (!gold.hasBest && wasBest) covEmptied++;

	if (dut->ready) Fail("ready high straight after a write", slot);
	uint32_t n = 0;
	while (!dut->ready) {
		if (++n > MAX_BUSY) Fail("ready stuck low after a write", slot);
		Tick();
	}
	CheckBest();
}

static void Read(uint32_t slot) {
	dut->rd_valid = 1;
	dut->rd_slot = slot;
	expectRead = true;
	Tick();
	dut->rd_valid = 0;
	if (dut->rd_shares != gold.levels[slot].shares) Fail("rd_shares", slot);
	if (dut->rd_orders != gold.levels[slot].orders) Fail("rd_orders", slot);
	covReads++;
}

static void ReadAll() {
	for (uint32_t s = 0; s < SLOTS; s++) Read(s);
}

static void Reset() {
	dut->rd_valid = 0;
	dut->wr_valid = 0;
	dut->rst = 1;
	for (int i = 0; i < 4; i++) Tick();
	if (dut->ready) Fail("ready high in reset", 0);
	dut->rst = 0;
	uint32_t n = 0;
	for (Tick(); !dut->ready; Tick())
		if (++n > SLOTS + READY_SLACK) Fail("ready never rose after reset", 0);
	gold = PriceBook{};
	CheckBest();
}

static void Occupy(uint32_t slot) {
	Write(slot, 1 + (Quantity)(rng() >> 33), 1 + rng() % 0xFFFE);
}

static void Empty(uint32_t slot) {
	Write(slot, 0, 0);
}

// ---- Directed: the corners random traffic reaches only by luck ----

static void TestEnds() {
	Reset();
	Occupy(0);
	Occupy(SLOTS - 1);
	Occupy(SLOTS / 2);
	Empty(SLOTS / 2);
	Empty(0);
	Empty(SLOTS - 1);       // side empty again
	Occupy(SLOTS - 1);
	Empty(SLOTS - 1);
	Occupy(0);
	Empty(0);
}

// Neighbouring slots across a row boundary, and rows that keep a bit set
// after losing one, so the summary must not clear early.
static void TestRows() {
	Reset();
	const uint32_t cols = 128;
	for (uint32_t s : {cols - 1, cols, 2 * cols - 1, 2 * cols, 5 * cols + 3, 5 * cols + 9}) Occupy(s);
	for (uint32_t s : {5 * cols + 9, 5 * cols + 3, 2 * cols, 2 * cols - 1, cols, cols - 1}) {
		Empty(s);
		covRowKept++;
	}
	for (uint32_t s : {cols - 1, cols, 2 * cols - 1, 2 * cols, 5 * cols + 3, 5 * cols + 9}) Occupy(s);
	for (uint32_t s : {cols - 1, cols, 2 * cols - 1, 2 * cols, 5 * cols + 3, 5 * cols + 9}) Empty(s);
}

// A write to the best slot that keeps it occupied changes only the level.
static void TestSameSlot() {
	Reset();
	Occupy(4000);
	for (int i = 0; i < 4; i++) Occupy(4000);
	Occupy(4001);
	Occupy(3999);
	Empty(gold.best);
	Empty(gold.best);
	Empty(gold.best);
}

// Empty means orders == 0, as in golden: a level can hold orders and no shares.
static void TestZeroShares() {
	Reset();
	Write(5000, 0, 3);
	Write(5001, 0, 1);
	Write(4999, 7, 1);
	Empty(gold.best);
	Empty(gold.best);
	Empty(gold.best);
}

static void TestResetClears() {
	Reset();
	for (uint32_t s : {0u, 1u, 200u, 8191u, 8192u, 16383u}) Occupy(s);
	Reset();
	ReadAll();
	Occupy(100);
	Empty(100);
}

// ---- Random ----

static void Round(bool hot) {
	Reset();
	const uint32_t centre = rng() % SLOTS;
	auto pick = [&]() -> uint32_t {
		if (!hot) return rng() % SLOTS;
		const int64_t s = (int64_t)centre + (int64_t)(rng() % 512) - 256;
		return (uint32_t)(s < 0 ? 0 : s >= SLOTS ? SLOTS - 1 : s);
	};

	std::vector<uint32_t> live;
	for (uint32_t op = 0; op < 20000; op++) {
		const uint32_t r = rng() % 100;
		if (live.empty() || r < 45) {
			const uint32_t s = pick();
			if (gold.levels[s].orders == 0) live.push_back(s);
			Occupy(s);
		} else if (r < 65) {                      // empty the best level
			if (gold.hasBest) {
				for (size_t i = 0; i < live.size(); i++)
					if (live[i] == gold.best) { live[i] = live.back(); live.pop_back(); break; }
				Empty(gold.best);
			}
		} else if (r < 85) {                      // empty any level
			const size_t i = rng() % live.size();
			const uint32_t s = live[i];
			live[i] = live.back();
			live.pop_back();
			Empty(s);
		} else {
			Read(rng() & 1 ? live[rng() % live.size()] : pick());
		}
		if (rng() % 16 == 0) { dut->rd_valid = dut->wr_valid = 0; Tick(); }
	}
	ReadAll();
}

int main(int argc, char** argv) {
	const bool sell = argc > 1 && std::atoi(argv[1]);
	const uint64_t seed = argc > 2 ? std::strtoull(argv[2], nullptr, 0) : 1;
	const uint32_t rounds = argc > 3 ? std::strtoul(argv[3], nullptr, 0) : 20;
	side = sell ? Side::Sell : Side::Buy;
	rng.seed(seed);

	Verilated::commandArgs(argc, argv);
	dut = new Vprice_book;

	TestEnds();
	TestRows();
	TestSameSlot();
	TestZeroShares();
	TestResetClears();
	for (uint32_t i = 0; i < rounds; i++) Round(i & 1);

	if (!(covBetter && covWorse && covSame && covRescan && covEmptied && covRowKept &&
	      covBestMin && covBestMax && covReads))
		Fail("coverage hole: a required case was never reached", 0);
	std::printf("PASS %s seed %llu: %llu cycles, %llu rescans, %llu emptied\n",
	            sell ? "ask" : "bid", (unsigned long long)seed, (unsigned long long)cycle,
	            (unsigned long long)covRescan, (unsigned long long)covEmptied);
	dut->final();
	delete dut;
	return 0;
}
