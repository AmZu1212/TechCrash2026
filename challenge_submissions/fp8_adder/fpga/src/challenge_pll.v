// ============================================================================
// FP8 Adder Challenge — Editable PLL
// ============================================================================
// Teams MAY modify this file.
//
// Output frequency = 50 MHz * CLK0_MULTIPLY_BY / CLK0_DIVIDE_BY
//
// Starting safe: 100 MHz (M=12, D=6, VCO=600 MHz — in-spec minimum VCO)
// Next step:     150 MHz (M=12, D=4, VCO=600 MHz)
// Next step:     200 MHz (M=12, D=3, VCO=600 MHz)
// Next step:     250 MHz (M=15, D=3, VCO=750 MHz)
// Max attempt:   300 MHz (M=12, D=2, VCO=600 MHz)
//
// Each step: recompile → verify TimeQuest closes → board test LEDR[0]=1.
// ============================================================================

module challenge_pll (
    input  wire inclk0,
    output wire c0,
    output wire locked
);

    localparam integer CLK0_MULTIPLY_BY = 12;
    localparam integer CLK0_DIVIDE_BY   = 12;   // 50 MHz — safe/confirmed timing closure

    wire [5:0] pll_clk_bus;
    wire [1:0] inclk_bus;

    assign inclk_bus = {1'b0, inclk0};
    assign c0 = pll_clk_bus[0];

    altpll altpll_component (
        .inclk          (inclk_bus),
        .clk            (pll_clk_bus),
        .locked         (locked),
        .activeclock    (),
        .areset         (1'b0),
        .clkena         (6'b111111),
        .clkbad         (),
        .clkloss        (),
        .clkswitch      (1'b0),
        .configupdate   (1'b0),
        .enable0        (),
        .enable1        (),
        .extclk         (),
        .extclkena      (4'b1111),
        .fbin           (1'b1),
        .fbmimicbidir   (),
        .fbout          (),
        .fref           (),
        .pfdena         (1'b1),
        .phasecounterselect (4'b1111),
        .phasedone      (),
        .phasestep      (1'b1),
        .phaseupdown    (1'b1),
        .pllena         (1'b1),
        .scanaclr       (1'b0),
        .scanclk        (1'b0),
        .scanclkena     (1'b1),
        .scandata       (1'b0),
        .scandataout    (),
        .scandone       (),
        .scanread       (1'b0),
        .scanwrite      (1'b0),
        .sclkout0       (),
        .sclkout1       (),
        .vcooverrange   (),
        .vcounderrange  ()
    );

    defparam
        altpll_component.bandwidth_type          = "AUTO",
        altpll_component.clk0_divide_by          = CLK0_DIVIDE_BY,
        altpll_component.clk0_duty_cycle         = 50,
        altpll_component.clk0_multiply_by        = CLK0_MULTIPLY_BY,
        altpll_component.clk0_phase_shift        = "0",
        altpll_component.compensate_clock        = "CLK0",
        altpll_component.inclk0_input_frequency  = 20000,
        altpll_component.intended_device_family  = "MAX 10",
        altpll_component.lpm_hint                = "CBX_MODULE_PREFIX=challenge_pll",
        altpll_component.lpm_type                = "altpll",
        altpll_component.operation_mode          = "NORMAL",
        altpll_component.pll_type                = "AUTO",
        altpll_component.port_activeclock        = "PORT_UNUSED",
        altpll_component.port_areset             = "PORT_UNUSED",
        altpll_component.port_clkbad0            = "PORT_UNUSED",
        altpll_component.port_clkbad1            = "PORT_UNUSED",
        altpll_component.port_clkloss            = "PORT_UNUSED",
        altpll_component.port_clkswitch          = "PORT_UNUSED",
        altpll_component.port_configupdate       = "PORT_UNUSED",
        altpll_component.port_fbin               = "PORT_UNUSED",
        altpll_component.port_inclk0             = "PORT_USED",
        altpll_component.port_inclk1             = "PORT_UNUSED",
        altpll_component.port_locked             = "PORT_USED",
        altpll_component.port_pfdena             = "PORT_UNUSED",
        altpll_component.port_phasecounterselect = "PORT_UNUSED",
        altpll_component.port_phasedone          = "PORT_UNUSED",
        altpll_component.port_phasestep          = "PORT_UNUSED",
        altpll_component.port_phaseupdown        = "PORT_UNUSED",
        altpll_component.port_pllena             = "PORT_UNUSED",
        altpll_component.port_scanaclr           = "PORT_UNUSED",
        altpll_component.port_scanclk            = "PORT_UNUSED",
        altpll_component.port_scanclkena         = "PORT_UNUSED",
        altpll_component.port_scandata           = "PORT_UNUSED",
        altpll_component.port_scandataout        = "PORT_UNUSED",
        altpll_component.port_scandone           = "PORT_UNUSED",
        altpll_component.port_scanread           = "PORT_UNUSED",
        altpll_component.port_scanwrite          = "PORT_UNUSED",
        altpll_component.port_clk0              = "PORT_USED",
        altpll_component.port_clk1              = "PORT_UNUSED",
        altpll_component.port_clk2              = "PORT_UNUSED",
        altpll_component.port_clk3              = "PORT_UNUSED",
        altpll_component.port_clk4              = "PORT_UNUSED",
        altpll_component.port_clk5              = "PORT_UNUSED",
        altpll_component.self_reset_on_loss_lock = "OFF",
        altpll_component.width_clock             = 6;

endmodule
