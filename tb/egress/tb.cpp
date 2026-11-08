#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

#include "Vegress.h"
#include "verilated.h"

#include "book.h"
#include "snapshot.h"

static constexpr int HDR = 42;
static constexpr int FRAME = HDR + SNAP_PACKET_LEN;
static constexpr int RECORDS = 128;
static constexpr int T_ARRIVE_OFF = 20, T_COMMIT_OFF = 24;

static uint64_t MAC_SRC, MAC_DST;
static uint32_t IP_SRC, IP_DST;
static uint16_t PORT_SRC, PORT_DST;

struct Snap {
	std::array<uint8_t, SNAP_PACKET_LEN> pkt;
	uint64_t t;
	uint32_t cycle;
	bool received;
};

static Vegress* dut;
static Book gold;
static std::mt19937_64 rng;
static uint64_t now, tRx, tTx, rxPeriod, txPeriod;
static uint32_t rxCycle;
static std::vector<Snap> snaps;
static std::vector<uint64_t> pops;
static std::array<uint8_t, HDR> header;

enum class Ready { Always, Random, Mac };
static Ready readyMode;
static uint32_t macGap;

static std::vector<uint8_t> frame;
static bool stalled;
static uint8_t stalledData;
static int64_t lastSeq = -1;

static uint64_t covStall, covFrames, covEmptySide, covWrap, covBusyDrop;

[[noreturn]] static void Fail(const char* what) {
	std::printf("FAIL t=%llu ps: %s\n", (unsigned long long)now, what);
	std::exit(1);
}

static void Put(uint8_t* p, uint64_t v, int n) {
	for (int i = n; i-- > 0; v >>= 8) p[i] = (uint8_t)v;
}

static uint64_t Get(const uint8_t* p, int n) {
	uint64_t v = 0;
	for (int i = 0; i < n; i++) v = v << 8 | p[i];
	return v;
}

static void BuildHeader() {
	uint8_t* h = header.data();
	Put(h + 0, MAC_DST, 6);
	Put(h + 6, MAC_SRC, 6);
	Put(h + 12, 0x0800, 2);
	const uint8_t ip[20] = {0x45, 0, 0, 20 + 8 + SNAP_PACKET_LEN, 0, 0, 0x40, 0, 64, 17, 0, 0,
	                        (uint8_t)(IP_SRC >> 24), (uint8_t)(IP_SRC >> 16), (uint8_t)(IP_SRC >> 8),
	                        (uint8_t)IP_SRC, (uint8_t)(IP_DST >> 24), (uint8_t)(IP_DST >> 16),
	                        (uint8_t)(IP_DST >> 8), (uint8_t)IP_DST};
	uint32_t sum = 0;
	for (int i = 0; i < 20; i += 2) sum += ip[i] << 8 | ip[i + 1];
	while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
	std::memcpy(h + 14, ip, 20);
	Put(h + 24, ~sum & 0xFFFF, 2);
	Put(h + 34, PORT_SRC, 2);
	Put(h + 36, PORT_DST, 2);
	Put(h + 38, 8 + SNAP_PACKET_LEN, 2);
	Put(h + 40, 0, 2);
}

static void Frame() {
	if (std::memcmp(frame.data(), header.data(), HDR)) Fail("header");
	const uint8_t* p = frame.data() + HDR;
	const int64_t seq = Get(p + 4, 4);
	if (seq <= lastSeq || seq >= (int64_t)snaps.size()) Fail("snap_seq out of order");
	if (std::memcmp(p, snaps[seq].pkt.data(), SNAP_PACKET_LEN)) Fail("payload");
	snaps[seq].received = true;
	lastSeq = seq;
	pops.push_back(now);
	covFrames++;
}

static void TxEdge() {
	if (readyMode == Ready::Always) dut->s_ready = 1;
	else if (readyMode == Ready::Random) dut->s_ready = rng() % 4 != 0;
	else {
		if (macGap) macGap--;
		dut->s_ready = !frame.empty() || (dut->s_valid && macGap == 0);
	}
	dut->eval();

	if (!dut->s_valid && !frame.empty()) Fail("s_valid dropped mid-frame");
	if (stalled && (!dut->s_valid || dut->s_data != stalledData)) Fail("data changed while stalled");
	stalled = dut->s_valid && !dut->s_ready;
	stalledData = dut->s_data;
	if (stalled) covStall++;

	if (dut->s_valid && dut->s_ready) {
		frame.push_back(dut->s_data);
		if (dut->s_last != (frame.size() == FRAME)) Fail("s_last");
		if (dut->s_last) {
			Frame();
			frame.clear();
			macGap = 24;
		}
	}

	dut->tx_clk = 1;
	dut->eval();
	dut->tx_clk = 0;
	dut->eval();
}

struct Driver {
	uint32_t idle, busy;
	int phase;
	bool tight;
	uint32_t minSpacing, maxSpacing;
} drv;

