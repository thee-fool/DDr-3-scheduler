//==============================================================================
// refresh_engine.v  -  decides WHEN to refresh and runs the refresh sequence
//------------------------------------------------------------------------------
// DRAM cells leak, so the device needs one REF command every tREFI cycles on
// average. We do not have to be exactly on time: up to 8 refreshes may be
// postponed, as long as they are caught up later.
//
//   refi_cnt : counts the cycles of one tREFI interval
//   owed     : how many refreshes we still owe the DRAM
//
// When do we refresh?
//   - "opportunistic" : we owe at least one AND the request queue is empty
//                       (nobody is waiting, so the refresh costs nothing)
//   - "urgent"        : we owe 8 (MAX_POSTPONE). Traffic has to wait.
//
// The refresh sequence (ref_active = 1 blocks all normal commands meanwhile):
//   S_CLOSE : wait until every open row may be closed, then precharge ALL banks
//   S_REF   : wait tRP (and tRFC after a previous REF), then issue REF
//   back to S_IDLE. The tRFC wait after the REF is enforced by timing_global,
//   which simply forbids every ACT (and every further REF) for tRFC cycles.
//==============================================================================
module refresh_engine #(
  parameter T_REFI = 6240          // refresh interval in cycles (tests shorten it)
) (
  input  clk,
  input  rst_n,

  input  queue_empty,   // no request is waiting
  input  any_open,      // at least one bank has an open row
  input  all_pre_ok,    // every OPEN bank may be precharged right now
  input  all_act_ok,    // every bank has finished its precharge (tRP done)
  input  ref_ok,        // tRFC since the previous REF has passed

  output ref_active,    // 1 = refresh sequence running, normal commands wait
  output do_prea,       // issue "precharge all banks" in this cycle
  output do_ref         // issue REF in this cycle
);

  `include "dram_params.vh"   // timing numbers and command codes

  localparam [1:0] S_IDLE  = 2'd0;
  localparam [1:0] S_CLOSE = 2'd1;
  localparam [1:0] S_REF   = 2'd2;

  reg [12:0] refi_cnt;
  reg [3:0]  owed;
  reg [1:0]  state;

  wire tick = (refi_cnt == T_REFI - 1);              // one more refresh is owed
  wire want = ((owed != 0) && queue_empty)           // opportunistic
           || (owed >= MAX_POSTPONE);                // urgent

  assign ref_active = (state != S_IDLE);
  assign do_prea    = (state == S_CLOSE) && any_open && all_pre_ok;
  assign do_ref     = (state == S_REF)   && all_act_ok && ref_ok;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      refi_cnt <= 0;
      owed     <= 0;
      state    <= S_IDLE;
    end else begin

      // ---- interval counter ---------------------------------------------
      if (tick) refi_cnt <= 0;
      else      refi_cnt <= refi_cnt + 1'b1;

      // ---- refresh debt: +1 every interval, -1 for every REF ------------
      if (tick && !do_ref) begin
        if (owed != 4'd15) owed <= owed + 1'b1;    // never wrap around
      end else if (do_ref && !tick) begin
        owed <= owed - 1'b1;
      end

      // ---- the sequence --------------------------------------------------
      case (state)
        S_IDLE : if (want)                 state <= S_CLOSE;
        S_CLOSE: if (!any_open || do_prea) state <= S_REF;   // all rows closed
        S_REF  : if (do_ref)               state <= S_IDLE;
        default:                           state <= S_IDLE;
      endcase
    end
  end

endmodule
