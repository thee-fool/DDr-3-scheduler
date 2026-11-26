# DDR3 Command Scheduler: code, tests and how to run them

Top module: `ddr3_scheduler` (in `Verilog/top.v`). 8 banks, 16-entry queue,
FCFS / FR-FCFS / FR-FCFS+Cap, all DDR3 timing rules, refresh with postponement.

## 1. What is in this folder

| File | What it is | Owner |
|---|---|---|
| `Verilog/dram_params.vh` | every timing number, command code and policy code (header, `` `include``d inside every module) | A |
| `Verilog/bank_state.v` | one bank: open row + six timers (8 copies) | A |
| `Verilog/timing_global.v` | timers shared by all banks, including tFAW | A |
| `Verilog/refresh_engine.v` | when to refresh, and the refresh sequence | A |
| `Verilog/addr_decode.v` | address to row / bank / column, two mappings | B |
| `Verilog/txn_queue.v` | 16-entry collapsing queue | B |
| `Verilog/eligibility.v` | which entry could send which command now | B |
| `Verilog/selector.v` | picks one entry (policy) + cap counters | B |
| `Verilog/data_path.v` | write-data buffer, write and read latency pipes | D |
| `Verilog/top.v` | wires everything, command output registers, counters | D |
| `Verilog/tb/tb_top.v` | testbench: drives requests, compares with golden files | C |
| `Verilog/tb/dram_beh.v` | behavioural DRAM (stores and returns data) | C |
| `Verilog/tb/sva_checker.v` | the 15 timing rules as clocked checks | C |
| `Verilog/tb/golden_model.py` | cycle-accurate Python reference model | C |
| `Verilog/tb/traffic_gen.py` | makes the stimulus file (stream / stride / random) | C |
| `Verilog/tb/queue_tb.v` | stand-alone test of the queue | B |
| `Verilog/tb/run_iverilog.sh` | run one test, write `waveforms.vcd` | C |
| `Verilog/tb/run_regression.sh` | 72-test regression, writes `results.csv` | C |
| `Verilog/tb/mutation_test.sh` | injects 20 bugs, checks each is caught | C |
| `Verilog/tb/short_test/` | fixed 60-request test for netlist simulations | C |
| `Verilog/tb/results_3000req.csv` | performance numbers, 58 configurations | C |
| `Scripts/constraints.sdc` | 200 MHz constraints | D |
| `Scripts/synthesis.tcl` | Genus template (see section 5) | D |
| `Scripts/rtl_files.f` | RTL file list in compile order | D |

The submission folders `Synthesis/`, `Physical_Design/` and
`Physical_Verification/` are filled by the Cadence tools on the server.

## 2. Quick start (needs iverilog and python3)

```bash
cd Verilog/tb
./run_iverilog.sh                      # one test, FR-FCFS, stream traffic
./run_iverilog.sh random 2 1 --n 300 --wr-pct 50 --cap 8
gtkwave waveforms.vcd &
./run_regression.sh                    # all 72 tests (a few minutes)
./mutation_test.sh                     # proves the checkers can fail
```

Arguments of `run_iverilog.sh`: pattern (`stream`, `stride`, `random`), mode
(0 FCFS, 1 FR-FCFS, 2 FR-FCFS+Cap), address map (0 or 1), then any option of
`traffic_gen.py` (`--n`, `--wr-pct`, `--gap`, `--cap`, `--streams`,
`--stride`, `--seed`).

A test prints `TEST PASSED` only if all three of these hold:

1. every command on the bus matches the Python model in the same cycle, and
   every read response matches in cycle, id and data;
2. none of the 15 timing rules is violated (`sva_checker.v`);
3. the DRAM model saw write data and returned read data at the right cycles.

## 3. How the test flow works

```
traffic_gen.py  ->  stim.txt  --+-->  golden_model.py  ->  golden_trace.txt, golden_rsp.txt
                                |                                   |
                                +-->  tb_top.v (RTL)   <------------+   compares every cycle
```

`tb_top.v` only touches the ports of the scheduler, so the same testbench
runs on the netlists after synthesis and after place and route.

Testbench options: `+stim= +trace= +rsp=` (file names), `+vcd` (all signals),
`+vcd_ports` (ports only, small file), `+nogolden` (protocol and DRAM checks
only, no golden files needed).

## 4. What was verified, and with what

Tools used: Icarus Verilog 12.0, Verilator 5.020, Yosys 0.71, Python 3.12.

| Check | Result |
|---|---|
| Icarus sweep: 3 policies x 2 maps x 3 patterns x 3 write mixes x 2 loads x 2 refresh intervals | 216 of 216 pass |
| `run_regression.sh` as shipped | 72 of 72 pass |
| Verilator random soak with the checker as concurrent `assert property` (random policy, map, cap 0..15, pattern, load, refresh interval) | 491 tests, 16.3 million cycles, 0 failures |
| `mutation_test.sh`: 20 deliberate RTL bugs | 20 of 20 detected |
| `queue_tb.v`: 20,000 random cycles | pass, 4,219 cycles with add and remove at once |
| Yosys synthesis to generic gates | 0 latches, 3,624 flip-flops, about 13,400 gates |
| Simulation of the Yosys gate-level netlist with this testbench | 3 of 3 pass |

The checks above were run on the original SystemVerilog version. The code
was then converted to plain Verilog-2001 (no package, no 2-D packed arrays,
no `assert`, no `$urandom`). The converted version was checked with
ModelSim 10.5b (Intel FPGA edition):

| Check on the Verilog-2001 version | Result |
|---|---|
| `vlog -vlog01compat` (strict Verilog-2001) on all 13 `.v` files | 0 errors, 0 warnings |
| Old SV vs. new Verilog, same stimulus: 3 patterns x 3 policies x 2 maps, plus 6 refresh-stress runs (tREFI 300) | 24 of 24 pass, command traces byte-identical |
| `short_test/` (the netlist-simulation stimulus) | pass (65 commands, 40 responses matched) |
| `queue_tb.v`: 20,000 random cycles | pass |
| The 20 bugs of `mutation_test.sh` | 20 of 20 detected |

Not verified, because no Cadence tools were available:

- Nothing was run in Genus, Innovus or Incisive. `Scripts/synthesis.tcl` is
  a template; `Scripts/constraints.sdc` uses only standard SDC commands.
- 200 MHz is not confirmed. The longest path is 69 simple-gate levels before
  any timing optimisation: queue entry -> eligibility -> selector -> queue
  read-out -> command register. If Genus misses timing, that is the path to
  report.
- The Verilog-2001 version was not run with Icarus (only ModelSim, see
  above). The scripts call `iverilog -g2005 -I..`; `-I..` is needed so the
  compiler finds `dram_params.vh`.

## 5. Running on the IITB server

**Synthesis (Genus).** Copy `5.ALU_CLK_1` as in Assignment 3. Put
`Scripts/constraints.sdc` in place of the example's file. In the example's
`synthesis.tcl` keep the library lines and change only the design name
(`ddr3_scheduler`) and the file list; `Scripts/synthesis.tcl` shows the
lines. The code is plain Verilog, so `read_hdl` needs no `-sv`. One thing
matters: every module includes `dram_params.vh`, so add
`set_db init_hdl_search_path ../Verilog` before `read_hdl`. Do not list the
`.vh` file itself in `read_hdl`.

**Netlist simulation (post-synthesis and post-route).** In the example's
`run-incisive.sh` keep the standard-cell library lines and compile the
netlist, `dram_beh.v`, `sva_checker.v`, `tb_top.v` with the define
`GATE_SIM` and the include path to the header (`+incdir+../Verilog`, or
wherever `dram_params.vh` is). No SystemVerilog switch is needed. Run with

```
+stim=short_test/stim.txt +trace=short_test/golden_trace.txt +rsp=short_test/golden_rsp.txt +vcd_ports
```

This gives a VCD of about 1 MB for the submission.

**Place and route (Innovus).** Use the script provided on the server and
change the design name, netlist and SDC file names. No Innovus script is
included here because it could not be tested.

## 6. Design decisions that differ from the earlier plan and PDF

1. **Address map 1.** The plan put the bank at `addr[3:1]`. Requests are
   16-byte aligned, so that would send everything to bank 0. Used here:
   map 0 = row `[27:14]`, bank `[13:11]`, column `[10:4]`;
   map 1 = row `[27:14]`, column `[13:7]`, bank `[6:4]`.
2. **FCFS is strict in-order.** Only the oldest request may act.
3. **Three extra ports**: `dq_wvalid`, `dq_wdata` (write data to the DRAM)
   and `dq_rdata` (read data from the DRAM). One burst is one 128-bit word.
4. **RD -> WR gap is 9 cycles** (`CL + tCCD + 2 - CWL`), not 8. Check this
   against the datasheet; it is one line in `dram_params.vh`.
5. **`cap_limit` is 4 bits**: sweep 4, 8, 15. A value of 0 forbids all
   overtaking inside a bank.
6. **Row hits inside one bank are served oldest first**, so a write and a
   later read of the same address stay in order.
7. **A row is not closed while a request that may use it is waiting.**
8. **Reset is asynchronous, active low.** Everything is reset except the
   2,048 write-buffer flip-flops.
9. **No one-cycle-early eligibility.** Timers are compared with zero
   directly, which is simpler; see the timing note in section 4.
10. **Traffic is generated in Python**, and the testbench does the trace
    comparison itself (no `traffic_gen.sv`, no `compare_traces.py`).
11. **Rule 14.** The command bus does not carry the row on RD/WR, so the
    checker proves "RD/WR only to an open bank"; a wrong row is caught by
    the read-data comparison.
12. **T_REFI is a parameter of the top module** so tests can shorten the
    refresh interval (`-Ptb_top.T_REFI=300`). The netlist uses 6240.

## 7. Sample results (3,000 requests, 30 % writes, saturating load)

| Traffic | Map | Policy | Cycles | Row hits | Avg latency | Max latency |
|---|---|---|---|---|---|---|
| stream (2 streams) | 0 | FCFS | 124,746 | 0.0 % | 677 | 868 |
| stream (2 streams) | 0 | FR-FCFS | 26,024 | 95.9 % | 151 | 356 |
| stream (2 streams) | 0 | FR-FCFS+Cap 4 | 31,353 | 88.3 % | 180 | 325 |
| stream (2 streams) | 1 | FR-FCFS | 15,424 | 56.0 % | 95 | 358 |
| stride 4096 | 0 | FCFS | 69,529 | 0.0 % | 383 | 549 |
| stride 4096 | 0 | FR-FCFS | 32,798 | 0.0 % | 187 | 233 |
| random | 0 | FCFS | 75,972 | 0.0 % | 417 | 608 |
| random | 0 | FR-FCFS | 25,018 | 0.0 % | 146 | 440 |

Latency is in cycles, from acceptance of a request to its last data beat.
All 58 configurations are in `Verilog/tb/results_3000req.csv`.

How to read them:

- On random traffic the row-hit rate is 0 % for every policy. FR-FCFS is
  still about 3 times faster than FCFS because it overlaps commands to
  different banks, not because of row hits.
- The cap trades throughput for fairness: cap 4 lowers the worst latency
  from 356 to 325 cycles and costs about 20 % more cycles. The effect is
  modest because the 16-entry queue already limits how long a request can
  be overtaken.
- "stream" uses two interleaved streams (like a copy loop). A single stream
  (`--streams 1`) hits the same row under every policy, so it shows no
  difference between them.
- Refresh overhead looks small in short saturated runs, because refreshes
  are postponed and caught up when the queue empties. Use a long run or
  `--gap` to see the steady-state value of about 2 %.