static void Noise() {
	dut->cmd_mold_seq = rng();
	dut->cmd_msg_index = rng();
	dut->cmd_t_arrive = rng();
	dut->order_dropped = rng() & 1;
	dut->price_rejected = rng() & 1;
	dut->unknown_order_ref = rng() & 1;
	dut->mold_gap_seen = rng() & 1;
	dut->bid_valid = rng() & 1;
	dut->bid_slot = rng() % SLOTS;
	dut->bid_shares = rng();
	dut->bid_orders = rng();
	dut->ask_valid = rng() & 1;
	dut->ask_slot = rng() % SLOTS;
	dut->ask_shares = rng();
	dut->ask_orders = rng();
}

static uint32_t RandSlot() {
	switch (rng() % 6) {
	case 0: return 0;
	case 1: return SLOTS - 1;
	case 2: return SLOT_CENTER;
	default: return rng() % SLOTS;
	}
}

static uint64_t accMold;
static uint32_t accIndex, accArrive;

static void Side(PriceBook& pb, uint8_t& valid, uint16_t& slot, uint32_t& shares, uint16_t& orders) {
	valid = rng() % 5 != 0;
	slot = valid ? RandSlot() : rng() % SLOTS;
	shares = valid ? (uint32_t)rng() : 0;
	orders = valid ? (uint16_t)rng() : 0;
	pb.hasBest = valid;
	pb.best = slot;
	if (valid) pb.levels[slot] = Level{shares, orders};
	if (!valid) covEmptySide++;
}

static void RxEdge(bool traffic) {
	Noise();
	dut->cmd_accept = 0;
	dut->done = 0;

	if (traffic) {
		if (drv.phase == 0 && drv.idle-- == 0) {
			drv.phase = 1;
			dut->cmd_accept = 1;
			dut->cmd_mold_seq = accMold = rng();
			dut->cmd_msg_index = accIndex = rng();
			dut->cmd_t_arrive = accArrive = rng();
			drv.busy = drv.tight ? rng() % 6 : 7 + rng() % 12;
		} else if (drv.phase == 1 && drv.busy-- == 0) {
			drv.phase = 0;
			drv.idle = drv.minSpacing - 9 + rng() % (drv.maxSpacing - drv.minSpacing + 1);
			if (rng() % 150 == 0) drv.idle += rng() % 30000;
			drv.tight = rng() % 40 == 0;
			if (drv.tight) drv.idle = 0;
			dut->done = 1;
			uint8_t status = 0;
			if (rng() % 3 == 0) status |= 1 << SNAP_STATUS_ORDER_DROPPED;
			if (rng() % 3 == 0) status |= 1 << SNAP_STATUS_PRICE_REJECTED;
			if (rng() % 3 == 0) status |= 1 << SNAP_STATUS_MOLD_GAP_SEEN;
			if (rng() % 3 == 0) status |= 1 << SNAP_STATUS_UNKNOWN_ORDER_REF;
			dut->order_dropped = status >> SNAP_STATUS_ORDER_DROPPED & 1;
			dut->price_rejected = status >> SNAP_STATUS_PRICE_REJECTED & 1;
			dut->mold_gap_seen = status >> SNAP_STATUS_MOLD_GAP_SEEN & 1;
			dut->unknown_order_ref = status >> SNAP_STATUS_UNKNOWN_ORDER_REF & 1;
			uint8_t bv, av;
			uint16_t bs, as, bo, ao;
			uint32_t bsh, ash;
			Side(gold.bids, bv, bs, bsh, bo);
			Side(gold.asks, av, as, ash, ao);
			dut->bid_valid = bv, dut->bid_slot = bs, dut->bid_shares = bsh, dut->bid_orders = bo;
			dut->ask_valid = av, dut->ask_slot = as, dut->ask_shares = ash, dut->ask_orders = ao;

			Snap s{};
			EncodeSnapshotPacket(s.pkt.data(), gold, status, (uint32_t)snaps.size(), accMold, accIndex);
			Put(s.pkt.data() + T_ARRIVE_OFF, accArrive, 4);
			Put(s.pkt.data() + T_COMMIT_OFF, rxCycle, 4);
			s.t = now;
			s.cycle = rxCycle;
			snaps.push_back(s);
		}
	}

	dut->cycle = rxCycle;
	dut->clk = 1;
	dut->eval();
	dut->clk = 0;
	dut->eval();
	rxCycle++;
}

static void Run(uint64_t until, bool traffic) {
	while (now < until) {
		now = std::min(tRx, tTx);
		if (tRx == now) {
			RxEdge(traffic);
			tRx += rxPeriod;
		}
		if (tTx == now) {
			TxEdge();
			tTx += txPeriod;
		}
	}
}

static void Reset() {
	dut->rst = dut->tx_rst = 1;
	for (int i = 0; i < 4; i++) Run(now + 8 * std::max(rxPeriod, txPeriod), false);
	dut->rst = dut->tx_rst = 0;
}

