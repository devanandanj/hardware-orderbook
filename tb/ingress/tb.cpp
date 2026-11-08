#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <optional>
#include <random>
#include <vector>

#include "Vingress.h"
#include "verilated.h"

#include "command.h"

using Bytes = std::vector<uint8_t>;

static Vingress* dut;
static std::mt19937_64 rng;
static uint64_t cycle;

static bool     haveExpected;
static uint64_t expected;
static bool     gapSeen;
static uint32_t msgCount;

struct Due {
	Command  cmd;
	uint64_t seq;
	uint32_t index;
	uint32_t arrive;
};
static std::optional<Due> due;
static bool held;
static bool readyLow;

static uint64_t covTaken, covSkippedType, covSkippedLocate, covShort, covRetrans, covGap,
                covHeartbeat, covEos, covBad, covTruncated, covZeroLen, covHeld, covOverrun;

[[noreturn]] static void Fail(const char* what) {
	std::printf("FAIL cycle %llu: %s\n", (unsigned long long)cycle, what);
	std::exit(1);
}

static uint64_t Be(const uint8_t* p, int n) {
	uint64_t v = 0;
	for (int i = 0; i < n; i++) v = v << 8 | p[i];
	return v;
}

static void Clock() {
	const bool accept = dut->cmd_valid && dut->cmd_ready;
	if (dut->cmd_valid && !dut->cmd_ready) covHeld++;
	dut->eval();
	dut->cycle = (uint32_t)cycle;
	dut->clk = 1;
	dut->eval();
	dut->clk = 0;
	dut->eval();
	cycle++;

	if (held && accept) held = false;
	if (due) {
		if (!dut->cmd_valid) Fail("no command the cycle after the message");
		const Command& c = due->cmd;
		if (dut->cmd_type != (uint8_t)c.type) Fail("cmd_type");
		if (dut->cmd_orn != c.orderId) Fail("cmd_orn");
		if (c.type == 'A' || c.type == 'F') {
			if (dut->cmd_side != (c.side == Side::Sell)) Fail("cmd_side");
			if (dut->cmd_price != c.price) Fail("cmd_price");
		}
		if (c.type == 'U') {
			if (dut->cmd_new_orn != c.newOrderId) Fail("cmd_new_orn");
			if (dut->cmd_price != c.price) Fail("cmd_price");
		}
		if (c.type != 'D' && dut->cmd_shares != c.shares) Fail("cmd_shares");
		if (dut->cmd_mold_seq != due->seq) Fail("cmd_mold_seq");
		if (dut->cmd_msg_index != due->index) Fail("cmd_msg_index");
		if (dut->cmd_t_arrive != due->arrive) Fail("cmd_t_arrive");
		due.reset();
		held = true;
	} else if (dut->cmd_valid != held) {
		Fail(held ? "command dropped before accept" : "command out of nowhere");
	}
	if (dut->mold_gap_seen != gapSeen) Fail("mold_gap_seen");
}

static uint32_t busy;
static void Cycle(uint8_t data, bool valid, bool eof, bool bad) {
	dut->m_data = valid ? data : (uint8_t)rng();
	dut->m_valid = valid;
	dut->m_eof = eof;
	dut->m_bad = eof ? bad : rng() & 1;
	if (busy) busy--;
	dut->cmd_ready = !readyLow && busy == 0;
	if (dut->cmd_valid && dut->cmd_ready) busy = 1 + rng() % 18;
	Clock();
}

struct Frame {
	Bytes payload;
	bool  bad;
};

static bool filterEn;
static uint16_t locate;

