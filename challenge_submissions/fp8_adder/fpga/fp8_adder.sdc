create_clock -period 20.000 -name clk [get_ports {MAX10_CLK1_50}]
derive_pll_clocks
create_generated_clock -name meas_clk -source [get_ports {MAX10_CLK1_50}] -divide_by 2 [get_registers {meas_clk_div2}]
set_clock_groups -asynchronous -group [get_clocks {meas_clk}] -group [get_clocks {user_pll|altpll_component|auto_generated|pll1|clk[0]}]
derive_clock_uncertainty
