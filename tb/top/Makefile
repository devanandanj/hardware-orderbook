ROOT   := $(abspath ../..)
SEED   ?= 1
ROUNDS ?= 4
LOCATE ?= 1
BASE   ?= 1000000
RTL    ?= $(addprefix $(ROOT)/rtl/,book_pkg.sv orderbook_top.sv ingress.sv book.sv order_table.sv price_slot.sv price_book.sv egress.sv async_fifo.sv) \
          $(wildcard $(ROOT)/ethernet/rtl/*.sv)
BUILD  := build/$(LOCATE)-$(BASE)
GOLDEN := $(addprefix $(ROOT)/golden/src/,command.cpp itchparser.cpp book.cpp ordertable.cpp pricebook.cpp snapshot.cpp)

.PHONY: run replay clean

run: $(BUILD)/Vorderbook_top
	./$(BUILD)/Vorderbook_top $(SEED) $(ROUNDS)

replay: $(BUILD)/Vorderbook_top
	./$(BUILD)/Vorderbook_top --mold $(MOLD)

$(BUILD)/Vorderbook_top: tb.cpp $(RTL) $(GOLDEN)
	mkdir -p $(BUILD)
	verilator --cc --exe --build -j 4 -O2 -Wno-fatal --Mdir $(BUILD) \
	    --top-module orderbook_top -GLOCATE=$(LOCATE) -GBASE_PRICE=$(BASE) \
	    -I$(ROOT)/rtl -I$(ROOT)/spec/generated \
	    -CFLAGS "-std=c++20 -I$(ROOT)/golden/include -I$(ROOT)/spec/generated -DTOP_LOCATE=$(LOCATE) -DTOP_BASE=$(BASE)" \
	    $(RTL) $(abspath tb.cpp) $(GOLDEN)

clean:
	rm -rf build
