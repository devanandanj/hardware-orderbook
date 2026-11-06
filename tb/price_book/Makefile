# Verilator test of rtl/price_book.sv against golden's price book, one build
# per side.
#
#   make                     build and run both sides, seed 1
#   make SEED=7 ROUNDS=100   other seed, longer run

ROOT   ?= $(abspath ../..)
RTL    ?= $(ROOT)/rtl/price_book.sv
SEED   ?= 1
ROUNDS ?= 20

.PHONY: run clean

run: build/0/Vprice_book build/1/Vprice_book
	./build/0/Vprice_book 0 $(SEED) $(ROUNDS)
	./build/1/Vprice_book 1 $(SEED) $(ROUNDS)

build/%/Vprice_book: tb.cpp $(RTL) $(ROOT)/golden/src/pricebook.cpp
	mkdir -p build/$*
	verilator --cc --exe --build -j 1 -O2 -Wno-fatal --Mdir build/$* \
	    --top-module price_book -GSELL=$* -I$(ROOT)/spec/generated \
	    -CFLAGS "-std=c++20 -I$(ROOT)/golden/include" \
	    $(RTL) $(abspath tb.cpp) $(ROOT)/golden/src/pricebook.cpp

clean:
	rm -rf build
