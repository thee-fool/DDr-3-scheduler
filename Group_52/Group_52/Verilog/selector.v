//==============================================================================
// selector.v  -  pick ONE queue entry and say which command it gets
//------------------------------------------------------------------------------
// Because position in the queue equals age, "oldest" simply means
// "lowest set bit". So the whole policy needs just two find-first units:
//
//   1. if any RD/WR can go      -> the oldest entry with elig_cas   (row hit)
//   2. otherwise                -> the oldest entry with elig_act or elig_pre
//
// (In FCFS mode the eligibility logic only lets entry 0 through, so the same
//  two steps give strict in-order behaviour.)
//
// This module also holds the 8 cap counters of the FR-FCFS+Cap policy.
//==============================================================================
module selector (
  input             clk,
  input             rst_n,
  input      [3:0]  cap_limit,

  input      [15:0] elig_cas,
  input      [15:0] elig_act,
  input      [15:0] elig_pre,
  input      [15:0] bypass,
  input      [2:0]  sel_bank,     // bank of the chosen entry (from the queue)

  output            sel_valid,    // 1 = a command is issued in this cycle
  output     [3:0]  sel_idx,      // queue position of the chosen entry
  output            sel_is_cas,   // the command is a RD or WR
  output            sel_is_act,   // the command is an ACT
  output            sel_is_pre,   // the command is a PRE

  output     [7:0]  cap_reached   // per bank: no more overtaking allowed
);

  // Find the lowest set bit of a 16-bit vector (0 if no bit is set).
  // Scanning from bit 15 down to bit 0 means the lowest set bit is the last
  // one to overwrite the result.
  function [3:0] find_first;
    input [15:0] v;
    integer k;
    begin
      find_first = 4'd0;
      for (k = 15; k >= 0; k = k - 1)
        if (v[k]) find_first = k[3:0];
    end
  endfunction

  wire [15:0] elig_other = elig_act | elig_pre;   // "open or close a row"
  wire        any_cas    = |elig_cas;
  wire        any_other  = |elig_other;

  assign sel_valid  = any_cas || any_other;
  assign sel_idx    = any_cas ? find_first(elig_cas) : find_first(elig_other);
  assign sel_is_cas = any_cas;
  assign sel_is_act = !any_cas && any_other && elig_act[sel_idx];
  assign sel_is_pre = !any_cas && any_other && elig_pre[sel_idx];

  //---------------------------------------------------------------------------
  // Cap counters, one per bank.
  //   +1 : a row hit was served although an older request of the same bank
  //        is still waiting for a different row (it was overtaken)
  //    0 : a new row is opened in that bank (the waiting request got its row)
  //---------------------------------------------------------------------------
  reg [8*4-1:0]  cap_cnt;     // counter of bank b = cap_cnt[b*4 +: 4]
  integer        b;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cap_cnt <= 0;
    end else begin
      for (b = 0; b < 8; b = b + 1) begin
        if (sel_bank == b) begin
          if (sel_is_act)
            cap_cnt[b*4 +: 4] <= 4'd0;
          else if (sel_is_cas && bypass[sel_idx] && (cap_cnt[b*4 +: 4] != 4'd15))
            cap_cnt[b*4 +: 4] <= cap_cnt[b*4 +: 4] + 4'd1;        // stop at 15, never wrap
        end
      end
    end
  end

  genvar g;
  generate
    for (g = 0; g < 8; g = g + 1) begin : G_CAP
      assign cap_reached[g] = (cap_cnt[g*4 +: 4] >= cap_limit);
    end
  endgenerate

endmodule
