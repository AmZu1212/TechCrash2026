// LED Bar Graph Driver
// Maps a voltage (0.00 - 3.30V) to 10 LEDs on LEDR[9:0]
// Each LED represents ~0.33V (3.3V / 10 LEDs)

module led_bar_graph (
    input  logic [15:0] voltage_int,  // Voltage * 100 (e.g., 165 = 1.65V)
    output logic [9:0]  ledr
);

    // Thresholds for each LED (in units of voltage_int)
    // LED 0 = 33  (0.33V)
    // LED 1 = 66  (0.66V)
    // ... LED 9 = 330 (3.30V)

    always_comb begin
        ledr = 10'b0000000000;
        
        if (voltage_int >= 16'd33)   ledr[0] = 1'b1;
        if (voltage_int >= 16'd66)   ledr[1] = 1'b1;
        if (voltage_int >= 16'd99)   ledr[2] = 1'b1;
        if (voltage_int >= 16'd132)  ledr[3] = 1'b1;
        if (voltage_int >= 16'd165)  ledr[4] = 1'b1;
        if (voltage_int >= 16'd198)  ledr[5] = 1'b1;
        if (voltage_int >= 16'd231)  ledr[6] = 1'b1;
        if (voltage_int >= 16'd264)  ledr[7] = 1'b1;
        if (voltage_int >= 16'd297)  ledr[8] = 1'b1;
        if (voltage_int >= 16'd330)  ledr[9] = 1'b1;
    end
endmodule
