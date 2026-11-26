//==============================================================================
// tb_top.v  -  top-level testbench for ddr3_scheduler
//------------------------------------------------------------------------------
// What it does:
//   1. reads the requests from a stimulus file (made by traffic_gen.py) and
//      feeds them to the scheduler through the valid/ready handshake
//   2. compares EVERY command on the command bus, cycle by cycle, with the
//      golden trace written by the Python model (golden_model.py)
//   3. compares every read response (cycle, id, data) with the golden file
//   4. runs the 15-rule protocol checker (sva_checker.v) on the command bus
//   5. connects the behavioural DRAM (dram_beh.v) so real data is stored
//      and read back
//   6. at the end compares the four performance counters and prints
//      TEST PASSED or TEST FAILED
//
// It only touches the ports of the scheduler, so the same testbench also runs
// on the gate-level netlists after synthesis and after place & route
// (compile with +define+GATE_SIM).
//
// Options on the simulator command line:
//   +stim=<file>  +trace=<file>  +rsp=<file>   input files (see defaults below)
//   +nogolden     do not compare with the golden files; only the protocol
//                 checker and the DRAM model judge the run (no Python needed
//                 apart from the stimulus file)
//   +vcd          dump all signals to waveforms.vcd
//   +vcd_ports    dump only the scheduler ports (small file for submission)
//==============================================================================
`timescale 1ns/1ps

module tb_top;

  `include "dram_params.vh"   // timing numbers and command codes

  parameter T_REFI = tREFI;     // refresh interval; must match the stimulus file

  //---------------------------------------------------------------------------
  // Clock and reset: 200 MHz clock, active-low reset
  //---------------------------------------------------------------------------
  reg clk   = 1'b0;
  reg rst_n = 1'b0;
  always #2.5 clk = ~clk;

  //---------------------------------------------------------------------------
  // Scheduler ports
  //---------------------------------------------------------------------------
  reg          req_valid = 1'b0;
  wire         req_ready;
  reg  [27:0]  req_addr  = 28'd0;
  reg          req_we    = 1'b0;
  reg  [127:0] req_wdata = 128'd0;
  reg  [3:0]   req_id    = 4'd0;
  reg  [1:0]   sched_mode   = 2'd0;
  reg          addr_map_sel = 1'b0;
  reg  [3:0]   cap_limit    = 4'd0;
  wire [2:0]   cmd;
  wire [2:0]   cmd_bank;
  wire [13:0]  cmd_addr;
  wire         dq_wvalid;
  wire [127:0] dq_wdata;
  wire [127:0] dq_rdata;
  wire         rsp_valid;
  wire [3:0]   rsp_id;
  wire [127:0] rsp_rdata;
  wire [31:0]  perf_hits, perf_conflicts, perf_cmds, perf_refs;

  //---------------------------------------------------------------------------
  // Device under test, DRAM model, protocol checker
  //---------------------------------------------------------------------------
`ifdef GATE_SIM
  ddr3_scheduler dut (                       // a netlist has no parameters
`else
  ddr3_scheduler #(.T_REFI(T_REFI)) dut (
