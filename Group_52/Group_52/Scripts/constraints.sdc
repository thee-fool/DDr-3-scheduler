#==============================================================================
# constraints.sdc  -  timing constraints for ddr3_scheduler
# NOT run in Cadence by the author of this file (no Cadence tools available).
# It only uses standard SDC commands, the same ones as the course ALU example.
#==============================================================================

# 200 MHz clock = 5.0 ns period. For the clock-period sweep change this one
# number (4.0 / 5.0 / 6.0) and re-run synthesis.
create_clock -name clk -period 5.0 [get_ports clk]

# All inputs arrive 0.5 ns after the clock edge, all outputs must be ready
# 0.5 ns before the next one. (The clock port itself is excluded.)
set_input_delay  0.5 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 0.5 -clock clk [all_outputs]

# The reset is asynchronous and held for several cycles, so it is not timed.
set_false_path -from [get_ports rst_n]
