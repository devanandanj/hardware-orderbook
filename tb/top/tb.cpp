#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <random>
#include <vector>

#include "Vorderbook_top.h"
#include "verilated.h"

#include "book.h"
#include "command.h"
#include "snapshot.h"

namespace spec {
#include "itch_defs.h"
}

using Bytes = std::vector<uint8_t>;

static constexpr uint64_t MAC = 0x020000000001ull, HOST_MAC = 0x020000000002ull,
                          FEED_MAC = 0x020000000099ull;
static constexpr uint32_t IP = 0xC0A80A02, HOST_IP = 0xC0A80A01, FEED_IP = 0xC0A80A63;
static constexpr uint16_t PORT = 26400, HOST_PORT = 26401;
static constexpr uint16_t LOCATE = TOP_LOCATE;
static constexpr uint32_t BASE = TOP_BASE;
static constexpr uint64_t RX_PERIOD = 8000;
static constexpr uint32_t INIT_CYCLES = SLOTS + 2000;
static constexpr int T_ARRIVE_OFF = 20, T_COMMIT_OFF = 24;

static Vorderbook_top* dut;
static std::mt19937_64 rng;
static uint64_t now, tRx, tTx, txPeriod;

static std::deque<std::pair<uint8_t, bool>> rxq;
static Bytes txFrame;

static Book gold;
static bool haveExpected, gapSeen;
static uint64_t expected;
static uint32_t msgIndex, snapSeq;
static std::vector<std::array<uint8_t, SNAP_PACKET_LEN>> want;
static size_t got;
static uint64_t latMax, latSum;

static uint64_t covApplied, covDropped, covRejected, covUnknown, covRetrans, covGap, covHeartbeat,
                covEos, covBadFcs, covForeign, covOtherLocate, covOtherType, covFrames;

[[noreturn]] static void Fail(const char* what) {
	std::printf("FAIL t=%llu ps, snapshot %zu: %s\n", (unsigned long long)now, got, what);
	std::exit(1);
}

static void Put(Bytes& b, uint64_t v, int n) {
	for (int k = n - 1; k >= 0; k--) b.push_back((uint8_t)(v >> (8 * k)));
}

static void Set(uint8_t* p, uint64_t v, int n) {
	for (int k = n - 1; k >= 0; k--, v >>= 8) p[k] = (uint8_t)v;
}

static uint64_t Get(const uint8_t* p, int n) {
	uint64_t v = 0;
	for (int i = 0; i < n; i++) v = v << 8 | p[i];
	return v;
}

static uint32_t Crc(const uint8_t* p, size_t n) {
	uint32_t c = ~0u;
	for (size_t i = 0; i < n; i++) {
		c ^= p[i];
		for (int k = 0; k < 8; k++) c = c >> 1 ^ (0xEDB88320u & (0u - (c & 1)));
	}
	return ~c;
}

static Bytes UdpFrame(uint64_t dmac, uint64_t smac, uint32_t sip, uint32_t dip, uint16_t sport,
                      uint16_t dport, const Bytes& payload, uint16_t ethertype = 0x0800) {
	Bytes f;
	Put(f, dmac, 6);
	Put(f, smac, 6);
	Put(f, ethertype, 2);
	const size_t ip = f.size();
	Put(f, 0x4500, 2);
	Put(f, 28 + payload.size(), 2);
	Put(f, 0, 2);
	Put(f, 0x4000, 2);
	Put(f, 0x4011, 2);
	Put(f, 0, 2);
	Put(f, sip, 4);
	Put(f, dip, 4);
	uint32_t sum = 0;
	for (int i = 0; i < 20; i += 2) sum += f[ip + i] << 8 | f[ip + i + 1];
	while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
	Set(&f[ip + 10], ~sum & 0xFFFF, 2);
	Put(f, sport, 2);
	Put(f, dport, 2);
	Put(f, 8 + payload.size(), 2);
	Put(f, 0, 2);
	f.insert(f.end(), payload.begin(), payload.end());
	if (f.size() < 60) f.resize(60, 0);
	return f;
}

static void Send(Bytes f, bool badFcs) {
	uint32_t fcs = Crc(f.data(), f.size());
	if (badFcs) fcs ^= 1u << (rng() % 32);
	for (int k = 0; k < 4; k++) f.push_back((uint8_t)(fcs >> (8 * k)));
	for (int k = 0; k < 7; k++) rxq.push_back({0x55, true});
	rxq.push_back({0xD5, true});
	for (uint8_t b : f) rxq.push_back({b, true});
	for (int k = 12 + rng() % 24; k > 0; k--) rxq.push_back({0, false});
}

