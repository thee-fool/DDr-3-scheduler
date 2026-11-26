//==============================================================================
// dram_params.vh  -  every number that describes the DRAM lives here
//------------------------------------------------------------------------------
// Device : DDR3-1600, 2 Gb x16, speed bin 11-11-11
//          8 banks x 16384 rows x 1024 columns x 16 bits
//
// This file is NOT a module. Every module that needs these numbers includes
// it INSIDE its body:
//
//     module foo (...);
//       `include "dram_params.vh"
//       ...
//
// so each module gets its own copy of the localparams (plain Verilog-2001 has
// no packages). For that reason there is deliberately NO include guard.
// The tools need the folder of this file on their include path
// (iverilog -I.., Incisive +incdir+.., Genus init_hdl_search_path).
//
// All timing values are in clock cycles. The scheduler issues at most one
// command per cycle, so "tRCD = 11" means: after an ACT, wait at least 11
// cycles before a RD or WR to the same bank.
//
// Fixed sizes used all over the design (written as plain numbers in the
// port lists so they are easy to read):
//   bank address   3 bits  (8 banks)
//   row  address  14 bits  (16384 rows)
//   column addr   10 bits  (1024 columns)
//   queue depth   16 entries, so a queue index is 4 bits
//   request id     4 bits
//   burst data   128 bits  (8 beats x 16 bits)
//==============================================================================

  //---------------------------------------------------------------------------
  // Timing rules that involve ONE bank
  //---------------------------------------------------------------------------
  localparam tRCD = 11;   // ACT -> RD/WR   (row must be sensed before we use it)
  localparam tRP  = 11;   // PRE -> ACT     (bitlines must be precharged)
  localparam tRAS = 28;   // ACT -> PRE     (row must stay open this long)
  localparam tRC  = 39;   // ACT -> ACT     (same bank; equals tRAS + tRP)
  localparam tRTP = 6;    // RD  -> PRE
  localparam tWR  = 12;   // end of write data -> PRE (write recovery)

  //---------------------------------------------------------------------------
  // Timing rules that involve ALL banks (shared command bus / data bus)
  //---------------------------------------------------------------------------
  localparam tRRD = 6;    // ACT -> ACT     (any two banks)
  localparam tFAW = 32;   // at most 4 ACTs inside any window of 32 cycles
  localparam tCCD = 4;    // RD/WR -> RD/WR (one burst must leave the data bus)
  localparam tWTR = 6;    // end of write data -> RD

  //---------------------------------------------------------------------------
  // Data bus latencies
  //---------------------------------------------------------------------------
  localparam CL   = 11;   // RD command -> first read  data beat
  localparam CWL  = 8;    // WR command -> first write data beat
  localparam BL2  = 4;    // a burst occupies the data bus for 4 cycles (BL/2)

  //---------------------------------------------------------------------------
  // Refresh
  //---------------------------------------------------------------------------
  localparam tRFC  = 128;   // REF -> next command
  localparam tREFI = 6240;  // one refresh is owed every 6240 cycles
  localparam MAX_POSTPONE = 8;  // when 8 refreshes are owed we must refresh now

  //---------------------------------------------------------------------------
  // Derived gaps (command to command), so nobody has to redo the sums
  //---------------------------------------------------------------------------
  localparam tWR2PRE = CWL + BL2 + tWR;      // 24 : WR -> PRE, same bank
  localparam tWR2RD  = CWL + BL2 + tWTR;     // 18 : WR -> RD,  any bank
  localparam tRD2WR  = CL + tCCD + 2 - CWL;  //  9 : RD -> WR,  any bank (JEDEC)

  //---------------------------------------------------------------------------
  // Command codes on the cmd[2:0] bus
  //---------------------------------------------------------------------------
  localparam [2:0] CMD_NOP = 3'd0;  // nothing this cycle
  localparam [2:0] CMD_ACT = 3'd1;  // open a row        (cmd_addr = row)
  localparam [2:0] CMD_RD  = 3'd2;  // read  a burst     (cmd_addr = column)
  localparam [2:0] CMD_WR  = 3'd3;  // write a burst     (cmd_addr = column)
  localparam [2:0] CMD_PRE = 3'd4;  // close a row       (cmd_addr[10]=1 : all banks)
  localparam [2:0] CMD_REF = 3'd5;  // refresh

  //---------------------------------------------------------------------------
  // Scheduling policies on sched_mode[1:0]
  //---------------------------------------------------------------------------
  localparam [1:0] MODE_FCFS    = 2'd0;  // strictly in arrival order
  localparam [1:0] MODE_FRFCFS  = 2'd1;  // row hits first, then oldest
  localparam [1:0] MODE_FRFCFSC = 2'd2;  // FR-FCFS with a starvation cap (2 or 3)

