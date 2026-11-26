//==============================================================================
// eligibility.v  -  for every queue entry: "which command could go out NOW?"
//------------------------------------------------------------------------------
// Pure combinational logic. For each of the 16 entries it answers:
//
//   elig_cas[i] : the RD/WR of entry i may be issued now   (it is a row hit)
//   elig_act[i] : an ACT for entry i may be issued now     (its bank is closed)
//   elig_pre[i] : a PRE for entry i may be issued now      (wrong row is open)
//
// At most one of the three is 1 for an entry. The selector then just picks
// the oldest entry among the eligible ones.
//
// Three situations an entry can be in (decided by its bank):
//   hit      : the bank is open on exactly the row this entry needs
//   conflict : the bank is open, but on a different row -> PRE, then ACT
//   closed   : the bank has no open row                 -> ACT
//
// The three scheduling policies only differ in WHO is allowed to go:
//   FCFS        : only entry 0 (the oldest request) may do anything.
//   FR-FCFS     : every entry may go. A row is never closed while somebody
//                 in the queue still wants it (row hits come first).
//   FR-FCFS+Cap : like FR-FCFS, but each bank counts how many hits have
//                 jumped ahead of an older conflict request. When the count
//                 reaches cap_limit those hits must wait, the row is closed
//                 and the old request finally gets its turn.
//
// One extra rule in every mode: inside one bank, row hits are served oldest
// first. This keeps a write and a later read of the same address in order.
//==============================================================================
module eligibility (
  input      [1:0]         sched_mode,
  input                    ref_active,     // refresh running: nobody may go

  // the queue
  input      [15:0]        q_valid,
  input      [16*3-1:0]    q_bank,         // entry i = q_bank[i*3 +: 3]
  input      [16*14-1:0]   q_row,          // entry i = q_row[i*14 +: 14]
  input      [15:0]        q_we,

  // the 8 banks
  input      [7:0]         bank_open,
  input      [8*14-1:0]    bank_row,       // bank b  = bank_row[b*14 +: 14]
  input      [7:0]         bank_act_ok,
  input      [7:0]         bank_cas_ok,
  input      [7:0]         bank_pre_ok,

  // rules shared by all banks
  input                    glob_act_ok,
  input                    glob_rd_ok,
  input                    glob_wr_ok,

  // from the cap counters in the selector
  input      [7:0]         cap_reached,

  output reg [15:0]        elig_cas,
  output reg [15:0]        elig_act,
  output reg [15:0]        elig_pre,
  output reg [15:0]        bypass     // this hit would overtake an older conflict
);

  `include "dram_params.vh"   // timing numbers and command codes

  wire fcfs   = (sched_mode == MODE_FCFS);
  wire cap_en = sched_mode[1];             // modes 2 and 3 use the cap

  reg [15:0] in_play;     // entry is allowed to take part at all
  reg [15:0] hit;         // its row is open
  reg [15:0] conf;        // another row is open in its bank
  reg [15:0] older_hit;   // an older entry is a hit in the same bank
  reg [15:0] capped;      // a hit that must wait because of the cap
  reg [7:0]  keep_open;   // per bank: somebody still wants the open row
  reg [2:0]  b;
  integer    i, j;

  always @* begin

    // ---- step 1: classify every entry by looking at its bank ------------
    for (i = 0; i < 16; i = i + 1) begin
      b          = q_bank[i*3 +: 3];
      in_play[i] = q_valid[i] && !ref_active && (!fcfs || (i == 0));
      hit[i]     = in_play[i] && bank_open[b] && (bank_row[b*14 +: 14] == q_row[i*14 +: 14]);
      conf[i]    = in_play[i] && bank_open[b] && (bank_row[b*14 +: 14] != q_row[i*14 +: 14]);
    end

    // ---- step 2: compare each entry with the OLDER entries of its bank --
    for (i = 0; i < 16; i = i + 1) begin
      older_hit[i] = 1'b0;
      bypass[i]    = 1'b0;
      for (j = 0; j < 16; j = j + 1) begin
        if ((j < i) && (q_bank[j*3 +: 3] == q_bank[i*3 +: 3])) begin
          if (hit[j])            older_hit[i] = 1'b1;
          if (conf[j] && hit[i]) bypass[i]    = 1'b1;
        end
      end
      capped[i] = cap_en && bypass[i] && cap_reached[q_bank[i*3 +: 3]];
    end

    // ---- step 3: a row stays open while a hit that may go still needs it -
    keep_open = 8'd0;
    for (i = 0; i < 16; i = i + 1)
      if (hit[i] && !capped[i]) keep_open[q_bank[i*3 +: 3]] = 1'b1;

    // ---- step 4: add the timing rules ------------------------------------
    for (i = 0; i < 16; i = i + 1) begin
      b = q_bank[i*3 +: 3];

      // RD / WR : a hit, oldest hit of its bank, not capped, timing ok
      elig_cas[i] = hit[i] && !older_hit[i] && !capped[i]
                 && bank_cas_ok[b]
                 && (q_we[i] ? glob_wr_ok : glob_rd_ok);

      // ACT : the bank is closed and timing allows opening a row
      elig_act[i] = in_play[i] && !bank_open[b]
                 && bank_act_ok[b] && glob_act_ok;

      // PRE : wrong row is open, nobody needs it any more, timing ok
      elig_pre[i] = conf[i] && !keep_open[b] && bank_pre_ok[b];
    end
  end

endmodule
