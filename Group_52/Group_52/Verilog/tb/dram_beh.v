//==============================================================================
// dram_beh.v  -  behavioural model of the DRAM (testbench only, not synthesised)
//------------------------------------------------------------------------------
// This stands in for the real memory chip + PHY. It
//   - follows the command bus (which row is open in which bank),
//   - stores write data and returns read data at the correct cycles,
//   - complains if the scheduler does something a real DRAM would not accept.
//
// Timing, with B = the cycle in which a command is visible on the bus:
//   WR : dq_wvalid must be 1 exactly in cycles B+CWL ... B+CWL+BL2-1
//        (the data is stored in the last of these cycles)
//   RD : read data comes back in cycles B+CL ... B+CL+BL2-1, 32 bits more
//        in every cycle, so the 128-bit word is complete only in the last one.
//        A scheduler that samples too early or too late gets wrong data.
//
// Memory: 2 Gb is far too big for a simulator array, so only the locations
// that were written are kept in a small list. A location that was never
// written reads back a fixed pattern made from its own address.
//==============================================================================
module dram_beh (
  input              clk,
  input              rst_n,
  input      [2:0]   cmd,
  input      [2:0]   cmd_bank,
  input      [13:0]  cmd_addr,
  input              dq_wvalid,
  input      [127:0] dq_wdata,
  output reg [127:0] dq_rdata
);

  `include "dram_params.vh"   // timing numbers and command codes

  integer errors = 0;     // the testbench reads this at the end

  //---------------------------------------------------------------------------
  // The memory: a list of (location, data) pairs
  //---------------------------------------------------------------------------
  localparam MEM_MAX = 20000;            // enough for any test here
  reg [26:0]  mem_key [0:MEM_MAX-1];     // location = {row, bank, column}
  reg [127:0] mem_dat [0:MEM_MAX-1];
  integer     mem_n = 0;                 // number of locations in use

  // value of a location nobody has written yet (same pattern as the Python model)
  function [127:0] default_data;
    input [26:0] key;
    begin
      default_data = {4{5'b10101, key}};
    end
  endfunction

  function [127:0] mem_read;
    input [26:0] key;
    integer k;
    begin
      mem_read = default_data(key);
      for (k = 0; k < mem_n; k = k + 1)
        if (mem_key[k] == key) mem_read = mem_dat[k];
    end
  endfunction

  task mem_write;
    input [26:0]  key;
    input [127:0] data;
    integer k;
    integer found;
    begin
      found = 0;
      for (k = 0; k < mem_n; k = k + 1)
        if (mem_key[k] == key) begin
          mem_dat[k] = data;              // overwrite an existing location
          found = 1;
        end
      if (!found) begin                   // or add a new one
        if (mem_n == MEM_MAX) begin
          $display("DRAM MODEL: memory list is full, increase MEM_MAX");
          errors = errors + 1;
        end else begin
          mem_key[mem_n] = key;
          mem_dat[mem_n] = data;
          mem_n = mem_n + 1;
        end
      end
    end
  endtask

  //---------------------------------------------------------------------------
  // Open rows, and the two pipes that carry a RD / WR to its data cycles
  //---------------------------------------------------------------------------
  reg [7:0]   is_open;
  reg [13:0]  open_row [0:7];

  localparam WR_LEN = CWL + BL2 - 1;       // 11
  localparam RD_LEN = CL  + BL2 - 1;       // 14
  reg         wr_v   [0:WR_LEN-1];         // stage k = WR seen k+1 cycles ago
  reg [26:0]  wr_key [0:WR_LEN-1];
  reg         rd_v   [0:RD_LEN-1];
  reg [127:0] rd_dat [0:RD_LEN-1];

  reg [26:0]  key;
  reg         wr_expected;
  integer     k;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      is_open <= 8'd0;
      for (k = 0; k < WR_LEN; k = k + 1) wr_v[k] <= 1'b0;
      for (k = 0; k < RD_LEN; k = k + 1) rd_v[k] <= 1'b0;
    end else begin

      // ---- write data: must be on the bus exactly in the write window ----
      wr_expected = 1'b0;
      for (k = CWL - 1; k < WR_LEN; k = k + 1)
        if (wr_v[k]) wr_expected = 1'b1;
      if (dq_wvalid !== wr_expected) begin
        $display("DRAM MODEL ERROR t=%0t: dq_wvalid=%b but the model expects %b",
                 $time, dq_wvalid, wr_expected);
        errors = errors + 1;
      end
      if (wr_v[WR_LEN-1])                       // last beat: store the word
        mem_write(wr_key[WR_LEN-1], dq_wdata);

      // ---- move the pipes -------------------------------------------------
      for (k = WR_LEN - 1; k > 0; k = k - 1) begin
        wr_v[k]   <= wr_v[k-1];
        wr_key[k] <= wr_key[k-1];
      end
      for (k = RD_LEN - 1; k > 0; k = k - 1) begin
        rd_v[k]   <= rd_v[k-1];
        rd_dat[k] <= rd_dat[k-1];
      end
      wr_v[0] <= 1'b0;
      rd_v[0] <= 1'b0;

      // ---- follow the command bus ----------------------------------------
      key = {open_row[cmd_bank], cmd_bank, cmd_addr[9:0]};
      case (cmd)
        CMD_ACT: begin
          is_open[cmd_bank]  <= 1'b1;
          open_row[cmd_bank] <= cmd_addr;
        end
        CMD_PRE: begin
          if (cmd_addr[10]) is_open           <= 8'd0;    // all banks
          else              is_open[cmd_bank] <= 1'b0;
        end
        CMD_RD, CMD_WR: begin
          if (!is_open[cmd_bank]) begin
            $display("DRAM MODEL ERROR t=%0t: RD/WR to bank %0d, but no row is open",
                     $time, cmd_bank);
            errors = errors + 1;
          end
          if (cmd == CMD_RD) begin
            rd_v[0]   <= 1'b1;
            rd_dat[0] <= mem_read(key);
          end else begin
            wr_v[0]   <= 1'b1;
            wr_key[0] <= key;
          end
        end
        default: ;                                         // NOP, REF: nothing to store
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // Drive the read data. Changed on the FALLING clock edge so the value is
  // stable around the rising edge where the scheduler samples it.
  // In beat n (1..4) of the burst the lowest 32*n bits have arrived.
  //---------------------------------------------------------------------------
  integer j;
  always @(negedge clk) begin
    dq_rdata <= 128'd0;                                    // bus idle
    for (j = CL - 1; j < RD_LEN; j = j + 1)
      if (rd_v[j])
        dq_rdata <= rd_dat[j] & ({128{1'b1}} >> (128 - 32 * (j - CL + 2)));
  end

endmodule
