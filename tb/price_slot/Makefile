# Verilator test of rtl/price_slot.sv against golden's PriceToSlot.
#
#   make             build and run, seed 1

ROOT   ?= $(abspath ../..)
RTL    ?= $(ROOT)/rtl/price_slot.sv
SEED   ?= 1

.PHONY: run clean

run: build/Vprice_slot
	./build/Vprice_slot $(SEED)

build/Vprice_slot: tb.cpp $(RTL) $(ROOT)/golden/src/pricebook.cpp
	verilator --cc --exe --build -j 1 -O2 -Wno-fatal --Mdir build \
	    --top-module price_slot -I$(ROOT)/spec/generated \
	    -CFLAGS "-std=c++20 -I$(ROOT)/golden/include" \
	    $(RTL) $(abspath tb.cpp) $(ROOT)/golden/src/pricebook.cpp

clean:
	rm -rf build
