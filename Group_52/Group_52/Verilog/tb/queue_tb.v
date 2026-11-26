//==============================================================================
// queue_tb.v  -  stand-alone test of txn_queue.v
//------------------------------------------------------------------------------
// The collapsing queue has one tricky case: adding a request and removing
// one in the SAME cycle. This test hammers the queue with random add/remove
// operations (often both at once) and checks it against a simple reference
// list kept here in the testbench.
//
// Run:  iverilog -g2001 -I.. -o queue_sim ../txn_queue.v queue_tb.v
//       vvp queue_sim
//==============================================================================
`timescale 1ns/1ps

module queue_tb;

  reg clk = 1'b0, rst_n = 1'b0;
  always #2.5 clk = ~clk;

  // queue inputs
  reg         push = 1'b0, retire = 1'b0;
  reg  [13:0] in_row;
  reg  [2:0]  in_bank;
  reg  [9:0]  in_col;
  reg         in_we;
  reg  [3:0]  in_id, in_wptr, sel_idx = 4'd0;

  // queue outputs
  wire [15:0]       q_valid;
  wire [16*3-1:0]   q_bank;     // entry k = q_bank[k*3 +: 3]
  wire [16*14-1:0]  q_row;      // entry k = q_row[k*14 +: 14]
  wire [15:0]       q_we;
  wire [13:0] sel_row;
  wire [2:0]  sel_bank;
  wire [9:0]  sel_col;
  wire        sel_we;
  wire [3:0]  sel_id, sel_wptr;
  wire        full, empty;

  txn_queue dut (
    .clk(clk), .rst_n(rst_n),
    .push(push), .in_row(in_row), .in_bank(in_bank), .in_col(in_col),
    .in_we(in_we), .in_id(in_id), .in_wptr(in_wptr),
    .retire(retire), .sel_idx(sel_idx),
    .q_valid(q_valid), .q_bank(q_bank), .q_row(q_row), .q_we(q_we),
    .sel_row(sel_row), .sel_bank(sel_bank), .sel_col(sel_col),
    .sel_we(sel_we), .sel_id(sel_id), .sel_wptr(sel_wptr),
    .full(full), .empty(empty)
  );

  // Reference list: entry 0 is the oldest. One 36-bit word per entry holds
  // {row, bank, col, we, id, wptr}.
  reg [35:0] ref_q [0:15];
  integer    ref_n = 0;

  integer errors = 0, n_push = 0, n_retire = 0, n_both = 0;
  integer t, k;

  // compare the whole queue with the reference list
  task check;
    begin
      if (full !== (ref_n == 16) || empty !== (ref_n == 0)) begin
        $display("ERROR t=%0t: full=%b empty=%b but the reference holds %0d", $time, full, empty, ref_n);
        errors = errors + 1;
      end
      for (k = 0; k < 16; k = k + 1) begin
        if (q_valid[k] !== (k < ref_n)) begin
          $display("ERROR t=%0t: q_valid[%0d]=%b, reference holds %0d entries", $time, k, q_valid[k], ref_n);
          errors = errors + 1;
        end
        if (k < ref_n) begin
          sel_idx = k;          // read entry k through the 16:1 output mux
          #0.1;
          if ({sel_row, sel_bank, sel_col, sel_we, sel_id, sel_wptr} !== ref_q[k]
              || q_row[k*14 +: 14] !== ref_q[k][35:22] || q_bank[k*3 +: 3] !== ref_q[k][21:19]
              || q_we[k] !== ref_q[k][8]) begin
            $display("ERROR t=%0t: entry %0d differs from the reference", $time, k);
            errors = errors + 1;
          end
        end
      end
    end
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    for (t = 0; t < 20000; t = t + 1) begin
      @(negedge clk);
      check;                                   // state after the last edge

      // Choose the next operation. The mix changes every 2000 cycles so the
      // queue is sometimes nearly empty and sometimes completely full.
      push    = (ref_n < 16) && (({$random} % 10) < (((t / 2000) % 2) ? 7 : 4));
      retire  = (ref_n > 0)  && (({$random} % 10) < 5);
      sel_idx = (ref_n > 0) ? ({$random} % ref_n) : 0;
      in_row  = $random;  in_bank = $random;  in_col  = $random;
      in_we   = $random;  in_id   = $random;  in_wptr = $random;

      // do the same thing to the reference list: remove first, then add
      if (retire) begin
        for (k = sel_idx; k < ref_n - 1; k = k + 1) ref_q[k] = ref_q[k+1];
        ref_n = ref_n - 1;
        n_retire = n_retire + 1;
      end
      if (push) begin
        ref_q[ref_n] = {in_row, in_bank, in_col, in_we, in_id, in_wptr};
        ref_n = ref_n + 1;
        n_push = n_push + 1;
      end
      if (push && retire) n_both = n_both + 1;
    end

    @(negedge clk);
    push = 1'b0;  retire = 1'b0;
    check;
    $display("queue_tb: %0d adds, %0d removes, %0d cycles with both at once, %0d errors",
             n_push, n_retire, n_both, errors);
    if (errors == 0) $display("QUEUE TEST PASSED");
    else             $display("QUEUE TEST FAILED");
    $finish;
  end

endmodule