static void Reference(const Bytes& p, bool bad) {
	if (p.size() < spec::MOLD_HDR_LEN) return;
	const uint64_t seq = Get(&p[spec::MOLD_SEQUENCE_OFF], 8);
	const uint16_t count = (uint16_t)Get(&p[spec::MOLD_MESSAGE_COUNT_OFF], 2);
	if (count == spec::MOLD_END_OF_SESSION) { covEos++; return; }
	const bool retrans = haveExpected && seq < expected;
	if (retrans) covRetrans++;
	if (!retrans && haveExpected && seq > expected) { gapSeen = true; covGap++; }
	if (count == spec::MOLD_HEARTBEAT) covHeartbeat++;

	size_t i = spec::MOLD_HDR_LEN;
	for (uint16_t m = 0; m < count; m++) {
		const uint16_t len = (uint16_t)Get(&p[i], 2);
		const uint8_t* msg = &p[i + 2];
		i += 2 + len;
		const uint32_t index = msgIndex++;
		if (retrans) continue;
		const std::optional<Command> cmd = ParseCommand(msg, len);
		if (!cmd) { covOtherType++; continue; }
		if (Get(msg + 1, 2) != LOCATE) { covOtherLocate++; continue; }
		const Outcome o = ApplyCommand(&gold, *cmd);
		covApplied++;
		covDropped += o.status >> SNAP_STATUS_ORDER_DROPPED & 1;
		covRejected += o.status >> SNAP_STATUS_PRICE_REJECTED & 1;
		covUnknown += o.status >> SNAP_STATUS_UNKNOWN_ORDER_REF & 1;
		std::array<uint8_t, SNAP_PACKET_LEN> pkt;
		EncodeSnapshotPacket(pkt.data(), gold,
		                     o.status | (gapSeen ? 1u << SNAP_STATUS_MOLD_GAP_SEEN : 0u),
		                     snapSeq++, seq, index);
		want.push_back(pkt);
	}
	if (!retrans && !bad) {
		expected = count ? seq + count : seq;
		haveExpected = true;
	}
}

static Bytes header;

static void BuildHeader() {
	const Bytes f = UdpFrame(HOST_MAC, MAC, IP, HOST_IP, PORT, HOST_PORT, Bytes(SNAP_PACKET_LEN));
	header.assign(f.begin(), f.begin() + 42);
}

static void TxFrame() {
	const Bytes& f = txFrame;
	if (f.size() != 8 + 42 + SNAP_PACKET_LEN + 4) Fail("transmit frame length");
	for (int k = 0; k < 7; k++)
		if (f[k] != 0x55) Fail("preamble");
	if (f[7] != 0xD5) Fail("SFD");
	const uint8_t* e = &f[8];
	const size_t n = f.size() - 12;
	if (Crc(e, n) != (e[n] | e[n + 1] << 8 | e[n + 2] << 16 | (uint32_t)e[n + 3] << 24))
		Fail("transmit FCS");
	if (std::memcmp(e, header.data(), 42)) Fail("transmit header");
	if (got >= want.size()) Fail("snapshot nobody expected");
	std::array<uint8_t, SNAP_PACKET_LEN> p;
	std::memcpy(p.data(), e + 42, SNAP_PACKET_LEN);
	const uint32_t arrive = (uint32_t)Get(&p[T_ARRIVE_OFF], 4);
	const uint32_t commit = (uint32_t)Get(&p[T_COMMIT_OFF], 4);
	if (commit <= arrive || commit - arrive > 64) Fail("t_commit - t_arrive");
	latMax = std::max<uint64_t>(latMax, commit - arrive);
	latSum += commit - arrive;
	std::memset(&p[T_ARRIVE_OFF], 0, 8);
	if (p != want[got]) Fail("snapshot payload");
	got++;
}

static void RxEdge() {
	if (rxq.empty()) {
		dut->gmii_rx_dv = 0;
		dut->gmii_rxd = (uint8_t)rng();
	} else {
		dut->gmii_rxd = rxq.front().first;
		dut->gmii_rx_dv = rxq.front().second;
		rxq.pop_front();
	}
	dut->gmii_rx_er = 0;
	dut->gmii_rx_clk = 1;
	dut->eval();
	dut->gmii_rx_clk = 0;
	dut->eval();
}

