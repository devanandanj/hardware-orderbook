# Formal verification driver.
#
# Runs SymbiYosys on the SVA harness in book_props.sv, bound onto the DUT
# in ../rtl/book.v. The DUT does not exist yet; `make prove` will fail with
# a "file not found" until it does. That is intentional -- the properties
# are the contract the RTL must satisfy.

.PHONY: prove bmc cover clean

prove:
	sby -f book.sby prove

bmc:
	sby -f book.sby bmc

cover:
	sby -f book.sby cover

clean:
	rm -rf book_prove book_bmc book_cover
