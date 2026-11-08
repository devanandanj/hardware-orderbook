# Verilator test of rtl/ingress.sv against golden's ParseCommand and the
# MoldUDP64 rules in spec/moldudp64.yaml.
#
#   make                          build and run, seed 1
#   make SEED=7 ROUNDS=50         other seed, longer run
#   make replay MOLD=day.mold LOCATE=13
#                                 replay a .mold file from golden/tools/itch_to_mold.py

ROOT   := $(abspath ../..)
RTL    ?= $(ROOT)/rtl/ingress.sv
SEED   ?= 1
ROUNDS ?= 10
GOLDEN := $(addprefix $(ROOT)/golden/src/,command.cpp itchparser.cpp book.cpp ordertable.cpp pricebook.cpp)

.PHONY: run replay clean

run: build/Vingress
	./build/Vingress $(SEED) $(ROUNDS)

replay: build/Vingress
	./build/Vingress --mold $(MOLD) $(LOCATE)

build/Vingress: tb.cpp $(RTL) $(GOLDEN)
	verilator --cc --exe --build -j 1 -O2 -Wno-fatal --Mdir build \
	    --top-module ingress -I$(ROOT)/spec/generated \
	    -CFLAGS "-std=c++20 -I$(ROOT)/golden/include" \
	    $(RTL) $(abspath tb.cpp) $(GOLDEN)

clean:
	rm -rf build
