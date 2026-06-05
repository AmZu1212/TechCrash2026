# Timing Constraints -- DOOM Clone Controller
# DE10-Lite MAX 10 @ 50 MHz

create_clock -name CLK_50 -period 20.000 [get_ports MAX10_CLK1_50]

derive_pll_clocks
derive_clock_uncertainty

# Relax I/O timing -- SW and KEY are human-operated (no setup/hold requirement)
set_false_path -from [get_ports SW[*]]
set_false_path -from [get_ports KEY[*]]
set_false_path -to   [get_ports LEDR[*]]
set_false_path -to   [get_ports HEX0[*]]
set_false_path -to   [get_ports HEX1[*]]
set_false_path -to   [get_ports HEX2[*]]
set_false_path -to   [get_ports HEX3[*]]
set_false_path -to   [get_ports HEX4[*]]
set_false_path -to   [get_ports HEX5[*]]
set_false_path -to   [get_ports ARDUINO_IO[*]]