static void Feed(const Frame& f, uint32_t gapPct) {
	auto byte = [&](size_t i) {
		while (rng() % 100 < gapPct) Cycle(0, false, false, false);
		Cycle(f.payload[i], true, false, false);
	};

	const Bytes& p = f.payload;
	size_t n = p.size(), i = 0;
	bool commit = false;
	uint64_t next = 0;

	for (; i < n && i < 19; i++) byte(i);
	if (n >= 20) {
		const uint64_t seq = Be(&p[10], 8);
		const uint16_t count = (uint16_t)Be(&p[18], 2);
		const bool eos = count == 0xFFFF;
		const bool retrans = haveExpected && seq < expected;
		while (rng() % 100 < gapPct) Cycle(0, false, false, false);
		if (eos) covEos++;
		else if (retrans) covRetrans++;
		else if (haveExpected && seq > expected) { covGap++; gapSeen = true; }
		if (count == 0) covHeartbeat++;
		if (!eos) {
			commit = !retrans;
			next = count == 0 ? seq : seq + count;
		}
		Cycle(p[i++], true, false, false);

		for (uint32_t m = 0; !eos && m < count && i < n; m++) {
			if (i + 2 > n) { while (i < n) byte(i++); break; }
			const uint16_t len = (uint16_t)Be(&p[i], 2);
			byte(i++);
			if (i + 1 + len > n || len == 0) {
				if (len == 0) { msgCount++; covZeroLen++; }
				byte(i++);
				if (len == 0) continue;
				while (i < n) byte(i++);
				covTruncated++;
				break;
			}
			byte(i++);
			const uint8_t* msg = &p[i];
			for (uint16_t b = 0; b + 1 < len; b++) byte(i++);
			const uint32_t index = msgCount++;
			std::optional<Command> cmd = ParseCommand(msg, len);
			bool take = !retrans;
			if (!cmd) {
				const bool book = std::strchr("AFECXDU", msg[0]) && msg[0];
				(book ? covShort : covSkippedType)++;
				take = false;
			} else if (len >= 3 && filterEn && Be(msg + 1, 2) != locate) {
				covSkippedLocate++;
				take = false;
			}
			while (rng() % 100 < gapPct) Cycle(0, false, false, false);
			if (take) {
				if (held && readyLow) covOverrun++;
				else { due = Due{*cmd, seq, index, (uint32_t)cycle}; covTaken++; }
			}
			Cycle(p[i++], true, false, false);
		}
	}
	while (i < n) byte(i++);

	for (int k = rng() % 3; k > 0; k--) Cycle(0, false, false, false);
	if (f.bad) covBad++;
	if (n >= 20 && commit && !f.bad) { expected = next; haveExpected = true; }
	// eth_stack can flag a byte valid with m_eof when the UDP length ran
	// into the FCS; the frame is bad then, and the byte is not payload.
	Cycle((uint8_t)rng(), f.bad && rng() % 2, true, f.bad);
	for (int k = 1 + rng() % 4; k > 0; k--) Cycle(0, false, false, false);
}

static void Reset() {
	dut->rst = 1;
	dut->m_valid = dut->m_eof = 0;
	for (int k = 0; k < 3; k++) {
		dut->eval(); dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); cycle++;
	}
	dut->rst = 0;
	haveExpected = gapSeen = held = false;
	due.reset();
	expected = 0;
	msgCount = 0;
	busy = 0;
	dut->cfg_filter_en = filterEn;
	dut->cfg_locate = locate;
	Clock();
}

static void Put(Bytes& b, uint64_t v, int n) {
	for (int k = n - 1; k >= 0; k--) b.push_back((uint8_t)(v >> (8 * k)));
}

static Bytes Message() {
	static const char types[] = "AFECXDUSPRH";
	static const int lens[] = {36, 40, 31, 36, 23, 19, 35, 12, 44, 39, 25};
	const int k = rng() % 11;
	const char t = types[k];
	int len = lens[k];
	const uint32_t r = rng() % 100;
	if (r < 4) len = 1 + rng() % len;
	else if (r < 8) len += 1 + rng() % 8;
	Bytes m(len);
	for (auto& b : m) b = (uint8_t)rng();
	m[0] = (uint8_t)t;
	if (len >= 3) {
		const uint16_t loc = rng() % 4 ? locate : 1 + rng() % 3;
		m[1] = loc >> 8;
		m[2] = loc & 0xFF;
	}
	if ((t == 'A' || t == 'F') && len > 19) m[19] = rng() % 4 ? (rng() & 1 ? 'B' : 'S') : (uint8_t)rng();
	return m;
}

static Frame Packet(uint64_t seq) {
	Frame f{};
	Bytes& p = f.payload;
	for (int k = 0; k < 10; k++) p.push_back('A' + rng() % 26);
	Put(p, seq, 8);
	const uint32_t r = rng() % 100;
	uint16_t count = r < 5 ? 0 : r < 9 ? 0xFFFF : 1 + rng() % 12;
	if (r >= 9 && rng() % 20 == 0) count = 0;
	Put(p, count, 2);
	for (uint16_t m = 0; m < (count == 0xFFFF ? 1 + rng() % 3 : count); m++) {
		Bytes msg = rng() % 40 ? Message() : Bytes{};
		Put(p, msg.size(), 2);
		p.insert(p.end(), msg.begin(), msg.end());
	}
	if (rng() % 10 == 0) for (int k = rng() % 6; k > 0; k--) p.push_back((uint8_t)rng());
	if (rng() % 12 == 0) p.resize(rng() % (p.size() + 1));
	f.bad = rng() % 12 == 0;
	return f;
}

static void Round() {
	filterEn = rng() % 4 != 0;
	locate = 1 + rng() % 3;
	Reset();
	uint64_t seq = 1 + rng() % 1000;
	for (int k = 0; k < 400; k++) {
		const uint32_t r = rng() % 100;
		uint64_t s = seq;
		if (r < 7) s = seq + 1 + rng() % 5;
		else if (r < 10 && seq > 3) s = seq - 1 - rng() % 3;
		const Frame f = Packet(s);
		if (f.payload.size() >= 20) {
			const uint16_t count = (uint16_t)Be(&f.payload[18], 2);
			if (count != 0xFFFF && s >= seq) seq = count ? s + count : s;
		}
		Feed(f, rng() % 3 ? 0 : 30);
	}
}

