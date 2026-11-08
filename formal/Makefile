# Formal verification driver.
#
# Runs SymbiYosys on book_formal.sv, a free-input top around ../rtl/book.sv,
# at the small geometry in book_small.yaml. generated/ is committed, like
# spec/generated/; after editing book_small.yaml, run:
#   python3 ../spec/gen.py --book book_small.yaml --outdir generated

.PHONY: prove bmc cover clean

prove:
	sby -f book.sby prove

bmc:
	sby -f book.sby bmc

cover:
	sby -f book.sby cover

clean:
	rm -rf book_prove book_bmc book_cover
