//==============================================================================
// txn_queue.v  -  16-entry "collapsing" queue of waiting requests
//------------------------------------------------------------------------------
// Entry 0 is always the OLDEST request, entry 1 the next oldest, and so on.
// New requests are added behind the last valid entry.
//
// When the scheduler finishes entry k (its RD or WR was issued), entry k is
// removed and every entry above it moves down by one place. Because of this
// "collapse", the position of an entry IS its age. Finding the oldest request
// with some property is then just "find the lowest set bit" - no age
// counters and no age comparators are needed.
//
// One entry holds (37 bits):
//   valid(1) row(14) bank(3) col(10) we(1) id(4) wptr(4)
// wptr says where the write data of this request sits in the write buffer
// (see data_path.v). The data itself is NOT stored here, so nothing wide
// has to shift.
//
// Plain Verilog has no 2-D packed arrays, so every per-entry field is kept
// in ONE flat vector, entry i sitting in its own slice:
//   q_bank[i*3 +: 3]   q_row[i*14 +: 14]   q_col[i*10 +: 10]
//   q_id[i*4 +: 4]     q_wptr[i*4 +: 4]    (q_valid[i], q_we[i] are 1 bit)
//==============================================================================
module txn_queue (
  input                    clk,
  input                    rst_n,

  // add one request at the tail
  input                    push,
  input      [13:0]        in_row,
  input      [2:0]         in_bank,
  input      [9:0]         in_col,
  input                    in_we,
  input      [3:0]         in_id,
  input      [3:0]         in_wptr,

  // remove entry sel_idx (its RD / WR was issued in this cycle)
  input                    retire,
  input      [3:0]         sel_idx,

  // what the eligibility logic needs from EVERY entry
  output reg [15:0]        q_valid,
  output reg [16*3-1:0]    q_bank,     // entry i = q_bank[i*3 +: 3]
  output reg [16*14-1:0]   q_row,      // entry i = q_row[i*14 +: 14]
  output reg [15:0]        q_we,

  // all fields of the entry the selector is pointing at
  output     [13:0]        sel_row,
  output     [2:0]         sel_bank,
  output     [9:0]         sel_col,
  output                   sel_we,
  output     [3:0]         sel_id,
  output     [3:0]         sel_wptr,

  output                   full,
  output                   empty
);

  reg [16*10-1:0] q_col;      // entry i = q_col[i*10 +: 10]
  reg [16*4-1:0]  q_id;       // entry i = q_id[i*4 +: 4]
  reg [16*4-1:0]  q_wptr;     // entry i = q_wptr[i*4 +: 4]
  reg [4:0]       count;      // number of valid entries, 0..16

  // Where does a new request go? Behind the last valid entry. If one entry
  // is removed in the same cycle, everything moves down, so the new request
  // lands one place lower.
  wire [4:0] tail5 = retire ? (count - 5'd1) : count;
  wire [3:0] tail  = tail5[3:0];

  integer i;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q_valid <= 0;
      q_bank  <= 0;
      q_row   <= 0;
      q_col   <= 0;
      q_we    <= 0;
      q_id    <= 0;
      q_wptr  <= 0;
      count   <= 0;
    end else begin

      // ---- step 1: remove entry sel_idx, move the younger ones down -----
      if (retire) begin
        for (i = 0; i < 15; i = i + 1) begin
          if (i >= sel_idx) begin           // copy from the place above
            q_valid[i]          <= q_valid[i+1];
            q_bank[i*3 +: 3]    <= q_bank[(i+1)*3 +: 3];
            q_row[i*14 +: 14]   <= q_row[(i+1)*14 +: 14];
            q_col[i*10 +: 10]   <= q_col[(i+1)*10 +: 10];
            q_we[i]             <= q_we[i+1];
            q_id[i*4 +: 4]      <= q_id[(i+1)*4 +: 4];
            q_wptr[i*4 +: 4]    <= q_wptr[(i+1)*4 +: 4];
          end
        end
        // the top place (15) always becomes empty: sel_idx <= 15 always
        q_valid[15]          <= 1'b0;
        q_bank[15*3 +: 3]    <= 3'd0;
        q_row[15*14 +: 14]   <= 14'd0;
        q_col[15*10 +: 10]   <= 10'd0;
        q_we[15]             <= 1'b0;
        q_id[15*4 +: 4]      <= 4'd0;
        q_wptr[15*4 +: 4]    <= 4'd0;
      end

      // ---- step 2: add the new request at the tail -----------------------
      // (written after step 1 on purpose: if both touch the same place,
      //  the later assignment wins, which is exactly what we want)
      if (push) begin
        q_valid[tail]          <= 1'b1;
        q_bank[tail*3 +: 3]    <= in_bank;
        q_row[tail*14 +: 14]   <= in_row;
        q_col[tail*10 +: 10]   <= in_col;
        q_we[tail]             <= in_we;
        q_id[tail*4 +: 4]      <= in_id;
        q_wptr[tail*4 +: 4]    <= in_wptr;
      end

      // ---- step 3: keep the count up to date -----------------------------
      if (push && !retire) count <= count + 5'd1;
      if (retire && !push) count <= count - 5'd1;
    end
  end

  // 16-to-1 multiplexers: read out the entry the selector points at
  assign sel_row  = q_row[sel_idx*14 +: 14];
  assign sel_bank = q_bank[sel_idx*3 +: 3];
  assign sel_col  = q_col[sel_idx*10 +: 10];
  assign sel_we   = q_we[sel_idx];
  assign sel_id   = q_id[sel_idx*4 +: 4];
  assign sel_wptr = q_wptr[sel_idx*4 +: 4];

  assign full  = (count == 5'd16);
  assign empty = (count == 5'd0);

endmodule
