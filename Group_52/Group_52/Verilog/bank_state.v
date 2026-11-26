//==============================================================================
// bank_state.v  -  everything we must remember about ONE bank
//------------------------------------------------------------------------------
// The design has 8 copies of this module, one per bank.
//
// A bank is either closed (no row open) or open (one row sits in the row
// buffer). On top of that, six down-counters remember how long ago the last
// ACT / PRE / RD / WR happened, so that the next command is not sent too early.
//
// How every counter works:
//   - when its command is issued, load (delay - 1)
//   - otherwise count down by one each cycle and stop at 0
//   - the next command is allowed only when the counter is 0
//   Loading (delay - 1) makes the gap between the two commands exactly
//   "delay" cycles.
//
// The four textbook states are easy to read off these registers:
//   IDLE        : row_open = 0 and cnt_rp  = 0
//   PRECHARGING : row_open = 0 and cnt_rp != 0
//   ACTIVATING  : row_open = 1 and cnt_rcd != 0
//   ACTIVE      : row_open = 1 and cnt_rcd = 0
//==============================================================================
module bank_state (
  input             clk,
  input             rst_n,

  // "a command was issued to this bank in this cycle"
  input             ev_act,     // ACT : open row act_row
  input             ev_rd,      // RD
  input             ev_wr,      // WR
  input             ev_pre,     // PRE (also set for a precharge-all)
  input      [13:0] act_row,    // row address that comes with ev_act

  // what the scheduler needs to know
  output reg        row_open,   // 1 = a row is open in this bank
  output reg [13:0] open_row,   // which row (only meaningful if row_open)
  output            act_ok,     // timing allows an ACT now
  output            cas_ok,     // timing allows a RD or WR now
  output            pre_ok      // timing allows a PRE now
);

  `include "dram_params.vh"   // timing numbers and command codes

  // The six down-counters. Each is just wide enough for its start value.
  reg [3:0] cnt_rcd;   // ACT -> RD/WR      starts at 10
  reg [4:0] cnt_ras;   // ACT -> PRE        starts at 27
  reg [5:0] cnt_rc;    // ACT -> ACT        starts at 38
  reg [3:0] cnt_rp;    // PRE -> ACT        starts at 10
  reg [2:0] cnt_rtp;   // RD  -> PRE        starts at  5
  reg [4:0] cnt_wr;    // WR  -> PRE        starts at 23

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      row_open <= 1'b0;
      open_row <= 14'd0;
      cnt_rcd  <= 0;
      cnt_ras  <= 0;
      cnt_rc   <= 0;
      cnt_rp   <= 0;
      cnt_rtp  <= 0;
      cnt_wr   <= 0;
    end else begin

      // ---- is a row open, and which one --------------------------------
      if (ev_act) begin
        row_open <= 1'b1;
        open_row <= act_row;
      end else if (ev_pre) begin
        row_open <= 1'b0;
      end

      // ---- counters started by ACT --------------------------------------
      if (ev_act)            cnt_rcd <= tRCD - 1;
      else if (cnt_rcd != 0) cnt_rcd <= cnt_rcd - 1'b1;

      if (ev_act)            cnt_ras <= tRAS - 1;
      else if (cnt_ras != 0) cnt_ras <= cnt_ras - 1'b1;

      if (ev_act)            cnt_rc  <= tRC - 1;
      else if (cnt_rc != 0)  cnt_rc  <= cnt_rc - 1'b1;

      // ---- counter started by PRE ---------------------------------------
      if (ev_pre)            cnt_rp  <= tRP - 1;
      else if (cnt_rp != 0)  cnt_rp  <= cnt_rp - 1'b1;

      // ---- counters started by RD / WR ----------------------------------
      if (ev_rd)             cnt_rtp <= tRTP - 1;
      else if (cnt_rtp != 0) cnt_rtp <= cnt_rtp - 1'b1;

      if (ev_wr)             cnt_wr  <= tWR2PRE - 1;
      else if (cnt_wr != 0)  cnt_wr  <= cnt_wr - 1'b1;
    end
  end

  // A command is allowed when every counter that guards it has reached 0.
  assign act_ok = (cnt_rp  == 0) && (cnt_rc  == 0);                    // tRP, tRC
  assign cas_ok = (cnt_rcd == 0);                                      // tRCD
  assign pre_ok = (cnt_ras == 0) && (cnt_rtp == 0) && (cnt_wr == 0);   // tRAS, tRTP, tWR

endmodule
