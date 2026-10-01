#!/usr/bin/env bash
# Build and run the UVM testbench on Vivado xsim.
#
#   tb/uvm/run.sh                      # book_random_test, seed 1
#   tb/uvm/run.sh book_fill_test 42    # named test, seed
#
# Needs Vivado's bin/ on PATH (xvlog, xelab, xsim, xsc). On Windows/Git Bash
# the tools are .bat files, which bash runs directly.
set -euo pipefail

TEST=${1:-book_random_test}
SEED=${2:-1}

cd "$(dirname "$0")"
ROOT=../..
mkdir -p build && cd build

ext=""; [[ "${OS:-}" == Windows_NT ]] && ext=".bat"

# DPI-C: the golden model plus its bridge, built into a shared library.
# Not via xsc: its built-in g++ 6.2 tops out at C++14 and the golden model
# is C++20. The DPI boundary is plain integers, so no svdpi.h is needed and
# any compiler will do; on Windows use the newest g++ Vivado bundles.
if [[ -n $ext ]]; then
    viv=$(dirname "$(command -v xvlog.bat)")/..
    CXX=${CXX:-$(ls -d "$viv"/tps/mingw/*/win64.o/nt/bin/g++.exe | sort -V | tail -1)}
    lib=golden_dpi.dll; static="-static -Wl,--out-implib,golden_dpi.a"  # xelab links the .a
else
    CXX=${CXX:-g++}
    lib=golden_dpi.so; static=
fi
"$CXX" -std=c++2a -O2 -shared -fPIC $static -o "$lib" \
    ../golden_dpi.cpp ../$ROOT/golden/src/orderbook.cpp

xvlog$ext -sv -L uvm -i .. \
    ../$ROOT/rtl/book.v \
    ../book_if.sv ../book_pkg.sv ../tb_top.sv

xelab$ext -L uvm -sv_root . -sv_lib golden_dpi -timescale 1ns/1ps tb_top \
    -s tb_top_snap --debug off

# Plusargs go through a file: cmd.exe splits bare arguments at '=', which
# would mangle UVM_TESTNAME=... when run via xsim.bat.
cat > xsim_args.txt <<EOF
-R -sv_seed $SEED
-testplusarg UVM_TESTNAME=$TEST
-testplusarg UVM_VERBOSITY=UVM_LOW
EOF
xsim$ext tb_top_snap -f xsim_args.txt | tee xsim_run.log

# xsim exits 0 even when UVM reports errors, and SVA failures in book_if
# bypass UVM's error count entirely; gate on both.
if grep -q '^ERROR:' xsim_run.log; then echo "FAIL: assertion errors"; exit 1; fi
grep -q '\*\*\* PASSED \*\*\*' xsim_run.log
