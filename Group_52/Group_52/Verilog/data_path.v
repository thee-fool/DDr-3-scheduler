//==============================================================================
// data_path.v  -  write-data buffer and the two "latency pipelines"
//------------------------------------------------------------------------------
// The command bus is only half of a memory access. The data itself travels
// on the DQ bus a fixed number of cycles AFTER the command:
//
//   WR command visible on the bus in cycle B
//       -> write data must be on dq_wdata in cycles B+CWL ... B+CWL+BL2-1
//   RD command visible on the bus in cycle B
//       -> read data arrives on dq_rdata in cycles B+CL ... B+CL+BL2-1
//          (the full 128-bit word is complete in the last of these cycles)
//
// This module makes that happen with two simple shift registers ("pipes"):
// a flag enters at stage 0 when the scheduler picks a RD/WR and moves one
// stage per cycle. When it reaches the right stage, we act.
//
// The real DQ/DQS pins and the PHY are outside this project. Here the whole
// burst is handled as one 128-bit word.
//
// Write-data buffer: 16 slots x 128 bits. A write request parks its data in
// a free slot when it enters the queue; the queue entry only remembers the
// 4-bit slot number (wptr).
//==============================================================================
module data_path (
  input              clk,
  input              rst_n,

  // a WRITE request enters the queue in this cycle: keep its data
  input              store,
  input      [127:0] store_data,
  output     [3:0]   free_ptr,     // the slot it will be stored in
  output             wbuf_full,    // no free slot left

  // the scheduler chose a WR / RD in this cycle
  input              ev_wr,
  input      [3:0]   ev_wr_ptr,    // slot that holds the write data
  input              ev_rd,
  input      [3:0]   ev_rd_id,     // id to return together with the read data

  // data bus towards the DRAM (PHY side)
  output reg         dq_wvalid,    // write data is on the bus
  output reg [127:0] dq_wdata,
  input      [127:0] dq_rdata,

  // response channel to the host (reads only)
  output reg         rsp_valid,
  output reg [3:0]   rsp_id,
  output reg [127:0] rsp_rdata
);

  `include "dram_params.vh"   // timing numbers and command codes

  // Pipe lengths. The command appears on the bus one cycle after the
  // scheduler picks it (the command outputs are registered), which is why
  // these are "latency - 1 + burst length" and not simply the latency.
  localparam WR_LEN = CWL + BL2 - 1;   // 11 stages
  localparam RD_LEN = CL  + BL2;       // 15 stages

  //---------------------------------------------------------------------------
  // Write-data buffer
  //---------------------------------------------------------------------------
  reg [127:0] wbuf [0:15];   // the data (no reset needed, see below)
  reg [15:0]  used;          // 1 = slot holds data that is still needed

  // lowest free slot (same "find first" idea as in the selector)
  function [3:0] find_first;
    input [15:0] v;
    integer k;
    begin
      find_first = 4'd0;
      for (k = 15; k >= 0; k = k - 1)
        if (v[k]) find_first = k[3:0];
    end
  endfunction

  assign free_ptr  = find_first(~used);
  assign wbuf_full = &used;

  // The data flops have no reset on purpose: a slot is only ever read after
  // it was written, so its start value does not matter (saves area).
  always @(posedge clk) begin
    if (store) wbuf[free_ptr] <= store_data;
  end

  //---------------------------------------------------------------------------
  // The pipes
  //---------------------------------------------------------------------------
  reg [WR_LEN-1:0]      wr_vld;   // stage s = "a WR was chosen s+1 cycles ago"
  reg [WR_LEN*4-1:0]    wr_ptr;   // its buffer slot travels along (stage s = wr_ptr[s*4 +: 4])
  reg [RD_LEN-1:0]      rd_vld;
  reg [RD_LEN*4-1:0]    rd_id;    // its request id travels along (stage s = rd_id[s*4 +: 4])

  // The write burst starts when the flag reaches stage CWL-1 ...
  wire       wr_start     = wr_vld[CWL-1];
  wire [3:0] wr_start_ptr = wr_ptr[(CWL-1)*4 +: 4];
  // ... and lasts BL2 cycles (stages CWL-1 up to the last stage).
  wire       wr_on_bus    = |wr_vld[WR_LEN-1:CWL-1];

  // The read burst is complete when the flag reaches the last stage.
  wire       rd_done      = rd_vld[RD_LEN-1];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      used      <= 16'd0;
      wr_vld    <= 0;
      wr_ptr    <= 0;
      rd_vld    <= 0;
      rd_id     <= 0;
      dq_wvalid <= 1'b0;
      dq_wdata  <= 128'd0;
      rsp_valid <= 1'b0;
      rsp_id    <= 4'd0;
      rsp_rdata <= 128'd0;
    end else begin

      // ---- move both pipes one stage ------------------------------------
      wr_vld <= {wr_vld[WR_LEN-2:0], ev_wr};
      wr_ptr <= {wr_ptr[(WR_LEN-1)*4-1:0], ev_wr_ptr};
      rd_vld <= {rd_vld[RD_LEN-2:0], ev_rd};
      rd_id  <= {rd_id[(RD_LEN-1)*4-1:0],  ev_rd_id};

      // ---- write side: drive the data bus, then free the slot -----------
      dq_wvalid <= wr_on_bus;
      if (wr_start) begin
        dq_wdata           <= wbuf[wr_start_ptr];   // stays stable for the burst
        used[wr_start_ptr] <= 1'b0;                 // slot can be reused
      end

      // ---- a new write request takes the lowest free slot ---------------
      if (store) used[free_ptr] <= 1'b1;

      // ---- read side: capture the finished burst, answer the host -------
      rsp_valid <= rd_done;
      if (rd_done) begin
        rsp_id    <= rd_id[(RD_LEN-1)*4 +: 4];
        rsp_rdata <= dq_rdata;
      end
    end
  end

endmodule