static void TxEdge() {
	dut->gtx_clk = 1;
	dut->eval();
	dut->gtx_clk = 0;
	dut->eval();
	if (dut->gmii_tx_er) Fail("gmii_tx_er");
	if (dut->gmii_tx_en) txFrame.push_back(dut->gmii_txd);
	else if (!txFrame.empty()) {
		TxFrame();
		covFrames++;
		txFrame.clear();
	}
}

static void Step() {
	now = std::min(tRx, tTx);
	if (tRx == now) { RxEdge(); tRx += RX_PERIOD; }
	if (tTx == now) { TxEdge(); tTx += txPeriod; }
}

static void RunRx(uint64_t cycles) {
	const uint64_t end = now + cycles * RX_PERIOD;
	while (now < end) Step();
}

static void Flush() {
	while (!rxq.empty()) Step();
}

static void Reset() {
	dut->rst_async = 1;
	RunRx(8);
	dut->rst_async = 0;
	RunRx(INIT_CYCLES);
	ResetBook(&gold, BASE);
	haveExpected = gapSeen = false;
	expected = 0;
	msgIndex = snapSeq = 0;
	want.clear();
	got = 0;
}

static void Drain() {
	Flush();
	for (uint64_t k = 0; got < want.size() || !txFrame.empty(); k++) {
		RunRx(100);
		if (k > 100000) Fail("snapshots never arrived");
	}
	RunRx(2000);
	if (got != want.size()) Fail("extra snapshots");
	if (dut->mold_gap_seen != gapSeen) Fail("mold_gap_seen");
	if (dut->cmd_overrun) Fail("cmd_overrun");
	if (dut->snap_overflow) Fail("snap_overflow");
}

struct Live {
	uint64_t orn;
	uint32_t shares;
};
static std::vector<Live> live;
static uint64_t nextOrn = 1;
static uint64_t twins;

static uint64_t NewOrn() {
	if (rng() % 8) return nextOrn++;
	const uint64_t n = twins++ % 1024;
	return 1ull << 40 | n << 20 | n << 10 | 5;
}

static uint32_t RandPrice() {
	const uint32_t r = rng() % 100;
	const int64_t ticks = (int64_t)(rng() % 400) - 200;
	uint32_t p = (uint32_t)(BASE + ticks * 100);
	if (r < 3) p += 1 + rng() % 99;
	else if (r < 5) p = (uint32_t)(BASE + (rng() & 1 ? 1 : -1) * (int64_t)(9000 + rng() % 5000) * 100);
	return p;
}

static Bytes Itch(char t, uint16_t locate) {
	using namespace spec;
	size_t len;
	switch (t) {
	case 'A': len = ITCH_ADD_ORDER_LEN; break;
	case 'F': len = ITCH_ADD_ORDER_MPID_LEN; break;
	case 'E': len = ITCH_ORDER_EXECUTED_LEN; break;
	case 'C': len = ITCH_ORDER_EXECUTED_WITH_PRICE_LEN; break;
	case 'X': len = ITCH_ORDER_CANCEL_LEN; break;
	case 'D': len = ITCH_ORDER_DELETE_LEN; break;
	case 'U': len = ITCH_ORDER_REPLACE_LEN; break;
	case 'S': len = 12; break;
	case 'R': len = 39; break;
	case 'P': len = 44; break;
	default: len = 25; break;
	}
	Bytes m(len);
	for (auto& b : m) b = (uint8_t)rng();
	m[0] = (uint8_t)t;
	Set(&m[1], locate, 2);
	return m;
}

