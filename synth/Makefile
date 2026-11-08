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
BOOK   := $(addprefix $(ROOT)/rtl/,orderbook_top.sv ingress.sv egress.sv async_fifo.sv book.sv order_table.sv price_slot.sv price_book.sv)
ETH    := $(wildcard $(ROOT)/ethernet/rtl/*.sv)
BOARD  := $(ROOT)/rtl/xupv5_top.sv
PART   := xc5vlx110t-ff1136-1
INC    := $(ROOT)/rtl/book_pkg.sv $(ROOT)/spec/generated/itch_defs.vh

.PHONY: all check bit clean

all: build/.stamp

build/.stamp: $(BOOK) $(ETH) $(BOARD) $(INC)
	mkdir -p build/board
	$(SV2V) -I$(ROOT)/rtl -I$(ROOT)/spec/generated $(BOOK) -w build
	$(SV2V) $(ETH) -w build
	$(SV2V) $(BOARD) -w build/board
	touch $@

check: all
	iverilog -g2001 -t null build/*.v
	for t in ingress order_table price_slot price_book; do \
	    $(MAKE) -C $(ROOT)/tb/$$t clean && \
	    $(MAKE) -C $(ROOT)/tb/$$t RTL=$(CURDIR)/build/$$t.v || exit 1; \
	    $(MAKE) -C $(ROOT)/tb/$$t clean; \
	done
	$(MAKE) -C $(ROOT)/tb/egress clean
	$(MAKE) -C $(ROOT)/tb/egress RTL="$(addprefix $(CURDIR)/build/,egress.v async_fifo.v)"
	$(MAKE) -C $(ROOT)/tb/egress clean
	$(MAKE) -C $(ROOT)/tb/top clean
	$(MAKE) -C $(ROOT)/tb/top RTL="$(wildcard $(CURDIR)/build/*.v)"
	$(MAKE) -C $(ROOT)/tb/top clean
	$(MAKE) -C $(ROOT)/tb/book clean
	$(MAKE) -C $(ROOT)/tb/book \
	    RTL="$(addprefix $(CURDIR)/build/,book.v order_table.v price_slot.v price_book.v)"
	$(MAKE) -C $(ROOT)/tb/book clean

bit: all
	mkdir -p build/ise
	cd build/ise && ls $(CURDIR)/build/*.v $(CURDIR)/build/board/*.v | sed 's/^/verilog work /' > top.prj
	cd build/ise && echo "run -ifn top.prj -ifmt mixed -top xupv5_top -p $(PART) -ofn xupv5_top.ngc -opt_mode speed" > top.xst
	cd build/ise && xst -ifn top.xst
	cd build/ise && ngdbuild -uc $(CURDIR)/xupv5.ucf -p $(PART) xupv5_top.ngc
	cd build/ise && map -p $(PART) -o map.ncd xupv5_top.ngd
	cd build/ise && par -w map.ncd par.ncd
	cd build/ise && trce -v 10 -u 10 par.ncd map.pcf -o timing.twr
	cd build/ise && bitgen -w par.ncd xupv5_top.bit

clean:
	rm -rf build
