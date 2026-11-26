//==============================================================================
// sva_checker.v  -  the 15 DDR3 timing rules as protocol checks
//------------------------------------------------------------------------------
// This checker watches ONLY the command bus (cmd, cmd_bank, cmd_addr). It
// knows nothing about the inside of the scheduler, so it is an independent
// judge: whatever the scheduler does, a rule violation is reported in the
// very cycle it happens.
//
// How it works: for every kind of command it keeps an "age" = the number of
// cycles since that command was last seen (per bank, and for any bank).
// Every rule is then one line of the form
//        "if this command is on the bus now, that age must be at least T".
// (The scheduler itself uses down-counters, so the two are built differently.)
//
// Plain Verilog-2001: each rule is a small clocked block that calls fail()
// when its condition is false (this is what an immediate assertion does in
// SystemVerilog). The module keeps its old name so the testbench and the
// scripts did not have to change.
//==============================================================================

// One rule = one named clocked check, active only while out of reset.
`define RULE(NAME, COND, MSG) \
  always @(posedge clk) if (rst_n) begin : NAME \
    if (!(COND)) fail(MSG); \
  end

module sva_checker #(
  parameter T_REFI = 6240           // = tREFI; the testbench passes its own value
) (
  input        clk,
  input        rst_n,
  input [2:0]  cmd,
  input [2:0]  cmd_bank,
  input [13:0] cmd_addr
);

  `include "dram_params.vh"   // timing numbers and command codes

  integer errors = 0;     // the testbench reads this at the end

  task fail;
    input [8*48-1:0] msg;
    begin
      errors = errors + 1;
      if (errors <= 20)
        $display("PROTOCOL ERROR t=%0t: %0s  (cmd=%0d bank=%0d addr=%h)",
                 $time, msg, cmd, cmd_bank, cmd_addr);
    end
  endtask

  //---------------------------------------------------------------------------
  // What is on the bus in this cycle?
  //---------------------------------------------------------------------------
  wire is_act = (cmd == CMD_ACT);
  wire is_rd  = (cmd == CMD_RD);
  wire is_wr  = (cmd == CMD_WR);
  wire is_cas = is_rd || is_wr;
  wire is_pre = (cmd == CMD_PRE);
  wire is_ref = (cmd == CMD_REF);

  // which banks a PRE closes: one bank, or all of them if address bit 10 is set
  wire [7:0] pre_banks = !is_pre       ? 8'h00 :
                         cmd_addr[10]  ? 8'hFF : (8'h01 << cmd_bank);

  //---------------------------------------------------------------------------
  // History: ages in cycles (255 means "long ago")
  //---------------------------------------------------------------------------
  reg [7:0] age_act [0:7];   // since the last ACT to this bank
  reg [7:0] age_pre [0:7];   // since the last PRE to this bank
  reg [7:0] age_rd  [0:7];   // since the last RD  to this bank
  reg [7:0] age_wr  [0:7];   // since the last WR  to this bank
  reg [7:0] age_act_any;     // since the last ACT to any bank
  reg [7:0] age_cas_any;     // since the last RD or WR
  reg [7:0] age_rd_any;
  reg [7:0] age_wr_any;
  reg [7:0] age_ref;
  reg [7:0] is_open;         // which banks have an open row

  // act_hist[k] = 1 : an ACT was on the bus k+1 cycles ago (for tFAW)
  reg [tFAW-2:0] act_hist;

  // dq_busy[k] = 1 : the data bus is in use k cycles from now
  reg [31:0] dq_busy;
  wire [31:0] rd_window = {BL2{1'b1}} << CL;    // cycles a RD issued now will use
  wire [31:0] wr_window = {BL2{1'b1}} << CWL;   // cycles a WR issued now will use

  // refresh debt, counted independently of the scheduler
  reg [12:0] refi_cnt;
  reg [4:0]  debt;

  // age + 1, but never past 255
  function [7:0] older;
    input [7:0] a;
    begin
      older = (a == 8'hFF) ? 8'hFF : a + 8'd1;
    end
  endfunction

  function [5:0] count_ones;
    input [tFAW-2:0] v;
    integer k;
    begin
      count_ones = 0;
      for (k = 0; k < tFAW - 1; k = k + 1)
        if (v[k]) count_ones = count_ones + 6'd1;
    end
  endfunction

  integer b;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (b = 0; b < 8; b = b + 1) begin
        age_act[b] <= 8'hFF;
        age_pre[b] <= 8'hFF;
        age_rd[b]  <= 8'hFF;
        age_wr[b]  <= 8'hFF;
      end
      age_act_any <= 8'hFF;
      age_cas_any <= 8'hFF;
      age_rd_any  <= 8'hFF;
      age_wr_any  <= 8'hFF;
      age_ref     <= 8'hFF;
      is_open     <= 8'd0;
      act_hist    <= 0;
      dq_busy     <= 32'd0;
      refi_cnt    <= 0;
      debt        <= 0;
    end else begin
      // a command seen now is 1 cycle old in the next cycle
      for (b = 0; b < 8; b = b + 1) begin
        age_act[b] <= (is_act && cmd_bank == b) ? 8'd1 : older(age_act[b]);
        age_rd[b]  <= (is_rd  && cmd_bank == b) ? 8'd1 : older(age_rd[b]);
        age_wr[b]  <= (is_wr  && cmd_bank == b) ? 8'd1 : older(age_wr[b]);
        age_pre[b] <= pre_banks[b]              ? 8'd1 : older(age_pre[b]);
      end
      age_act_any <= is_act ? 8'd1 : older(age_act_any);
      age_cas_any <= is_cas ? 8'd1 : older(age_cas_any);
      age_rd_any  <= is_rd  ? 8'd1 : older(age_rd_any);
      age_wr_any  <= is_wr  ? 8'd1 : older(age_wr_any);
      age_ref     <= is_ref ? 8'd1 : older(age_ref);

      if (is_act) is_open[cmd_bank] <= 1'b1;
      if (is_pre) is_open           <= is_open & ~pre_banks;

      act_hist <= {act_hist[tFAW-3:0], is_act};

      // one cycle passes on the data bus; a new burst books its cycles
      dq_busy <= (dq_busy >> 1)
               | (is_rd ? (rd_window >> 1) : 32'd0)
               | (is_wr ? (wr_window >> 1) : 32'd0);

      // +1 refresh owed every T_REFI cycles, -1 for every REF
      if (refi_cnt == T_REFI - 1) refi_cnt <= 0;
      else                        refi_cnt <= refi_cnt + 13'd1;
      if ((refi_cnt == T_REFI - 1) && !is_ref)                   debt <= debt + 5'd1;
      if (is_ref && (refi_cnt != T_REFI - 1) && (debt != 5'd0))  debt <= debt - 5'd1;
    end
  end

  // "every bank is closed and its precharge has finished" (needed before REF)
  reg all_idle;
  always @* begin
    all_idle = (is_open == 8'd0);
    for (b = 0; b < 8; b = b + 1)
      if (age_pre[b] < tRP) all_idle = 1'b0;
  end

  //---------------------------------------------------------------------------
  // The 15 rules. Read each line as:  NOT(command on the bus) OR (condition)
  //---------------------------------------------------------------------------
  `RULE(r01_tRCD , !is_cas || (age_act[cmd_bank] >= tRCD),   "R1  ACT->RD/WR same bank < tRCD")
  `RULE(r03_tRP  , !is_act || (age_pre[cmd_bank] >= tRP),    "R3  PRE->ACT same bank < tRP")
  `RULE(r04_tRC  , !is_act || (age_act[cmd_bank] >= tRC),    "R4  ACT->ACT same bank < tRC")
  `RULE(r05_tRRD , !is_act || (age_act_any >= tRRD),         "R5  ACT->ACT any bank < tRRD")
  `RULE(r06_tFAW , !is_act || (count_ones(act_hist) <= 3),   "R6  more than 4 ACTs in tFAW")
  `RULE(r07_tCCD , !is_cas || (age_cas_any >= tCCD),         "R7  RD/WR->RD/WR < tCCD")
  `RULE(r10_tWTR , !is_rd  || (age_wr_any >= tWR2RD),        "R10 WR->RD too early (tWTR)")
  `RULE(r11_tRTW , !is_wr  || (age_rd_any >= tRD2WR),        "R11 RD->WR too early")
  `RULE(r12_REF  , !is_ref || all_idle,                      "R12 REF but banks not idle")
  `RULE(r13_tRFC , (cmd == CMD_NOP) || (age_ref >= tRFC),    "R13 command within tRFC of REF")
  `RULE(r14_open , !is_cas || is_open[cmd_bank],             "R14 RD/WR to a closed bank")
  `RULE(r15_dqbus, !((is_rd && |(dq_busy & rd_window)) || (is_wr && |(dq_busy & wr_window))),
                                                             "R15 two bursts overlap on DQ")

  // Rules about PRE are checked for every bank the PRE closes (one or all 8).
  genvar g;
  generate
    for (g = 0; g < 8; g = g + 1) begin : G_PRE
      `RULE(r02_tRAS, !(pre_banks[g] && is_open[g]) || (age_act[g] >= tRAS), "R2  ACT->PRE < tRAS")
      `RULE(r08_tRTP, !pre_banks[g] || (age_rd[g] >= tRTP),                  "R8  RD->PRE < tRTP")
      `RULE(r09_tWR , !pre_banks[g] || (age_wr[g] >= tWR2PRE),               "R9  WR->PRE < write recovery")
    end
  endgenerate

  // Two extra sanity checks on top of the fifteen.
  `RULE(x1_act_open, !is_act || !is_open[cmd_bank],          "X1  ACT to a bank that is open")
  `RULE(x2_refresh , debt <= MAX_POSTPONE + 1,               "X2  too many refreshes postponed")

endmodule