static void Drain() {
	const uint64_t end = now + (uint64_t)(RECORDS + 4) * FRAME * 4 * txPeriod + 100 * rxPeriod;
	Run(end, false);
	if (dut->s_valid || !frame.empty()) Fail("FIFO did not drain");
}

static void CheckDrops() {
	uint64_t enq = 0, drops = 0;
	int64_t lastTake = -100;
	for (const Snap& s : snaps) {
		const bool writing = (int64_t)s.cycle - lastTake <= 6;
		const uint64_t seen = std::lower_bound(pops.begin(), pops.end(), s.t) - pops.begin();
		const uint64_t sure = std::lower_bound(pops.begin(), pops.end(),
		                                       s.t > 3 * rxPeriod ? s.t - 3 * rxPeriod : 0) - pops.begin();
		if (s.received) {
			if (enq - seen >= RECORDS) Fail("taken while full");
			if (writing) Fail("taken while writing");
			lastTake = s.cycle;
			enq++;
		} else {
			if (enq - sure < RECORDS && !writing) Fail("dropped with room");
			if (writing && enq - sure < RECORDS) covBusyDrop++;
			drops++;
		}
	}
	if ((drops != 0) != (dut->snap_overflow != 0)) Fail("snap_overflow");
	if (enq >= 2 * RECORDS) covWrap++;
	std::printf("  %zu snapshots, %llu dropped\n", snaps.size(), (unsigned long long)drops);
}

int main(int argc, char** argv) {
	const uint32_t seed = argc > 1 ? std::atoi(argv[1]) : 1;
	const uint32_t rounds = argc > 2 ? std::atoi(argv[2]) : 8;
	rng.seed(seed);
	Verilated::commandArgs(argc, argv);
	dut = new Vegress;

	uint64_t totalSnaps = 0, totalDrops = 0;
	for (uint32_t r = 0; r < rounds; r++) {
		static const uint64_t periods[] = {8000, 7992, 8008, 3000, 20000, 0};
		rxPeriod = 8000;
		txPeriod = periods[r % 6] ? periods[r % 6] : 2000 + rng() % 28000;
		readyMode = (Ready)(r % 3);
		const bool burst = r % 2 == 0;
		drv = {0, 0, 0, false, burst ? 9u : 120u, burst ? 30u : 400u};

		MAC_SRC = rng() >> 16, MAC_DST = rng() >> 16;
		IP_SRC = rng(), IP_DST = rng();
		if (r % 4 == 3) {
			IP_SRC |= 0xFFFF0000;
			const uint32_t sum = 0x4500 + 20 + 8 + SNAP_PACKET_LEN + 0x4000 + 0x4011 + (IP_SRC >> 16) +
			                     (IP_SRC & 0xFFFF) + (IP_DST >> 16);
			IP_DST = (IP_DST & 0xFFFF0000) | ((0xFFFF - sum) & 0xFFFF);
		}
		PORT_SRC = rng(), PORT_DST = rng();
		BuildHeader();
		dut->cfg_src_mac = MAC_SRC;
		dut->cfg_dst_mac = MAC_DST;
		dut->cfg_src_ip = IP_SRC;
		dut->cfg_dst_ip = IP_DST;
		dut->cfg_src_port = PORT_SRC;
		dut->cfg_dst_port = PORT_DST;

		const uint32_t base = rng() % 3 == 0 ? (uint32_t)rng() % 1000000 : 100 * SLOT_CENTER + 100 * (rng() % 100000);
		ResetBook(&gold, base);
		dut->base_price = base;
		snaps.clear();
		pops.clear();
		frame.clear();
		lastSeq = -1;
		stalled = false;
		tRx = now;
		tTx = now + rng() % txPeriod;
		Reset();

		Run(now + (uint64_t)(burst ? 3000 : 1500) * 40 * rxPeriod, true);
		Drain();
		std::printf("round %u: tx %llu ps, ready %d, %s\n", r, (unsigned long long)txPeriod,
		            (int)readyMode, burst ? "burst" : "sparse");
		const uint64_t busyBefore = covBusyDrop;
		CheckDrops();
		uint64_t d = 0;
		for (const Snap& s : snaps) d += !s.received;
		if (!burst && txPeriod <= 8008 && d > covBusyDrop - busyBefore) Fail("sparse traffic dropped");
		totalSnaps += snaps.size();
		totalDrops += d;
	}

	if (!covStall || !covFrames || !covEmptySide || !covWrap || !covBusyDrop || !totalDrops)
		Fail("coverage: a case never happened");
	std::printf("PASS seed %u: %llu snapshots, %llu dropped, %llu stalls\n", seed,
	            (unsigned long long)totalSnaps, (unsigned long long)totalDrops,
	            (unsigned long long)covStall);
	delete dut;
	return 0;
}
