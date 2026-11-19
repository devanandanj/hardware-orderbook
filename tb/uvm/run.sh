#!/usr/bin/env bash
# UVM test of rtl/book.sv against the golden model (DPI-C), on Vivado xsim.
#
#   tb/uvm/run.sh                          book_random_test, seed 1
#   tb/uvm/run.sh book_corner_test 7       named test, seed
#   COUNT=100000 tb/uvm/run.sh             longer random run
set -euo pipefail

TEST=${1:-book_random_test}
SEED=${2:-1}
VIVADO=${VIVADO:-$HOME/2026.1/Vivado/settings64.sh}

cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
command -v xvlog >/dev/null || source "$VIVADO"
mkdir -p build && cd build

# Not xsc: the golden model is C++20, and the DPI boundary is plain integers.
${CXX:-g++} -std=c++20 -O2 -shared -fPIC -o golden_api.so \
    "$ROOT"/golden/src/{golden_api,book,command,itchparser,ordertable,pricebook}.cpp

xvlog -sv -L uvm -i "$ROOT/rtl" -i "$ROOT/spec/generated" -i .. \
    "$ROOT"/rtl/{book,order_table,price_slot,price_book}.sv \
    ../book_if.sv ../book_wr_if.sv ../book_tb_pkg.sv ../tb_top.sv
xelab -L uvm -sv_root . -sv_lib golden_api -timescale 1ns/1ps tb_top -s tb_top_snap --debug off

xsim tb_top_snap -R -sv_seed "$SEED" -testplusarg UVM_TESTNAME="$TEST" \
    ${COUNT:+-testplusarg COUNT="$COUNT"} | tee xsim_run.log

# xsim exits 0 on UVM errors, and SVA failures in book_if bypass UVM's count.
if grep -q '^Error:\|^ERROR:' xsim_run.log; then echo "FAIL: assertion errors"; exit 1; fi
grep -q '\*\*\* PASSED \*\*\*' xsim_run.log