static Bytes BookMessage(uint16_t locate) {
	using namespace spec;
	const bool mine = locate == LOCATE;
	const uint32_t r = rng() % 100;
	const bool known = mine && !live.empty() && rng() % 20;
	const size_t k = known ? rng() % live.size() : 0;
	const uint64_t orn = known ? live[k].orn : rng() % (nextOrn + 10);
	auto forget = [&] { if (known) { live[k] = live.back(); live.pop_back(); } };

	if (r < 40 || live.empty()) {
		const bool f = rng() % 4 == 0;
		Bytes m = Itch(f ? 'F' : 'A', locate);
		const uint32_t shares = 1 + rng() % 1000;
		const uint64_t id = NewOrn();
		Set(&m[f ? ITCH_ADD_ORDER_MPID_ORDER_REF_OFF : ITCH_ADD_ORDER_ORDER_REF_OFF], id, 8);
		m[f ? ITCH_ADD_ORDER_MPID_SIDE_OFF : ITCH_ADD_ORDER_SIDE_OFF] = rng() & 1 ? ITCH_SIDE_BUY_CHAR : 'S';
		Set(&m[f ? ITCH_ADD_ORDER_MPID_SHARES_OFF : ITCH_ADD_ORDER_SHARES_OFF], shares, 4);
		Set(&m[f ? ITCH_ADD_ORDER_MPID_PRICE_OFF : ITCH_ADD_ORDER_PRICE_OFF], RandPrice(), 4);
		if (mine) live.push_back({id, shares});
		return m;
	}
	if (r < 60) {
		const char t = "ECX"[rng() % 3];
		Bytes m = Itch(t, locate);
		const uint32_t shares = known && rng() % 3 ? 1 + rng() % live[k].shares : rng() % 2000;
		const size_t orefOff = t == 'E' ? ITCH_ORDER_EXECUTED_ORDER_REF_OFF
		                     : t == 'C' ? ITCH_ORDER_EXECUTED_WITH_PRICE_ORDER_REF_OFF
		                                : ITCH_ORDER_CANCEL_ORDER_REF_OFF;
		const size_t sharesOff = t == 'E' ? ITCH_ORDER_EXECUTED_EXECUTED_SHARES_OFF
		                       : t == 'C' ? ITCH_ORDER_EXECUTED_WITH_PRICE_EXECUTED_SHARES_OFF
		                                  : ITCH_ORDER_CANCEL_CANCELLED_SHARES_OFF;
		Set(&m[orefOff], orn, 8);
		Set(&m[sharesOff], shares, 4);
		if (known) {
			if (shares >= live[k].shares) forget();
			else live[k].shares -= shares;
		}
		return m;
	}
	if (r < 80) {
		Bytes m = Itch('D', locate);
		Set(&m[ITCH_ORDER_DELETE_ORDER_REF_OFF], orn, 8);
		forget();
		return m;
	}
	Bytes m = Itch('U', locate);
	const uint32_t shares = 1 + rng() % 1000;
	const uint64_t id = NewOrn();
	Set(&m[ITCH_ORDER_REPLACE_ORIGINAL_ORDER_REF_OFF], orn, 8);
	Set(&m[ITCH_ORDER_REPLACE_NEW_ORDER_REF_OFF], id, 8);
	Set(&m[ITCH_ORDER_REPLACE_SHARES_OFF], shares, 4);
	Set(&m[ITCH_ORDER_REPLACE_PRICE_OFF], RandPrice(), 4);
	if (known) {
		forget();
		live.push_back({id, shares});
	}
	return m;
}

static Bytes Message() {
	const uint32_t r = rng() % 100;
	if (r < 8) return Itch("SRPH"[rng() % 4], LOCATE);
	if (r < 20) return BookMessage(LOCATE + 1 + rng() % 3);
	return BookMessage(LOCATE);
}

static Bytes Mold(uint64_t seq, uint16_t count, size_t messages) {
	Bytes p;
	for (char c : std::string("SESSION001")) p.push_back((uint8_t)c);
	Put(p, seq, 8);
	Put(p, count, 2);
	for (size_t m = 0; m < messages; m++) {
		const Bytes msg = Message();
		Put(p, msg.size(), 2);
		p.insert(p.end(), msg.begin(), msg.end());
	}
	return p;
}

static void Deliver(const Bytes& payload, bool badFcs) {
	while (want.size() - got > 48) RunRx(200);
	Send(UdpFrame(MAC, FEED_MAC, FEED_IP, IP, 26477, PORT, payload), badFcs);
	Reference(payload, badFcs);
	if (badFcs) covBadFcs++;
}

static void Foreign(const Bytes& payload) {
	switch (rng() % 4) {
	case 0: Send(UdpFrame(MAC, FEED_MAC, FEED_IP, IP, 26477, PORT + 1, payload), false); break;
	case 1: Send(UdpFrame(MAC, FEED_MAC, FEED_IP, IP + 1, 26477, PORT, payload), false); break;
	case 2: Send(UdpFrame(MAC + 1, FEED_MAC, FEED_IP, IP, 26477, PORT, payload), false); break;
	default: Send(UdpFrame(MAC, FEED_MAC, FEED_IP, IP, 26477, PORT, payload, 0x0806), false); break;
	}
	covForeign++;
}

