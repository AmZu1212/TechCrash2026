// adc_pll.v
// Minimal ALTPLL for DE10-Lite MAX10 ADC clock requirement.
// Input: 50 MHz oscillator  (MAX10_CLK1_50)
// Output clk0: 50 MHz PLL-buffered  (feeds fiftyfivenm_adcblock clkin_from_pll_c0)
//
// The MAX10 ADC hard block requires its clock to come from a PLL C-counter
// output, not directly from a board oscillator pin.  This PLL satisfies that
// constraint with a 1:1 ratio (50 MHz in → 50 MHz out).

module adc_pll (
    input  wire inclk0,    // 50 MHz from MAX10_CLK1_50
    output wire clk0,      // 50 MHz to ADC block
    output wire locked     // PLL lock indicator
);

// Unused clock outputs from the 5-wide bus
wire [3:0] unused_clk;   // clk[4:1]

altpll #(
    // Reference and output frequency
    .inclk0_input_frequency (20000),   // Input period in ps (1/50 MHz = 20 000 ps)
    .clk0_divide_by         (1),
    .clk0_multiply_by       (1),
    .clk0_duty_cycle        (50),
    .clk0_phase_shift       ("0"),

    // Device family
    .intended_device_family ("MAX 10"),
    .pll_type               ("AUTO"),
    .lpm_type               ("altpll"),
    .operation_mode         ("NORMAL"),
    .compensate_clock       ("CLK0"),
    .bandwidth_type         ("AUTO"),

    // Ports used / unused
    .port_inclk0            ("PORT_USED"),
    .port_inclk1            ("PORT_UNUSED"),
    .port_clk0              ("PORT_USED"),
    .port_clk1              ("PORT_UNUSED"),
    .port_clk2              ("PORT_UNUSED"),
    .port_clk3              ("PORT_UNUSED"),
    .port_clk4              ("PORT_UNUSED"),
    .port_locked            ("PORT_USED"),
    .port_areset            ("PORT_UNUSED"),
    .port_pfdena            ("PORT_UNUSED"),
    .port_activeclock       ("PORT_UNUSED"),
    .port_clkbad0           ("PORT_UNUSED"),
    .port_clkbad1           ("PORT_UNUSED"),
    .port_clkloss           ("PORT_UNUSED"),
    .port_clkswitch         ("PORT_UNUSED"),
    .port_configupdate      ("PORT_UNUSED"),
    .port_fbin              ("PORT_UNUSED"),
    .port_phasecounterselect("PORT_UNUSED"),
    .port_phasedone         ("PORT_UNUSED"),
    .port_phasestep         ("PORT_UNUSED"),
    .port_phaseupdown       ("PORT_UNUSED"),
    .port_pllena            ("PORT_UNUSED"),
    .port_scanaclr          ("PORT_UNUSED"),
    .port_scanclk           ("PORT_UNUSED"),
    .port_scanclkena        ("PORT_UNUSED"),
    .port_scandata          ("PORT_UNUSED"),
    .port_scandataout       ("PORT_UNUSED"),
    .port_scandone          ("PORT_UNUSED"),
    .port_scanread          ("PORT_UNUSED"),
    .port_scanwrite         ("PORT_UNUSED"),

    .self_reset_on_loss_of_lock ("OFF"),
    .width_clock                (5)
) u_altpll (
    .inclk   ({1'b0, inclk0}),
    .clk     ({unused_clk, clk0}),
    .locked  (locked),

    // Tie off unused ports
    .areset        (1'b0),
    .pfdena        (1'b1),
    .clkswitch     (1'b0),
    .configupdate  (1'b0),
    .pllena        (1'b1),
    .scanaclr      (1'b0),
    .scanclk       (1'b0),
    .scanclkena    (1'b1),
    .scandata      (1'b0),
    .scanread      (1'b0),
    .scanwrite     (1'b0),
    .fbin          (1'b1),

    // Unused outputs (open)
    .activeclock   (),
    .clkbad        (),
    .clkloss       (),
    .enable0       (),
    .enable1       (),
    .fbout         (),
    .phasedone     (),
    .scandataout   (),
    .scandone      (),
    .sclkout0      (),
    .sclkout1      (),
    .vcooverrange  (),
    .vcounderrange ()
);

endmodule
