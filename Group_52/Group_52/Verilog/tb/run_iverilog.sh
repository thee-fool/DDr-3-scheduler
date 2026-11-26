#!/bin/bash
#==============================================================================
# run_iverilog.sh  -  run ONE pre-synthesis test and write waveforms.vcd
#
# usage:  ./run_iverilog.sh [pattern] [mode] [map] [more traffic_gen options]
#           pattern : stream | stride | random     (default stream)
#           mode    : 0 FCFS, 1 FR-FCFS, 2 FR-FCFS+Cap   (default 1)
#           map     : 0 row:bank:col, 1 row:col:bank     (default 0)
# example: ./run_iverilog.sh random 2 1 --n 300 --wr-pct 50 --cap 8
#
# Steps: 1. make the stimulus file     (traffic_gen.py)
#        2. run the golden model       (golden_model.py) -> golden_*.txt
#        3. compile and run the RTL    (iverilog / vvp), which checks itself
#           against the golden files and the 15 protocol rules
#==============================================================================
PATTERN=${1:-stream}
MODE=${2:-1}
MAP=${3:-0}
[ $# -gt 0 ] && shift      # drop the three positional arguments;
[ $# -gt 0 ] && shift      # whatever is left goes to traffic_gen.py
[ $# -gt 0 ] && shift

RTL="../addr_decode.v ../bank_state.v ../timing_global.v \
     ../refresh_engine.v ../txn_queue.v ../eligibility.v ../selector.v \
     ../data_path.v ../top.v"
TB="dram_beh.v sva_checker.v tb_top.v"

python3 traffic_gen.py --pattern $PATTERN --mode $MODE --map $MAP --n 200 "$@" --out stim.txt || exit 1
python3 golden_model.py --stim stim.txt || exit 1

iverilog -g2005 -I.. -o sim.out $RTL $TB || exit 1
vvp sim.out +vcd

echo "Waveforms: gtkwave waveforms.vcd &"
