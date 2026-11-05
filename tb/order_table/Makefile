# Verilator test of rtl/order_table.sv against the golden order table.
#
#   make                     build and run, seed 1
#   make SEED=7 ROUNDS=200   other seed, longer run

ROOT   := $(abspath ../..)
PKG    := $(ROOT)/rtl/book_pkg.sv
RTL    ?= $(ROOT)/rtl/order_table.sv
SEED   ?= 1
ROUNDS ?= 40

.PHONY: run clean

run: build/Vorder_table
	./build/Vorder_table $(SEED) $(ROUNDS)

build/Vorder_table: tb.cpp $(PKG) $(RTL) $(ROOT)/golden/src/ordertable.cpp
	verilator --cc --exe --build -j 0 -O2 -Wno-fatal --Mdir build \
	    --top-module order_table -I$(ROOT)/rtl -I$(ROOT)/spec/generated \
	    -CFLAGS "-std=c++20 -I$(ROOT)/golden/include" \
	    $(RTL) $(abspath tb.cpp) $(ROOT)/golden/src/ordertable.cpp

clean:
	rm -rf build
