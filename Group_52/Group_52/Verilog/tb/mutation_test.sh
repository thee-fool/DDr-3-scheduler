#!/bin/bash
#==============================================================================
# mutation_test.sh  -  "who checks the checker?"
#
# A testbench that never fails proves nothing. This script breaks the RTL on
# purpose, one small bug at a time (for example: wait tRCD-1 cycles instead
# of tRCD), and confirms that the testbench notices every one of them.
#
# The original files are not touched: each bug is applied to a copy in a
# temporary folder.
#
# For bugs 1-16 the PROTOCOL CHECKER alone must report the right rule
# (it does not know the golden model). Bugs 17-20 break data or ordering and
# must be caught by the DRAM model or by the golden-model comparison.
#
# usage: ./mutation_test.sh
#==============================================================================
HERE=$(pwd)
WORK=$(mktemp -d)
FILES="addr_decode.v bank_state.v timing_global.v refresh_engine.v \
       txn_queue.v eligibility.v selector.v data_path.v top.v"
TB="$HERE/dram_beh.v $HERE/sva_checker.v $HERE/tb_top.v"

# Two stimulus files with a short refresh interval, so every rule gets busy.
python3 traffic_gen.py --pattern stream --mode 1 --wr-pct 50 --trefi 300 --n 600 --out $WORK/stream.txt
python3 traffic_gen.py --pattern random --mode 1 --wr-pct 50 --trefi 300 --n 600 --out $WORK/random.txt
for P in stream random; do
  python3 golden_model.py --stim $WORK/$P.txt --trace $WORK/$P.trace --rsp $WORK/$P.rsp > /dev/null
done

DETECTED=0
MISSED=0

# mutate <name> <file> <sed expression> <text that must appear> [simulator option]
mutate () {
  NAME=$1; FILE=$2; EXPR=$3; EXPECT=$4; OPT=$5
  rm -rf $WORK/rtl; mkdir $WORK/rtl
  for F in $FILES; do cp ../$F $WORK/rtl/; done
  cp ../dram_params.vh $WORK/rtl/          # header, included by every module
  sed -i "$EXPR" $WORK/rtl/$FILE
  if cmp -s ../$FILE $WORK/rtl/$FILE; then
    echo "SCRIPT ERROR: '$NAME' did not change $FILE"; MISSED=$((MISSED+1)); return
  fi
  (cd $WORK/rtl && iverilog -g2005 -I. -Ptb_top.T_REFI=300 -o ../mut.out $FILES $TB) || { echo "COMPILE ERROR: $NAME"; return; }
  OUT=""
  for P in stream random; do
    OUT="$OUT$(cd $WORK && vvp mut.out +stim=$P.txt +trace=$P.trace +rsp=$P.rsp $OPT)"
  done
  if echo "$OUT" | grep -q "$EXPECT"; then
    DETECTED=$((DETECTED+1)); echo "detected  $NAME   (looked for: $EXPECT)"
  else
    MISSED=$((MISSED+1));     echo "MISSED    $NAME   (looked for: $EXPECT)"
  fi
}

#        name                               file               bug                                                           must report
mutate "01 tRCD one cycle short"          bank_state.v      's/cnt_rcd <= tRCD - 1/cnt_rcd <= tRCD - 2/'                   "R1 "   +nogolden
mutate "02 tRAS one cycle short"          bank_state.v      's/cnt_ras <= tRAS - 1/cnt_ras <= tRAS - 2/'                   "R2 "   +nogolden
mutate "03 tRP one cycle short"           bank_state.v      's/cnt_rp  <= tRP - 1/cnt_rp  <= tRP - 2/'                     "R3 "   +nogolden
mutate "04 tRC not checked (+short tRAS)" bank_state.v      's/ && (cnt_rc  == 0)//; s/cnt_ras <= tRAS - 1/cnt_ras <= tRAS - 2/' "R4 "   +nogolden
mutate "05 tRRD one cycle short"          timing_global.v   's/cnt_rrd <= tRRD - 1/cnt_rrd <= tRRD - 2/'                   "R5 "   +nogolden
mutate "06 tFAW not checked"              timing_global.v   's/ && (faw\[faw_ptr\*5 +: 5\] == 0)//'                        "R6 "   +nogolden
mutate "07 tCCD one cycle short"          timing_global.v   's/cnt_ccd <= tCCD - 1/cnt_ccd <= tCCD - 2/'                   "R7 "   +nogolden
mutate "08 tRTP one cycle short"          bank_state.v      's/cnt_rtp <= tRTP - 1/cnt_rtp <= tRTP - 2/'                   "R8 "   +nogolden
mutate "09 write recovery one short"      bank_state.v      's/cnt_wr  <= tWR2PRE - 1/cnt_wr  <= tWR2PRE - 2/'             "R9 "   +nogolden
mutate "10 WR->RD one cycle short"        timing_global.v   's/cnt_wtr <= tWR2RD - 1/cnt_wtr <= tWR2RD - 2/'               "R10 "   +nogolden
mutate "11 RD->WR one cycle short"        timing_global.v   's/cnt_rtw <= tRD2WR - 1/cnt_rtw <= tRD2WR - 2/'               "R11 "   +nogolden
mutate "12 REF without waiting tRP"       refresh_engine.v  's/(state == S_REF)   && all_act_ok && ref_ok/(state == S_REF) \&\& ref_ok/' "R12 "   +nogolden
mutate "13 tRFC one cycle short"          timing_global.v   's/cnt_rfc <= tRFC - 1/cnt_rfc <= tRFC - 2/'                   "R13 "   +nogolden
mutate "14 RD/WR to a closed bank"        eligibility.v     's/hit\[i\]     = in_play\[i\] && bank_open\[b\] &&/hit[i]     = in_play[i] \&\&/' "R14 "   +nogolden
mutate "15 bursts collide on the DQ bus"  timing_global.v   's/cnt_rtw <= tRD2WR - 1/cnt_rtw <= 3/'                        "R15 "   +nogolden
mutate "16 urgent refresh never happens"  refresh_engine.v  's/|| (owed >= MAX_POSTPONE)/|| 1'"'"'b0/'                     "X2 "   +nogolden
mutate "17 read data sampled too early"   data_path.v       's/localparam RD_LEN = CL  + BL2;/localparam RD_LEN = CL + BL2 - 1;/' "RTL response"
mutate "18 write data window too short"   data_path.v       's/|wr_vld\[WR_LEN-1:CWL-1\]/|wr_vld[WR_LEN-1:CWL]/'           "DRAM MODEL ERROR"
mutate "19 queue: add+remove bug"         txn_queue.v       's/retire ? (count - 5'"'"'d1) : count/count/'                 "MISMATCH"
mutate "20 address decode: wrong bank"    addr_decode.v     's/addr\[13:11\];/addr[12:10];/'                               "MISMATCH"

rm -rf $WORK
echo "=============================================="
echo " bugs detected: $DETECTED     bugs missed: $MISSED"
echo "=============================================="
[ $MISSED -eq 0 ]
