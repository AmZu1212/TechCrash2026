// ============================================================================
// FP8 Adder Challenge — Top Level
// ============================================================================
// DO NOT MODIFY THIS FILE — teams may only modify fp8_adder.v and
// challenge_pll.v
//
// Controls:
//   KEY[0] = Start test (active low, directly used — no debounce needed)
//   KEY[1] = Reset (active low)
//
// Display:
//   Running: HEX5-4 = "EE", LEDs[9:1] = progress bar
//   Finished:
//     HEX5-HEX0 = elapsed time in microseconds (6-digit decimal)
//     LEDR[0] = 1 when all tests passed, 0 otherwise
//
// Clocking:
//   - MAX10_CLK1_50 is divided by 2 here to create a fixed 25 MHz measurement
//     clock used only for wall-time measurement and final display.
//   - challenge_pll.v generates the editable DUT/test clock. Teams may tune
//     that PLL and the adder micro-architecture, but may not touch the fixed
//     measurement clock path.
// ============================================================================

module fp8_top (
    input  wire        MAX10_CLK1_50,
    input  wire [1:0]  KEY,
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR,
    output wire [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5
);

    // ─── Clock and Reset ───
    wire meas_rst_n = KEY[1];
    reg  meas_clk_div2;
    wire meas_clk = meas_clk_div2;

    wire dut_clk;
    wire pll_locked;
    wire dut_rst_n = KEY[1] & pll_locked;

    always @(posedge MAX10_CLK1_50 or negedge meas_rst_n) begin
        if (!meas_rst_n)
            meas_clk_div2 <= 1'b0;
        else
            meas_clk_div2 <= ~meas_clk_div2;
    end

    challenge_pll user_pll (
        .inclk0 (MAX10_CLK1_50),
        .c0     (dut_clk),
        .locked (pll_locked)
    );

    // ─── Start edge detection ───
    reg key0_r, key0_rr;
    wire start_pulse;
    always @(posedge dut_clk or negedge dut_rst_n) begin
        if (!dut_rst_n) begin
            key0_r  <= 1'b1;
            key0_rr <= 1'b1;
        end else begin
            key0_r  <= KEY[0];
            key0_rr <= key0_r;
        end
    end
    assign start_pulse = key0_rr & ~key0_r;  // Falling edge of KEY[0]

    // ─── Memory (ROM) instances ───
    wire [11:0] mem_addr;
    wire [7:0]  mem_a_data, mem_b_data, mem_exp_data;

    rom_8x4096 #(.INIT_FILE("mem/mem_a.hex")) rom_a (
        .clock   (dut_clk),
        .address (mem_addr),
        .q       (mem_a_data)
    );

    rom_8x4096 #(.INIT_FILE("mem/mem_b.hex")) rom_b (
        .clock   (dut_clk),
        .address (mem_addr),
        .q       (mem_b_data)
    );

    rom_8x4096 #(.INIT_FILE("mem/mem_expected.hex")) rom_exp (
        .clock   (dut_clk),
        .address (mem_addr),
        .q       (mem_exp_data)
    );

    // ─── FP8 Adder (THE DUT — this is what teams optimize) ───
    wire [7:0] adder_a, adder_b, adder_result;
    wire       adder_start, adder_done, adder_busy;

    fp8_adder dut (
        .clk    (dut_clk),
        .rst_n  (dut_rst_n),
        .start  (adder_start),
        .a      (adder_a),
        .b      (adder_b),
        .result (adder_result),
        .done   (adder_done),
        .busy   (adder_busy)
    );

    // ─── Test Controller ───
    wire [31:0] cycle_count;
    wire [11:0] pass_count, fail_count, test_index;
    wire        running, finished;

    test_controller tc (
        .clk          (dut_clk),
        .rst_n        (dut_rst_n),
        .start        (start_pulse),
        .mem_addr     (mem_addr),
        .mem_a_data   (mem_a_data),
        .mem_b_data   (mem_b_data),
        .mem_exp_data (mem_exp_data),
        .adder_a      (adder_a),
        .adder_b      (adder_b),
        .adder_start  (adder_start),
        .adder_result (adder_result),
        .adder_done   (adder_done),
        .adder_busy   (adder_busy),
        .cycle_count  (cycle_count),
        .pass_count   (pass_count),
        .fail_count   (fail_count),
        .test_index   (test_index),
        .running      (running),
        .finished     (finished)
    );

    // Synchronize run state into the fixed measurement domain.
    reg running_meta;
    reg running_sync;
    reg finished_meta;
    reg finished_sync;

    always @(posedge meas_clk or negedge meas_rst_n) begin
        if (!meas_rst_n) begin
            running_meta  <= 1'b0;
            running_sync  <= 1'b0;
            finished_meta <= 1'b0;
            finished_sync <= 1'b0;
        end else begin
            running_meta  <= running;
            running_sync  <= running_meta;
            finished_meta <= finished;
            finished_sync <= finished_meta;
        end
    end

    // ─── Fixed-time measurement at 25 MHz ───
    // 25 cycles = 1 microsecond. This clock path is locked and separate from
    // the editable PLL-driven DUT clock.
    reg [4:0] us_prescaler;
    reg [3:0] us_d5, us_d4, us_d3, us_d2, us_d1, us_d0;

    always @(posedge meas_clk or negedge meas_rst_n) begin
        if (!meas_rst_n) begin
            us_prescaler <= 5'd0;
            us_d5 <= 4'd0;
            us_d4 <= 4'd0;
            us_d3 <= 4'd0;
            us_d2 <= 4'd0;
            us_d1 <= 4'd0;
            us_d0 <= 4'd0;
        end else if (!running_sync && !finished_sync) begin
            us_prescaler <= 5'd0;
            us_d5 <= 4'd0;
            us_d4 <= 4'd0;
            us_d3 <= 4'd0;
            us_d2 <= 4'd0;
            us_d1 <= 4'd0;
            us_d0 <= 4'd0;
        end else if (running_sync) begin
            if (us_prescaler == 5'd24) begin
                us_prescaler <= 5'd0;
                if (us_d0 == 4'd9) begin
                    us_d0 <= 4'd0;
                    if (us_d1 == 4'd9) begin
                        us_d1 <= 4'd0;
                        if (us_d2 == 4'd9) begin
                            us_d2 <= 4'd0;
                            if (us_d3 == 4'd9) begin
                                us_d3 <= 4'd0;
                                if (us_d4 == 4'd9) begin
                                    us_d4 <= 4'd0;
                                    if (us_d5 == 4'd9)
                                        us_d5 <= 4'd0;
                                    else
                                        us_d5 <= us_d5 + 4'd1;
                                end else begin
                                    us_d4 <= us_d4 + 4'd1;
                                end
                            end else begin
                                us_d3 <= us_d3 + 4'd1;
                            end
                        end else begin
                            us_d2 <= us_d2 + 4'd1;
                        end
                    end else begin
                        us_d1 <= us_d1 + 4'd1;
                    end
                end else begin
                    us_d0 <= us_d0 + 4'd1;
                end
            end else begin
                us_prescaler <= us_prescaler + 5'd1;
            end
        end
    end

    // ─── Display Logic ───
    // When running: show progress on LEDs (test_index / 4096 mapped to 10 LEDs)
    // When finished: show elapsed time and pass/fail

    wire [3:0] hex5_val, hex4_val, hex3_val, hex2_val, hex1_val, hex0_val;

    assign hex5_val = finished_sync ? us_d5 : (running_sync ? 4'hE : 4'h0);
    assign hex4_val = finished_sync ? us_d4 : (running_sync ? 4'hE : 4'h0);
    assign hex3_val = finished_sync ? us_d3 : 4'h0;
    assign hex2_val = finished_sync ? us_d2 : 4'h0;
    assign hex1_val = finished_sync ? us_d1 : 4'h0;
    assign hex0_val = finished_sync ? us_d0 : 4'h0;

    seg7_hex s5 (.hex(hex5_val), .seg(HEX5));
    seg7_hex s4 (.hex(hex4_val), .seg(HEX4));
    seg7_hex s3 (.hex(hex3_val), .seg(HEX3));
    seg7_hex s2 (.hex(hex2_val), .seg(HEX2));
    seg7_hex s1 (.hex(hex1_val), .seg(HEX1));
    seg7_hex s0 (.hex(hex0_val), .seg(HEX0));

    // ─── LEDs ───
    // Running: progress bar on LEDR[9:1], LEDR[0] kept low
    // Finished: LEDR[0] = pass/fail bit
    reg [9:0] led_out;
    always @(*) begin
        if (running) begin
            // Progress bar: light LEDs as tests complete
            case (test_index[11:9])
                3'd0: led_out = 10'b0000000010;
                3'd1: led_out = 10'b0000000110;
                3'd2: led_out = 10'b0000001110;
                3'd3: led_out = 10'b0000011110;
                3'd4: led_out = 10'b0000111110;
                3'd5: led_out = 10'b0001111110;
                3'd6: led_out = 10'b0011111110;
                3'd7: led_out = 10'b0111111110;
                default: led_out = 10'b1111111110;
            endcase
        end else if (finished_sync) begin
            led_out = {9'd0, fail_count == 12'd0};
        end else begin
            led_out = 10'd0;
        end
    end
    assign LEDR = led_out;

endmodule
