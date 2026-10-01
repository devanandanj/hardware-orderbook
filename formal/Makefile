# Formal verification driver.
#
# Runs SymbiYosys on book_formal.sv, a wrapper around ../rtl/book.v.

.PHONY: prove bmc cover clean

prove:
	sby -f book.sby prove

bmc:
	sby -f book.sby bmc

cover:
	sby -f book.sby cover

clean:
	rm -rf book_prove book_bmc book_cover