`endif
    .clk(clk), .rst_n(rst_n),
    .req_valid(req_valid), .req_ready(req_ready), .req_addr(req_addr),
    .req_we(req_we), .req_wdata(req_wdata), .req_id(req_id),
    .sched_mode(sched_mode), .addr_map_sel(addr_map_sel), .cap_limit(cap_limit),
    .cmd(cmd), .cmd_bank(cmd_bank), .cmd_addr(cmd_addr),
    .dq_wvalid(dq_wvalid), .dq_wdata(dq_wdata), .dq_rdata(dq_rdata),
    .rsp_valid(rsp_valid), .rsp_id(rsp_id), .rsp_rdata(rsp_rdata),
    .perf_hits(perf_hits), .perf_conflicts(perf_conflicts),
    .perf_cmds(perf_cmds), .perf_refs(perf_refs)
  );

  dram_beh u_dram (
    .clk(clk), .rst_n(rst_n),
    .cmd(cmd), .cmd_bank(cmd_bank), .cmd_addr(cmd_addr),
    .dq_wvalid(dq_wvalid), .dq_wdata(dq_wdata), .dq_rdata(dq_rdata)
  );

  sva_checker #(.T_REFI(T_REFI)) u_chk (
    .clk(clk), .rst_n(rst_n),
    .cmd(cmd), .cmd_bank(cmd_bank), .cmd_addr(cmd_addr)
  );

  //---------------------------------------------------------------------------
  // Files
  //---------------------------------------------------------------------------
  reg [8*256-1:0] stim_name, trace_name, rsp_name;
  integer fd_stim, fd_trace, fd_rsp, fd_log;
  integer code;

  // test configuration (first line of the stimulus file)
  integer cfg_mode, cfg_map, cfg_cap, cfg_trefi, cfg_nreq;

  // the next command / response the golden model expects
  integer      exp_cyc, exp_cmd, exp_bank;
  reg [13:0]   exp_addr;
  integer      exp_rsp_cyc, exp_rsp_id;
  reg [127:0]  exp_rsp_data;
  integer      exp_hits, exp_conflicts, exp_cmds, exp_refs;

  integer cyc      = 0;   // cycle number, 0 = first cycle after reset
  integer errors   = 0;   // mismatches against the golden files
  integer n_cmd    = 0;   // commands that matched
  integer n_rsp    = 0;   // responses that matched
  integer n_sent   = 0;   // requests accepted by the scheduler
  integer last_cyc = 0;   // cycle in which the last request was accepted
  reg     no_golden;      // 1 = +nogolden given on the command line

  // read the next expected command (cmd = 7 marks the end of the test)
  task next_cmd;
    begin
      code = $fscanf(fd_trace, "%d %d %d %h", exp_cyc, exp_cmd, exp_bank, exp_addr);
      if (code != 4) begin
        $display("TB ERROR: golden trace ended without an end marker");
        errors = errors + 1;
        exp_cmd = 7;
        exp_cyc = cyc;
      end
    end
  endtask

  // read the next expected read response (cycle = -1 : none left)
  task next_rsp;
    begin
      code = $fscanf(fd_rsp, "%d %d %h", exp_rsp_cyc, exp_rsp_id, exp_rsp_data);
      if (code != 3) exp_rsp_cyc = -1;
    end
  endtask

  //---------------------------------------------------------------------------
  // Driver: offer the requests one after another
  //---------------------------------------------------------------------------
  // Inputs change on the FALLING clock edge, so they are stable when the
  // scheduler samples them on the rising edge (also safe for gate-level runs).
  integer      gap, we_i, id_i;
  reg [27:0]   addr_i;
  reg [127:0]  wdata_i;
  integer      r;

  initial begin
    if (!$value$plusargs("stim=%s",  stim_name))  stim_name  = "stim.txt";
    if (!$value$plusargs("trace=%s", trace_name)) trace_name = "golden_trace.txt";
    if (!$value$plusargs("rsp=%s",   rsp_name))   rsp_name   = "golden_rsp.txt";

    no_golden = $test$plusargs("nogolden");

    fd_stim  = $fopen(stim_name,  "r");
    fd_log   = $fopen("rtl_trace.txt", "w");      // what the RTL really did
    if (fd_stim == 0) begin
      $display("TB ERROR: cannot open the stimulus file. Run traffic_gen.py first.");
      $finish;
    end
    if (!no_golden) begin
      fd_trace = $fopen(trace_name, "r");
      fd_rsp   = $fopen(rsp_name,   "r");
      if (fd_trace == 0 || fd_rsp == 0) begin
        $display("TB ERROR: cannot open the golden files. Run golden_model.py first (or use +nogolden).");
        $finish;
      end
    end

    if ($test$plusargs("vcd")) begin
      $dumpfile("waveforms.vcd");
      $dumpvars(0, tb_top);
    end else if ($test$plusargs("vcd_ports")) begin
      $dumpfile("waveforms.vcd");
      $dumpvars(1, tb_top);
    end

    // configuration line
    code = $fscanf(fd_stim, "%d %d %d %d %d", cfg_mode, cfg_map, cfg_cap, cfg_trefi, cfg_nreq);
    sched_mode   = cfg_mode;
    addr_map_sel = cfg_map;
    cap_limit    = cfg_cap;
`ifndef GATE_SIM
    if (cfg_trefi != T_REFI) begin
      $display("TB ERROR: stimulus was made for trefi=%0d but T_REFI=%0d. Recompile with -Ptb_top.T_REFI=%0d",
               cfg_trefi, T_REFI, cfg_trefi);
      $finish;
    end
