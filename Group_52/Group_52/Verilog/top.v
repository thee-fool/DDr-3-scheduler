//==============================================================================
// top.v  -  ddr3_scheduler : the complete DDR3 command scheduler
//------------------------------------------------------------------------------
// What happens in every clock cycle:
//
//   1. A request offered by the host (req_valid) is taken into the queue if
//      there is room (req_ready). Its address is split into row/bank/column.
//   2. eligibility looks at all 16 queue entries and at the state of the 8
//      banks and marks which entries could send a command right now.
//   3. selector picks one of them according to the scheduling policy.
//   4. The refresh engine may take over instead (it then blocks step 2).
//   5. The chosen command is written into the cmd / cmd_bank / cmd_addr
//      output registers, so it appears on the DRAM command bus in the NEXT
//      cycle. In the same clock edge the bank state, the timers and the
//      queue are updated, so step 2 of the next cycle sees the new state.
//
// Design boundary: the DRAM command bus plus a simplified data bus
// (dq_*). The PHY, the DQ/DQS pins and power-up initialisation are not part
// of this design.
//
// sched_mode, addr_map_sel and cap_limit are configuration inputs. Set them
// before the first request and keep them stable while requests are pending.
//==============================================================================
module ddr3_scheduler #(
  parameter T_REFI = 6240     // refresh interval = tREFI (tests shorten it)
) (
  input              clk,
  input              rst_n,         // active low, asynchronous

  // ---- request channel from the host (valid / ready handshake) ----------
  input              req_valid,
  output             req_ready,
  input      [27:0]  req_addr,      // byte address, lowest 4 bits ignored
  input              req_we,        // 1 = write, 0 = read
  input      [127:0] req_wdata,     // data of a write request
  input      [3:0]   req_id,        // tag, returned with the read data

  // ---- configuration -----------------------------------------------------
  input      [1:0]   sched_mode,    // 0 FCFS, 1 FR-FCFS, 2 FR-FCFS+Cap
  input              addr_map_sel,  // 0 row:bank:col, 1 row:col:bank
  input      [3:0]   cap_limit,     // max. overtakes per bank in mode 2

  // ---- DRAM command bus --------------------------------------------------
  output reg [2:0]   cmd,           // see CMD_* in dram_params.vh
  output reg [2:0]   cmd_bank,
  output reg [13:0]  cmd_addr,      // row (ACT) or column (RD/WR)

  // ---- DRAM data bus (simplified, one 128-bit word per burst) ------------
  output             dq_wvalid,
  output     [127:0] dq_wdata,
  input      [127:0] dq_rdata,

  // ---- response channel to the host (read data) --------------------------
  output             rsp_valid,
  output     [3:0]   rsp_id,
  output     [127:0] rsp_rdata,

  // ---- performance counters ----------------------------------------------
  output reg [31:0]  perf_hits,       // RD/WR that found its row already open
  output reg [31:0]  perf_conflicts,  // rows closed to make room for another row
  output reg [31:0]  perf_cmds,       // all commands issued (ACT/RD/WR/PRE/REF)
  output reg [31:0]  perf_refs        // REF commands issued
);

  `include "dram_params.vh"   // timing numbers and command codes

  //---------------------------------------------------------------------------
  // Wires between the blocks
  //---------------------------------------------------------------------------
  // address decode
  wire [13:0]       in_row;
  wire [2:0]        in_bank;
  wire [9:0]        in_col;

  // queue
  wire [15:0]       q_valid;
  wire [16*3-1:0]   q_bank;       // entry i = q_bank[i*3 +: 3]
  wire [16*14-1:0]  q_row;        // entry i = q_row[i*14 +: 14]
  wire [15:0]       q_we;
  wire [13:0]       sel_row;
  wire [2:0]        sel_bank;
  wire [9:0]        sel_col;
  wire              sel_we;
  wire [3:0]        sel_id;
  wire [3:0]        sel_wptr;
  wire              q_full;
  wire              q_empty;

  // banks
  wire [7:0]        bank_open;
  wire [8*14-1:0]   bank_row;     // bank b  = bank_row[b*14 +: 14]
  wire [7:0]        bank_act_ok;
  wire [7:0]        bank_cas_ok;
  wire [7:0]        bank_pre_ok;

  // global timing
  wire              glob_act_ok;
  wire              glob_rd_ok;
  wire              glob_wr_ok;
  wire              glob_ref_ok;

  // eligibility and selector
  wire [15:0]       elig_cas;
  wire [15:0]       elig_act;
  wire [15:0]       elig_pre;
  wire [15:0]       bypass;
  wire [7:0]        cap_reached;
  wire              sel_valid;
  wire [3:0]        sel_idx;
  wire              sel_is_cas;
  wire              sel_is_act;
  wire              sel_is_pre;

  // refresh
  wire              ref_active;
  wire              do_prea;
  wire              do_ref;

  // write buffer
  wire [3:0]        free_ptr;
  wire              wbuf_full;

  //---------------------------------------------------------------------------
  // Request handshake
  //---------------------------------------------------------------------------
  // We accept a request when the queue has a free entry and the write buffer
  // has a free slot.
  assign req_ready = !q_full && !wbuf_full;
  wire   push      = req_valid && req_ready;

  //---------------------------------------------------------------------------
  // The command chosen in this cycle (at most one of these is 1)
  //---------------------------------------------------------------------------
  wire issue_act = sel_valid && sel_is_act;
  wire issue_rd  = sel_valid && sel_is_cas && !sel_we;
  wire issue_wr  = sel_valid && sel_is_cas &&  sel_we;
  wire issue_pre = sel_valid && sel_is_pre;

  //---------------------------------------------------------------------------
  // Blocks
  //---------------------------------------------------------------------------
  addr_decode u_decode (
    .addr_map_sel (addr_map_sel),
    .addr         (req_addr),
    .row          (in_row),
    .bank         (in_bank),
    .col          (in_col)
  );

  txn_queue u_queue (
    .clk      (clk),
    .rst_n    (rst_n),
    .push     (push),
    .in_row   (in_row),
    .in_bank  (in_bank),
    .in_col   (in_col),
    .in_we    (req_we),
    .in_id    (req_id),
    .in_wptr  (free_ptr),
    .retire   (issue_rd || issue_wr),   // a request is done when its RD/WR goes out
    .sel_idx  (sel_idx),
    .q_valid  (q_valid),
    .q_bank   (q_bank),
    .q_row    (q_row),
    .q_we     (q_we),
    .sel_row  (sel_row),
    .sel_bank (sel_bank),
    .sel_col  (sel_col),
    .sel_we   (sel_we),
    .sel_id   (sel_id),
    .sel_wptr (sel_wptr),
    .full     (q_full),
    .empty    (q_empty)
  );

  // 8 banks. Each one only sees the commands addressed to it.
  genvar g;
  generate
    for (g = 0; g < 8; g = g + 1) begin : G_BANK
      wire mine = (sel_bank == g);
      bank_state u_bank (
        .clk      (clk),
        .rst_n    (rst_n),
        .ev_act   (issue_act && mine),
        .ev_rd    (issue_rd  && mine),
        .ev_wr    (issue_wr  && mine),
        .ev_pre   ((issue_pre && mine) || do_prea),   // precharge-all hits every bank
        .act_row  (sel_row),
        .row_open (bank_open[g]),
        .open_row (bank_row[g*14 +: 14]),
        .act_ok   (bank_act_ok[g]),
        .cas_ok   (bank_cas_ok[g]),
        .pre_ok   (bank_pre_ok[g])
      );
    end
  endgenerate

  timing_global u_timing (
    .clk    (clk),
    .rst_n  (rst_n),
    .ev_act (issue_act),
    .ev_rd  (issue_rd),
    .ev_wr  (issue_wr),
    .ev_ref (do_ref),
    .act_ok (glob_act_ok),
    .rd_ok  (glob_rd_ok),
    .wr_ok  (glob_wr_ok),
    .ref_ok (glob_ref_ok)
  );

  eligibility u_elig (
    .sched_mode  (sched_mode),
    .ref_active  (ref_active),
    .q_valid     (q_valid),
    .q_bank      (q_bank),
    .q_row       (q_row),
    .q_we        (q_we),
    .bank_open   (bank_open),
    .bank_row    (bank_row),
    .bank_act_ok (bank_act_ok),
    .bank_cas_ok (bank_cas_ok),
    .bank_pre_ok (bank_pre_ok),
    .glob_act_ok (glob_act_ok),
    .glob_rd_ok  (glob_rd_ok),
    .glob_wr_ok  (glob_wr_ok),
    .cap_reached (cap_reached),
    .elig_cas    (elig_cas),
    .elig_act    (elig_act),
    .elig_pre    (elig_pre),
    .bypass      (bypass)
  );

  selector u_select (
    .clk         (clk),
    .rst_n       (rst_n),
    .cap_limit   (cap_limit),
    .elig_cas    (elig_cas),
    .elig_act    (elig_act),
    .elig_pre    (elig_pre),
    .bypass      (bypass),
    .sel_bank    (sel_bank),
    .sel_valid   (sel_valid),
    .sel_idx     (sel_idx),
    .sel_is_cas  (sel_is_cas),
    .sel_is_act  (sel_is_act),
    .sel_is_pre  (sel_is_pre),
    .cap_reached (cap_reached)
  );

  refresh_engine #(.T_REFI(T_REFI)) u_refresh (
    .clk         (clk),
    .rst_n       (rst_n),
    .queue_empty (q_empty),
    .any_open    (|bank_open),
    .all_pre_ok  (&(bank_pre_ok | ~bank_open)),   // closed banks do not matter
    .all_act_ok  (&bank_act_ok),
    .ref_ok      (glob_ref_ok),
    .ref_active  (ref_active),
    .do_prea     (do_prea),
    .do_ref      (do_ref)
  );

  data_path u_data (
    .clk        (clk),
    .rst_n      (rst_n),
    .store      (push && req_we),
    .store_data (req_wdata),
    .free_ptr   (free_ptr),
    .wbuf_full  (wbuf_full),
    .ev_wr      (issue_wr),
    .ev_wr_ptr  (sel_wptr),
    .ev_rd      (issue_rd),
    .ev_rd_id   (sel_id),
    .dq_wvalid  (dq_wvalid),
    .dq_wdata   (dq_wdata),
    .dq_rdata   (dq_rdata),
    .rsp_valid  (rsp_valid),
    .rsp_id     (rsp_id),
    .rsp_rdata  (rsp_rdata)
  );

  //---------------------------------------------------------------------------
  // Command output registers
  //---------------------------------------------------------------------------
  // Registered outputs give the command bus a full clock cycle and no
  // glitches. Every command is delayed by the same one cycle, so all the
  // distances between commands stay exactly as the timers set them.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cmd      <= CMD_NOP;
      cmd_bank <= 3'd0;
      cmd_addr <= 14'd0;
    end else begin
      // default: nothing
      cmd      <= CMD_NOP;
      cmd_bank <= 3'd0;
      cmd_addr <= 14'd0;

      if (do_prea) begin                    // refresh: close all banks
        cmd      <= CMD_PRE;
        cmd_addr <= 14'h0400;               // address bit 10 = "all banks"
      end else if (do_ref) begin            // refresh itself
        cmd      <= CMD_REF;
      end else if (issue_act) begin         // open a row
        cmd      <= CMD_ACT;
        cmd_bank <= sel_bank;
        cmd_addr <= sel_row;
      end else if (issue_rd || issue_wr) begin
        cmd      <= sel_we ? CMD_WR : CMD_RD;
        cmd_bank <= sel_bank;
        cmd_addr <= {4'd0, sel_col};
      end else if (issue_pre) begin         // close one row
        cmd      <= CMD_PRE;
        cmd_bank <= sel_bank;
      end
    end
  end

  //---------------------------------------------------------------------------
  // Performance counters
  //---------------------------------------------------------------------------
  // A RD/WR is a "row hit" unless it is the first access after the ACT that
  // opened the row (that first access had to pay for the ACT).
  // fresh[b] = 1 means: bank b was opened and nothing has used the row yet.
  reg [7:0] fresh;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fresh          <= 8'd0;
      perf_hits      <= 32'd0;
      perf_conflicts <= 32'd0;
      perf_cmds      <= 32'd0;
      perf_refs      <= 32'd0;
    end else begin
      if (issue_act)
        fresh[sel_bank] <= 1'b1;

      if (issue_rd || issue_wr) begin
        fresh[sel_bank] <= 1'b0;
        if (!fresh[sel_bank]) perf_hits <= perf_hits + 32'd1;
      end

      if (issue_pre)        perf_conflicts <= perf_conflicts + 32'd1;
      if (do_ref)           perf_refs      <= perf_refs      + 32'd1;
      if (sel_valid || do_prea || do_ref)
                            perf_cmds      <= perf_cmds      + 32'd1;
    end
  end

endmodule
