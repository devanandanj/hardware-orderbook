// golden_dpi.cpp -- DPI-C bridge from the UVM scoreboard to the C++ golden
// model (golden/src/orderbook.cpp). The scoreboard checks the RTL against the
// exact code the rest of the project trusts, not a SystemVerilog re-port.

#include <algorithm>

#include "../../golden/include/orderbook.h"

namespace {

Orderbook book;

// Each side sorted ascending by orderId after every command: the same
// canonical order as the snapshot spec and the UVM monitor.
Order sorted[2][MAX_ORDERS_PER_SIDE];

void refresh() {
    const Order* src[2] = {book.bids, book.asks};
    const uint8_t n[2] = {book.bid_count, book.ask_count};
    for (int s = 0; s < 2; ++s) {
        std::copy(src[s], src[s] + n[s], sorted[s]);
        std::sort(sorted[s], sorted[s] + n[s],
                  [](const Order& a, const Order& b) { return a.orderId < b.orderId; });
    }
}

}  // namespace

extern "C" {

// Return codes for golden_apply; mirrored in book_pkg.sv.
enum { G_OK = 0, G_UNKNOWN = 1, G_EVICTED = 2, G_DISCARDED = 3 };

void golden_reset() {
    book = Orderbook{};
    refresh();
}

int golden_apply(unsigned char typ, unsigned char side,
                 unsigned long long oref, unsigned long long new_ref,
                 unsigned int shares, unsigned int price, unsigned int exe) {
    int rc = G_OK;
    switch (typ) {
        case 'A': {
            const Order o{oref, side ? Side::Sell : Side::Buy, price, shares};
            const AddResult r = AddOrder(&book, o);
            rc = r == AddResult::Evicted   ? G_EVICTED
               : r == AddResult::Discarded ? G_DISCARDED
                                           : G_OK;
            break;
        }
        case 'D':
            rc = CancelOrder(&book, oref) ? G_OK : G_UNKNOWN;
            break;
        case 'E':
            rc = ExecuteOrder(&book, OrderExecute{oref, exe, 0}) ? G_OK : G_UNKNOWN;
            break;
        case 'U':
            rc = ModifyOrder(&book, OrderModify{oref, new_ref, price, shares})
                         == ModifyResult::NotFound ? G_UNKNOWN : G_OK;
            break;
    }
    refresh();
    return rc;
}

int golden_count(unsigned char side) {
    return side ? book.ask_count : book.bid_count;
}

void golden_get(unsigned char side, int idx, unsigned long long* oref,
                unsigned int* price, unsigned int* qty) {
    const Order& o = sorted[side ? 1 : 0][idx];
    *oref = o.orderId;
    *price = o.price;
    *qty = o.quantity;
}

}  // extern "C"
