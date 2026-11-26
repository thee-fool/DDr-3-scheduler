#!/bin/bash
#==============================================================================
# run_regression.sh  -  the full pre-synthesis regression
#
# Part 1: 3 policies x 3 traffic patterns x 2 address maps x 3 read/write
#         mixes = 54 tests with the real refresh interval (6240 cycles).
# Part 2: 18 more tests with a very short refresh interval (300 cycles) and
#         some idle time, so refresh interrupts the traffic all the time.
#
# Every test must print TEST PASSED (RTL = golden model cycle by cycle, no
# protocol rule violated, read data correct).
# The performance numbers of part 1 are collected in results.csv.
#
# usage: ./run_regression.sh [requests per test, default 400]
#==============================================================================
N=${1:-400}

RTL="../addr_decode.v ../bank_state.v ../timing_global.v \
     ../refresh_engine.v ../txn_queue.v ../eligibility.v ../selector.v \
     ../data_path.v ../top.v"
TB="dram_beh.v sva_checker.v tb_top.v"

iverilog -g2005 -I.. -o sim.out $RTL $TB                            || exit 1
iverilog -g2005 -I.. -Ptb_top.T_REFI=300 -o sim_ref.out $RTL $TB    || exit 1

PASS=0
FAIL=0
echo "pattern,wr_pct,mode,map,cap,requests,cycles,hit_rate_pct,avg_latency,max_latency,bus_util_pct,refresh_ovh_pct" > results.csv

# run one test: $1 = simulator binary, $2 = label, rest = traffic_gen options
run_one () {
  SIM=$1; LABEL=$2; shift 2
  python3 traffic_gen.py "$@" --n $N --out stim.txt
  LINE=$(python3 golden_model.py --stim stim.txt --csv)
  if vvp $SIM | grep -q "TEST PASSED"; then
    PASS=$((PASS+1)); echo "PASS  $LABEL"
  else
    FAIL=$((FAIL+1)); echo "FAIL  $LABEL"
  fi
}

echo "=== Part 1: 54 tests, normal refresh interval ==="
for PATTERN in stream stride random; do
  for WR in 0 30 100; do
    for MODE in 0 1 2; do
      for MAP in 0 1; do
        run_one sim.out "$PATTERN wr=$WR% mode=$MODE map=$MAP" \
                --pattern $PATTERN --wr-pct $WR --mode $MODE --map $MAP --cap 4
        echo "$PATTERN,$WR,$LINE" >> results.csv
      done
    done
  done
done

echo "=== Part 2: 18 tests, refresh every 300 cycles ==="
for PATTERN in stream stride random; do
  for MODE in 0 1 2; do
    for MAP in 0 1; do
      run_one sim_ref.out "refresh-stress $PATTERN mode=$MODE map=$MAP" \
              --pattern $PATTERN --wr-pct 50 --mode $MODE --map $MAP --cap 2 \
              --trefi 300 --gap 6 --seed 7
    done
  done
done

echo "=============================================="
echo " passed: $PASS    failed: $FAIL"
echo " performance numbers: results.csv"
echo "=============================================="
[ $FAIL -eq 0 ]
