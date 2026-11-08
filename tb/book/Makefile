# Verilator test of rtl/book.sv against golden's ApplyCommand.
#
#   make                    build and run, seed 1
#   make SEED=7 ROUNDS=40   other seed, longer run
#
# RTL may name one sv2v output file holding all four modules.

ROOT   := $(abspath ../..)
RTL    ?= $(addprefix $(ROOT)/rtl/,book.sv order_table.sv price_slot.sv price_book.sv)
SEED   ?= 1
ROUNDS ?= 6
GOLDEN := $(addprefix $(ROOT)/golden/src/,book.cpp command.cpp itchparser.cpp ordertable.cpp pricebook.cpp)

.PHONY: run clean

run: build/Vbook
	./build/Vbook $(SEED) $(ROUNDS)

build/Vbook: tb.cpp $(RTL) $(ROOT)/rtl/book_pkg.sv $(GOLDEN)
	verilator --cc --exe --build -j 1 -O2 -Wno-fatal --public-flat-rw --Mdir build \
	    --top-module book -I$(ROOT)/rtl -I$(ROOT)/spec/generated \
	    -CFLAGS "-std=c++20 -I$(ROOT)/golden/include" \
	    $(RTL) $(abspath tb.cpp) $(GOLDEN)

clean:
	rm -rf build
