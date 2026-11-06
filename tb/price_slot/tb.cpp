// tb.cpp -- rtl/price_slot.sv against golden's PriceToSlot.
//
// Every price in the slot window, plus a margin either side, for bases
// across the range, so the reciprocal multiply is checked exhaustively
// rather than sampled. Requests stream one per cycle with random gaps; the
// response must land exactly 3 cycles later.

#include <array>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <random>

#include "Vprice_slot.h"
#include "verilated.h"

#include "pricebook.h"

static constexpr int LATENCY = 3;
static constexpr int64_t MARGIN = 1000;

struct Expect {
	uint32_t price;
	std::optional<Slot> slot;
};

static Vprice_slot* dut;
static std::mt19937_64 rng;
static uint64_t cycle;
static std::array<std::optional<Expect>, LATENCY - 1> stages;
static uint64_t covOk, covOffTick, covLow, covHigh, covMin, covMax;

[[noreturn]] static void Fail(const char* what, uint32_t base, uint32_t price) {
	std::printf("FAIL cycle %llu base %u price %u: %s\n", (unsigned long long)cycle,
	            base, price, what);
	std::exit(1);
}

static void Check(const Expect& x, uint32_t base) {
	if (dut->rsp_ok != x.slot.has_value()) Fail("rsp_ok", base, x.price);
	if (x.slot) {
		if (dut->rsp_slot != *x.slot) Fail("rsp_slot", base, x.price);
		covOk++;
		if (*x.slot == 0) covMin++;
		if (*x.slot == SLOTS - 1) covMax++;
	} else {
		const int64_t delta = (int64_t)x.price - base;
		if (delta < -(int64_t)SLOT_CENTER * PRICE_TICK) covLow++;
		else if (delta >= (int64_t)(SLOTS - SLOT_CENTER) * PRICE_TICK) covHigh++;
		else covOffTick++;
	}
}

static void Tick(uint32_t base, std::optional<Expect> accepted) {
	if (!dut->req_valid) dut->req_price = (uint32_t)rng();
	dut->eval();
	dut->clk = 1;
	dut->eval();
	dut->clk = 0;
	dut->eval();
	cycle++;

	const std::optional<Expect> due = stages.back();
	if (dut->rsp_valid != due.has_value())
		Fail("rsp_valid not exactly 3 cycles after req_valid", base, due ? due->price : 0);
	if (due) Check(*due, base);
	for (size_t i = stages.size() - 1; i > 0; i--) stages[i] = stages[i - 1];
	stages[0] = accepted;
}

static void Request(uint32_t base, uint32_t price) {
	dut->req_valid = 1;
	dut->req_price = price;
	Tick(base, Expect{price, PriceToSlot(base, price)});
	dut->req_valid = 0;
	if (rng() % 64 == 0) Tick(base, std::nullopt);
}

static void Sweep(uint32_t base) {
	dut->base_price = base;
	for (int i = 0; i < LATENCY; i++) Tick(base, std::nullopt);

	const int64_t lo = (int64_t)base - (int64_t)SLOT_CENTER * PRICE_TICK - MARGIN;
	const int64_t hi = (int64_t)base + (int64_t)(SLOTS - SLOT_CENTER) * PRICE_TICK + MARGIN;
	for (int64_t p = lo; p < hi; p++)
		if (p >= 0 && p <= UINT32_MAX) Request(base, (uint32_t)p);
	for (int i = 0; i < 1000; i++) Request(base, (uint32_t)rng());   // far outside
}

int main(int argc, char** argv) {
	const uint64_t seed = argc > 1 ? std::strtoull(argv[1], nullptr, 0) : 1;
	rng.seed(seed);

	Verilated::commandArgs(argc, argv);
	dut = new Vprice_slot;
	dut->req_valid = 0;
	for (int i = 0; i < 2 * LATENCY; i++) {   // flush power-up state
		dut->clk = 1; dut->eval();
		dut->clk = 0; dut->eval();
	}

	const uint32_t top = UINT32_MAX / PRICE_TICK * PRICE_TICK;
	for (uint32_t base : {0u, 100u, 500000u, 819100u, 819200u, 819300u, 1500000u,
	                      100000000u, top - 819200u, top})
		Sweep(base);

	if (!(covOk && covOffTick && covLow && covHigh && covMin && covMax))
		Fail("coverage hole: a required case was never reached", 0, 0);
	std::printf("PASS seed %llu: %llu cycles, %llu in window\n", (unsigned long long)seed,
	            (unsigned long long)cycle, (unsigned long long)covOk);
	dut->final();
	delete dut;
	return 0;
}
