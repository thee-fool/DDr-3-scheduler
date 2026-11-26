//==============================================================================
// timing_global.v  -  timing rules shared by all 8 banks
//------------------------------------------------------------------------------
// The banks share one command bus and one data bus, so some rules look at
// "the last command to ANY bank". Those counters live here.
//
// Same counter style as bank_state.v: load (delay - 1), count down to 0,
// allowed when 0.
//==============================================================================
module timing_global (
  input  clk,
  input  rst_n,

  // "this kind of command was issued in this cycle" (to any bank)
  input  ev_act,
  input  ev_rd,
  input  ev_wr,
  input  ev_ref,

  output act_ok,   // an ACT is allowed now   (tRRD, tFAW, tRFC)
  output rd_ok,    // a  RD  is allowed now   (tCCD, write-to-read turnaround)
  output wr_ok,    // a  WR  is allowed now   (tCCD, read-to-write turnaround)
  output ref_ok    // a  REF is allowed now   (tRFC since the previous REF)
);

  `include "dram_params.vh"   // timing numbers and command codes

  reg [2:0] cnt_rrd;   // ACT   -> ACT       starts at  5
  reg [1:0] cnt_ccd;   // RD/WR -> RD/WR     starts at  3
  reg [4:0] cnt_wtr;   // WR    -> RD        starts at 17
  reg [3:0] cnt_rtw;   // RD    -> WR        starts at  8
  reg [6:0] cnt_rfc;   // REF   -> anything  starts at 127

  //---------------------------------------------------------------------------
  // tFAW : "no more than 4 ACTs in any 32 cycles"
  //
  // One counter is NOT enough, because the rule looks at the last FOUR ACTs.
  // So we keep four counters, one per recent ACT, used in a circle:
  //   - every ACT loads the counter that faw_ptr points at, then moves faw_ptr
  //   - faw_ptr therefore always points at the OLDEST of the last four ACTs
  //   - a new ACT is allowed only when that oldest one is 32 cycles old (= 0)
  //---------------------------------------------------------------------------
  reg [4*5-1:0]   faw;      // four 5-bit counters, counter k = faw[k*5 +: 5]
  reg [1:0]       faw_ptr;  // which counter the next ACT will use
  integer         i;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt_rrd <= 0;
      cnt_ccd <= 0;
      cnt_wtr <= 0;
      cnt_rtw <= 0;
      cnt_rfc <= 0;
      faw     <= 0;
      faw_ptr <= 0;
    end else begin

      if (ev_act)               cnt_rrd <= tRRD - 1;
      else if (cnt_rrd != 0)    cnt_rrd <= cnt_rrd - 1'b1;

      if (ev_rd || ev_wr)       cnt_ccd <= tCCD - 1;
      else if (cnt_ccd != 0)    cnt_ccd <= cnt_ccd - 1'b1;

      if (ev_wr)                cnt_wtr <= tWR2RD - 1;
      else if (cnt_wtr != 0)    cnt_wtr <= cnt_wtr - 1'b1;

      if (ev_rd)                cnt_rtw <= tRD2WR - 1;
      else if (cnt_rtw != 0)    cnt_rtw <= cnt_rtw - 1'b1;

      if (ev_ref)               cnt_rfc <= tRFC - 1;
      else if (cnt_rfc != 0)    cnt_rfc <= cnt_rfc - 1'b1;

      // all four tFAW counters count down ...
      for (i = 0; i < 4; i = i + 1)
        if (faw[i*5 +: 5] != 0) faw[i*5 +: 5] <= faw[i*5 +: 5] - 1'b1;

      // ... and an ACT reloads the oldest one (this wins over the count-down)
      if (ev_act) begin
        faw[faw_ptr*5 +: 5] <= tFAW - 1;
        faw_ptr      <= faw_ptr + 1'b1;   // 2-bit pointer wraps 3 -> 0
      end
    end
  end

  assign ref_ok = (cnt_rfc == 0);
  assign act_ok = (cnt_rrd == 0) && (faw[faw_ptr*5 +: 5] == 0) && ref_ok;
  assign rd_ok  = (cnt_ccd == 0) && (cnt_wtr == 0);
  assign wr_ok  = (cnt_ccd == 0) && (cnt_rtw == 0);

endmodule