static void TestOverrun() {
	filterEn = false;
	locate = 1;
	Reset();
	Frame f{};
	Bytes& p = f.payload;
	for (int k = 0; k < 10; k++) p.push_back('S');
	Put(p, 1, 8);
	Put(p, 2, 2);
	for (int m = 0; m < 2; m++) {
		Bytes d(19, 0);
		d[0] = 'D';
		d[18] = (uint8_t)m;
		Put(p, d.size(), 2);
		p.insert(p.end(), d.begin(), d.end());
	}
	readyLow = true;
	Feed(f, 0);
	if (!dut->cmd_overrun) Fail("cmd_overrun not set");
	readyLow = false;
	Cycle(0, false, false, false);
	Cycle(0, false, false, false);
}

static Frame Simple(uint64_t seq, uint16_t count, bool bad) {
	Frame f{};
	for (int k = 0; k < 10; k++) f.payload.push_back('S');
	Put(f.payload, seq, 8);
	Put(f.payload, count, 2);
	for (uint16_t m = 0; m < (count == 0xFFFF ? 0 : count); m++) {
		Bytes x(23, 0);
		x[0] = 'X';
		Put(f.payload, x.size(), 2);
		f.payload.insert(f.payload.end(), x.begin(), x.end());
	}
	f.bad = bad;
	return f;
}

static void TestSequence() {
	filterEn = false;
	locate = 0;
	Reset();
	Feed(Simple(10, 2, false), 0);
	Feed(Simple(20, 0xFFFF, false), 0);
	Feed(Simple(11, 1, false), 0);
	Feed(Simple(12, 0, false), 0);
	Feed(Simple(12, 3, true), 0);
	if (gapSeen || dut->mold_gap_seen) Fail("gap flagged too early");
	Feed(Simple(15, 1, false), 0);
	if (!gapSeen) Fail("bad frame did not lead to a gap");
	for (int k = 0; k < 8; k++) {
		Frame f = Simple(16 + k, 1, true);
		f.payload.pop_back();
		Feed(f, 0);
	}
}

static void Replay(const char* path) {
	std::ifstream in(path, std::ios::binary);
	if (!in) Fail("cannot open the .mold file");
	const Bytes buf((std::istreambuf_iterator<char>(in)), {});
	Reset();
	size_t off = 0, packets = 0;
	while (off + 20 <= buf.size()) {
		const uint16_t count = (uint16_t)Be(&buf[off + 18], 2);
		size_t end = off + 20;
		if (count != 0xFFFF)
			for (uint16_t m = 0; m < count && end + 2 <= buf.size(); m++) end += 2 + Be(&buf[end], 2);
		if (end > buf.size()) Fail("truncated .mold file");
		Feed(Frame{Bytes(buf.begin() + off, buf.begin() + end), false}, 0);
		off = end;
		packets++;
	}
	std::printf("PASS replay %s: %zu packets, %u messages, %llu commands, %llu cycles\n", path,
	            packets, msgCount, (unsigned long long)covTaken, (unsigned long long)cycle);
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	dut = new Vingress;

	if (argc > 2 && std::strcmp(argv[1], "--mold") == 0) {
		filterEn = argc > 3;
		locate = argc > 3 ? (uint16_t)std::strtoul(argv[3], nullptr, 0) : 0;
		Replay(argv[2]);
		dut->final();
		return 0;
	}

	const uint64_t seed = argc > 1 ? std::strtoull(argv[1], nullptr, 0) : 1;
	const uint32_t rounds = argc > 2 ? std::strtoul(argv[2], nullptr, 0) : 10;
	rng.seed(seed);

	TestOverrun();
	TestSequence();
	for (uint32_t k = 0; k < rounds; k++) Round();

	if (!(covTaken && covSkippedType && covSkippedLocate && covShort && covRetrans && covGap &&
	      covHeartbeat && covEos && covBad && covTruncated && covZeroLen && covHeld && covOverrun))
		Fail("coverage hole: a required case was never reached");
	std::printf("PASS seed %llu: %llu cycles, %llu commands\n",
	            (unsigned long long)seed, (unsigned long long)cycle, (unsigned long long)covTaken);
	std::printf("  skipped type %llu locate %llu short %llu; retrans %llu gap %llu heartbeat %llu eos %llu bad %llu truncated %llu held %llu\n",
	            (unsigned long long)covSkippedType, (unsigned long long)covSkippedLocate,
	            (unsigned long long)covShort, (unsigned long long)covRetrans,
	            (unsigned long long)covGap, (unsigned long long)covHeartbeat,
	            (unsigned long long)covEos, (unsigned long long)covBad,
	            (unsigned long long)covTruncated, (unsigned long long)covHeld);
	dut->final();
	delete dut;
	return 0;
}