`endif
    if (!no_golden) begin
      next_cmd;
      next_rsp;
    end

    // reset for a few cycles, release it on a falling edge
    repeat (4) @(negedge clk);
    rst_n = 1'b1;

    for (r = 0; r < cfg_nreq; r = r + 1) begin
      code = $fscanf(fd_stim, "%d %d %d %h %h", gap, we_i, id_i, addr_i, wdata_i);
      repeat (gap) @(negedge clk);              // idle cycles before this request
      req_valid = 1'b1;
      req_we    = we_i;
      req_id    = id_i;
      req_addr  = addr_i;
      req_wdata = wdata_i;
      @(posedge clk);                           // wait for the edge at which
      while (!req_ready) @(posedge clk);        // the scheduler takes it
      n_sent   = n_sent + 1;
      last_cyc = cyc;
      @(negedge clk);
      req_valid = 1'b0;
    end
  end

  //---------------------------------------------------------------------------
  // Monitor: compare the RTL with the golden model on every rising edge
  //---------------------------------------------------------------------------
  task finish_test;
    begin
      // performance counters must match the model as well
      if (!no_golden)
        code = $fscanf(fd_trace, "%d %d %d %d", exp_hits, exp_conflicts, exp_cmds, exp_refs);
      if (!no_golden && errors == 0 && (code != 4 || perf_hits !== exp_hits || perf_conflicts !== exp_conflicts
                          || perf_cmds !== exp_cmds || perf_refs !== exp_refs)) begin
        $display("MISMATCH: performance counters  RTL %0d %0d %0d %0d   model %0d %0d %0d %0d",
                 perf_hits, perf_conflicts, perf_cmds, perf_refs,
                 exp_hits, exp_conflicts, exp_cmds, exp_refs);
        errors = errors + 1;
      end
      if (!no_golden && errors == 0 && exp_rsp_cyc != -1) begin
        $display("MISMATCH: the model expects more read responses than the RTL produced");
        errors = errors + 1;
      end
      if (errors == 0 && n_sent != cfg_nreq) begin
        $display("MISMATCH: only %0d of %0d requests were accepted", n_sent, cfg_nreq);
        errors = errors + 1;
      end

      $display("------------------------------------------------------------");
      $display(" cycles simulated      : %0d", cyc);
      $display(" requests accepted     : %0d", n_sent);
      if (no_golden) begin
        $display(" golden files NOT used (+nogolden): protocol and DRAM checks only");
      end else begin
        $display(" commands matched      : %0d", n_cmd);
        $display(" read responses matched: %0d", n_rsp);
      end
      $display(" perf_hits=%0d perf_conflicts=%0d perf_cmds=%0d perf_refs=%0d",
               perf_hits, perf_conflicts, perf_cmds, perf_refs);
      $display(" golden-model mismatches : %0d", errors);
      $display(" protocol rule violations: %0d", u_chk.errors);
      $display(" DRAM model errors       : %0d", u_dram.errors);
      if (errors == 0 && u_chk.errors == 0 && u_dram.errors == 0)
        $display(" TEST PASSED");
      else
        $display(" TEST FAILED");
      $display("------------------------------------------------------------");
      $fclose(fd_log);
      $finish;
    end
  endtask

  always @(posedge clk) begin
    if (rst_n) begin

      // ---- command bus ------------------------------------------------------
      if (cmd != CMD_NOP)
        $fdisplay(fd_log, "%0d %0d %0d %h", cyc, cmd, cmd_bank, cmd_addr);

      if (no_golden) begin
        // nothing to compare with
      end else if (cmd != CMD_NOP) begin
        if (exp_cmd != 7 && cyc == exp_cyc && cmd == exp_cmd
            && cmd_bank == exp_bank && cmd_addr == exp_addr) begin
          n_cmd = n_cmd + 1;
          next_cmd;
        end else begin
          $display("MISMATCH cycle %0d: RTL cmd=%0d bank=%0d addr=%h | model expects cmd=%0d bank=%0d addr=%h in cycle %0d",
                   cyc, cmd, cmd_bank, cmd_addr, exp_cmd, exp_bank, exp_addr, exp_cyc);
          errors = errors + 1;
        end
      end else if (exp_cmd != 7 && cyc >= exp_cyc) begin
        $display("MISMATCH cycle %0d: RTL is idle | model expects cmd=%0d bank=%0d addr=%h",
                 cyc, exp_cmd, exp_bank, exp_addr);
        errors = errors + 1;
      end

      // ---- read responses ---------------------------------------------------
      if (no_golden) begin
        // nothing to compare with
      end else if (rsp_valid) begin
        if (cyc == exp_rsp_cyc && rsp_id == exp_rsp_id && rsp_rdata === exp_rsp_data) begin
          n_rsp = n_rsp + 1;
          next_rsp;
        end else begin
          $display("MISMATCH cycle %0d: RTL response id=%0d data=%h | model expects id=%0d data=%h in cycle %0d",
                   cyc, rsp_id, rsp_rdata, exp_rsp_id, exp_rsp_data, exp_rsp_cyc);
          errors = errors + 1;
        end
      end else if (exp_rsp_cyc != -1 && cyc >= exp_rsp_cyc) begin
        $display("MISMATCH cycle %0d: model expects a read response (id=%0d), RTL gave none",
                 cyc, exp_rsp_id);
        errors = errors + 1;
      end

      // ---- end of test ------------------------------------------------------
      // with golden files : stop at the end marker, or early after a few mismatches
      // without           : stop 500 cycles after the last request was accepted
      if (no_golden) begin
        if (n_sent == cfg_nreq && cyc >= last_cyc + 500) finish_test;
      end else if ((exp_cmd == 7 && cyc >= exp_cyc) || errors >= 5 || u_chk.errors >= 20) begin
        finish_test;
      end

      cyc = cyc + 1;
    end
  end

endmodule
