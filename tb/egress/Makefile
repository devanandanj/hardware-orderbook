ROOT   := $(abspath ../..)
RTL    ?= $(ROOT)/rtl/egress.sv $(ROOT)/rtl/async_fifo.sv
SEED   ?= 1
ROUNDS ?= 12
GOLDEN := $(addprefix $(ROOT)/golden/src/,snapshot.cpp book.cpp ordertable.cpp pricebook.cpp)

.PHONY: run clean

run: build/Vegress
	./build/Vegress $(SEED) $(ROUNDS)

build/Vegress: tb.cpp $(RTL) $(GOLDEN)
	verilator --cc --exe --build -j 1 -O2 -Wno-fatal --Mdir build \
	    --top-module egress -I$(ROOT)/spec/generated \
	    -CFLAGS "-std=c++20 -I$(ROOT)/golden/include" \
	    $(RTL) $(abspath tb.cpp) $(GOLDEN)

clean:
	rm -rf build
