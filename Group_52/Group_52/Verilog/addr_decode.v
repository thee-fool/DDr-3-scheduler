//==============================================================================
// addr_decode.v  -  split a 28-bit byte address into row / bank / column
//------------------------------------------------------------------------------
// Pure combinational logic, no flip-flops.
//
// One request = one burst = 16 bytes, so the lowest 4 address bits only say
// "which byte inside the burst" and are ignored. That also means the lowest
// 3 column bits are always 0 (a burst covers 8 columns).
//
//   addr_map_sel = 0   "row : bank : column"   (keeps neighbours in ONE row)
//      [27:14] row     [13:11] bank    [10:4] column[9:3]    [3:0] ignored
//
//   addr_map_sel = 1   "row : column : bank"   (spreads neighbours over banks)
//      [27:14] row     [13:7] column[9:3]   [6:4] bank       [3:0] ignored
//
// With map 0 a sequential stream stays in one row for 128 bursts (many row
// hits). With map 1 every next burst goes to the next bank (bank parallelism).
//==============================================================================
module addr_decode (
  input         addr_map_sel,   // 0 = row:bank:col, 1 = row:col:bank
  input  [27:0] addr,           // byte address from the host
  output [13:0] row,
  output [2:0]  bank,
  output [9:0]  col
);

  // The row is in the same place for both mappings.
  assign row  = addr[27:14];

  // Bank and column swap places depending on the mapping.
  assign bank = addr_map_sel ? addr[6:4]            : addr[13:11];
  assign col  = addr_map_sel ? {addr[13:7], 3'b000} : {addr[10:4], 3'b000};

endmodule
