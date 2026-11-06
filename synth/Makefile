# SystemVerilog to Verilog for ISE, whose XST reads no SystemVerilog and is
# the only synthesizer for Virtex-5. The .sv files stay the source of truth;
# build/ is generated.
#
#   make          convert into build/
#   make check    convert, then rerun the block tests on the generated Verilog
#
# Needs sv2v and, for check, iverilog and verilator.

ROOT   := $(abspath ..)
SV2V   ?= sv2v
BOOK   := $(addprefix $(ROOT)/rtl/,order_table.sv price_slot.sv price_book.sv)
ETH    := $(wildcard $(ROOT)/ethernet/rtl/*.sv)
INC    := $(ROOT)/rtl/book_pkg.sv $(ROOT)/spec/generated/itch_defs.vh

.PHONY: all check clean

all: build/.stamp

build/.stamp: $(BOOK) $(ETH) $(INC)
	mkdir -p build
	$(SV2V) -I$(ROOT)/rtl -I$(ROOT)/spec/generated $(BOOK) -w build
	$(SV2V) $(ETH) -w build
	touch $@

check: all
	iverilog -g2001 -t null build/*.v
	for t in order_table price_slot price_book; do \
	    $(MAKE) -C $(ROOT)/tb/$$t clean && \
	    $(MAKE) -C $(ROOT)/tb/$$t RTL=$(CURDIR)/build/$$t.v || exit 1; \
	    $(MAKE) -C $(ROOT)/tb/$$t clean; \
	done

clean:
	rm -rf build