static void Round(uint32_t packets) {
	Reset();
	live.clear();
	twins = 0;
	std::vector<Bytes> sent;
	uint64_t seq = 1 + rng() % 100000;
	for (uint32_t k = 0; k < packets; k++) {
		const uint32_t r = rng() % 100;
		if (r < 3 && !sent.empty()) {
			Deliver(sent[rng() % sent.size()], false);
		} else if (r < 6) {
			Deliver(Mold(seq, spec::MOLD_HEARTBEAT, 0), false);
		} else if (r < 7) {
			Deliver(Mold(seq + rng() % 5, spec::MOLD_END_OF_SESSION, 0), false);
		} else if (r < 10) {
			Foreign(Mold(seq, 3, 3));
		} else {
			if (r < 13) seq += 1 + rng() % 4;
			const uint16_t count = 1 + rng() % 30;
			const Bytes p = Mold(seq, count, count);
			const bool bad = rng() % 25 == 0;
			Deliver(p, bad);
			sent.push_back(p);
			if (!bad || rng() % 2) seq += count;
		}
	}
	Drain();
}

static void Replay(const char* path) {
	std::ifstream in(path, std::ios::binary);
	if (!in) Fail("cannot open the .mold file");
	const Bytes buf((std::istreambuf_iterator<char>(in)), {});
	Reset();
	size_t off = 0, packets = 0;
	while (off + spec::MOLD_HDR_LEN <= buf.size()) {
		const uint16_t count = (uint16_t)Get(&buf[off + spec::MOLD_MESSAGE_COUNT_OFF], 2);
		size_t end = off + spec::MOLD_HDR_LEN;
		if (count != spec::MOLD_END_OF_SESSION)
			for (uint16_t m = 0; m < count && end + 2 <= buf.size(); m++) end += 2 + Get(&buf[end], 2);
		if (end > buf.size()) Fail("truncated .mold file");
		Deliver(Bytes(buf.begin() + off, buf.begin() + end), false);
		off = end;
		packets++;
	}
	Drain();
	std::printf("PASS replay %s: %zu packets, %u messages, %zu snapshots, latency max %llu cycles\n",
	            path, packets, msgIndex, got, (unsigned long long)latMax);
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	dut = new Vorderbook_top;
	BuildHeader();
	txPeriod = RX_PERIOD;
	tRx = 0;
	tTx = 1000;

	if (argc > 2 && std::strcmp(argv[1], "--mold") == 0) {
		Replay(argv[2]);
		delete dut;
		return 0;
	}

	const uint64_t seed = argc > 1 ? std::strtoull(argv[1], nullptr, 0) : 1;
	const uint32_t rounds = argc > 2 ? std::strtoul(argv[2], nullptr, 0) : 4;
	rng.seed(seed);

	uint64_t snapshots = 0;
	for (uint32_t r = 0; r < rounds; r++) {
		static const uint64_t periods[] = {8000, 7999, 8001};
		txPeriod = periods[r % 3];
		tTx = now + 1 + rng() % txPeriod;
		Round(600);
		snapshots += got;
	}

	if (!(covApplied && covDropped && covRejected && covUnknown && covRetrans && covGap &&
	      covHeartbeat && covEos && covBadFcs && covForeign && covOtherLocate && covOtherType))
		Fail("coverage: a case never happened");
	std::printf("PASS seed %llu: %llu snapshots, t_commit - t_arrive max %llu mean %.1f cycles\n",
	            (unsigned long long)seed, (unsigned long long)snapshots, (unsigned long long)latMax,
	            (double)latSum / snapshots);
	std::printf("  dropped %llu rejected %llu unknown %llu; retrans %llu gap %llu heartbeat %llu eos %llu bad fcs %llu foreign %llu\n",
	            (unsigned long long)covDropped, (unsigned long long)covRejected,
	            (unsigned long long)covUnknown, (unsigned long long)covRetrans,
	            (unsigned long long)covGap, (unsigned long long)covHeartbeat,
	            (unsigned long long)covEos, (unsigned long long)covBadFcs,
	            (unsigned long long)covForeign);
	delete dut;
	return 0;
}
