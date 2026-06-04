// Challenge 5: FPGA Volt-Meter -- DE10-Lite
//
// Uses MAX10 internal ADC (Channel 1 = Arduino A0) to read 0-3.3V.
// Displays voltage on 7-segment displays as X.XX with decimal point.
// Drives LED bar graph on LEDR[9:0] (0.30V per LED).
// Sends 5-byte UART frame to ESP32 every 100ms.
//
// Frame format (9600 8N1, ARDUINO_IO[1] = TX to ESP32 GPIO17):
//   Byte 0: Ones digit (BCD 0-3)
//   Byte 1: Tenths digit (BCD 0-9)
//   Byte 2: Hundredths digit (BCD 0-9)
//   Byte 3: LED bar bits [7:0]
//   Byte 4: LED bar bits [9:8]
//
// Display mapping:
//   HEX5/HEX4: off
//   HEX3: blank
//   HEX2: ones digit + decimal point lit
//   HEX1: tenths digit
//   HEX0: hundredths digit
//
// Reset: SW[9] (active-low)

module digital_voltmeter_top (
    input           MAX10_CLK1_50,
    input   [9:0]   SW,
    input   [1:0]   KEY,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout   [15:0]  ARDUINO_IO,
    inout           ARDUINO_RESET_N
);

    wire rst_n = SW[9];

    // ---- PLL: provides MAX10-ADC-compatible clock from board oscillator ----
    // The MAX10 ADC hard block requires its clock input to come from a PLL
    // C-counter output (routing constraint). This PLL passes 50 MHz → 50 MHz.
    wire clk;          // System clock (PLL-buffered 50 MHz)
    wire pll_locked;   // PLL lock (unused in logic, satisfies tool check)

    adc_pll u_pll (
        .inclk0 (MAX10_CLK1_50),
        .clk0   (clk),
        .locked (pll_locked)
    );

    // ---- Arduino I/O ----
    wire uart_tx_sig;
    assign ARDUINO_IO[1]    = uart_tx_sig;  // UART TX to ESP32 RX (GPIO17)
    assign ARDUINO_IO[0]    = 1'bz;         // Unused (ESP32 TX not connected)
    assign ARDUINO_IO[15:2] = 14'bz;

    // ---- Unused displays ----
    assign HEX4 = 8'b11111111;
    assign HEX5 = 8'b11111111;

    // ====================================================================
    // MAX10 Internal ADC  (free-running / continuous mode)
    //   Channel 1  = Arduino header A0
    //   clkdiv = 2 → ADC clock = 50 MHz / 10 = 5 MHz
    //   analog_input_pin_mask = 63 → CH1-CH6 enabled (bits 0-5)
    //   refsel = 0  → external VREF (tied to 3.3V on DE10-Lite)
    //   hard_pwd = 0 → ADC powered on during synthesis/implementation
    //
    //   SOC is held permanently HIGH so the ADC free-runs back-to-back
    //   conversions.  This is the simplest and most reliable approach —
    //   pulsing SOC risks the ADC not seeing it if the pulse falls on an
    //   unlucky ADC-clock edge (SOC is asynchronous to the ADC core clock).
    // ====================================================================
    wire        adc_eoc_raw;
    wire [11:0] adc_dout_raw;
    wire        adc_clkout;   // 5 MHz from ADC (unused as a logic clock)

    fiftyfivenm_adcblock_top_wrapper #(
        .clkdiv                          (2),
        .device_partname_fivechar_prefix ("10M50"),
        .is_this_first_or_second_adc     (1),
        .analog_input_pin_mask           (17'd63),
        .hard_pwd                        (0),
        .refsel                          (0)
    ) u_adc (
        .chsel             (5'd1),        // CH1 = Arduino A0
        .soc               (1'b1),        // Always high: ADC free-runs
        .eoc               (adc_eoc_raw),
        .dout              (adc_dout_raw),
        .usr_pwd           (1'b0),
        .tsen              (1'b0),
        .clkout_adccore    (adc_clkout),
        .clkin_from_pll_c0 (clk)          // PLL C-counter output (50 MHz)
    );

    // ---- Triple-flop synchronizer: EOC (5 MHz ADC domain) → 50 MHz system clock ----
    reg eoc_s1, eoc_s2, eoc_s3;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) {eoc_s3, eoc_s2, eoc_s1} <= 3'b0;
        else begin
            eoc_s1 <= adc_eoc_raw;
            eoc_s2 <= eoc_s1;
            eoc_s3 <= eoc_s2;
        end
    end
    wire eoc_rise = eoc_s2 & ~eoc_s3;  // Rising edge in system clock domain

    // ---- Latch ADC result on every EOC rising edge ----
    reg [11:0] adc_raw;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        adc_raw <= 12'd0;
        else if (eoc_rise) adc_raw <= adc_dout_raw;
    end

    // ====================================================================
    // Voltage Computation
    //   VCCADC on DE10-Lite = 5.00 V (full-scale reference for MAX10 ADC)
    //   voltage_cV = (adc_raw * 500) >> 12   (centvolts, 0.01 V units)
    //   Approximates: adc_raw / 4096 * 5.00 V * 100
    //   Range: 0 – 500  (5.00 V at full scale)
    //   Arduino A0 is limited to 3.3 V, so displayed max ≈ 3.30 V
    // ====================================================================
    wire [23:0] v_prod_cV   = {12'd0, adc_raw} * 24'd500;
    wire [11:0] v_cV        = v_prod_cV[23:12];   // >> 12

    // BCD digit extraction
    wire [3:0] v_ones       = 4'(v_cV / 12'd100);
    wire [3:0] v_tenths     = 4'((v_cV % 12'd100) / 12'd10);
    wire [3:0] v_hundredths = 4'(v_cV % 12'd10);

    // ---- LED Bar Graph  (0.30 V / LED, same as Challenge 1 ESP32) ----
    // LED[i] = 1 when voltage >= (i+1) * 30 cV = (i+1) * 0.30 V
    wire [9:0] led_bar;
    genvar gi;
    generate
        for (gi = 0; gi < 10; gi = gi + 1) begin : led_gen
            assign led_bar[gi] = (v_cV >= (gi + 1) * 12'd30);
        end
    endgenerate
    assign LEDR = led_bar;

    // ====================================================================
    // 7-Segment Displays
    //   HEX3 = blank
    //   HEX2 = ones digit  (decimal point bit7 active-low = ON)
    //   HEX1 = tenths digit
    //   HEX0 = hundredths digit
    // ====================================================================
    wire [7:0] seg_ones_raw;
    seven_segment seg2 (.data(v_ones),       .blank(1'b0), .seg(seg_ones_raw));
    seven_segment seg1 (.data(v_tenths),     .blank(1'b0), .seg(HEX1));
    seven_segment seg0 (.data(v_hundredths), .blank(1'b0), .seg(HEX0));

    assign HEX2 = seg_ones_raw & 8'b01111111;  // Decimal point ON (bit 7 = 0)
    assign HEX3 = 8'b11111111;                  // Blank

    // ====================================================================
    // UART TX  – 5-byte frame every 100 ms
    // ====================================================================
    wire uart_tx_busy;
    reg  [7:0] uart_tx_data;
    reg        uart_tx_start;

    uart_tx #(
        .CLK_FREQ(50_000_000),
        .BAUD(9600)
    ) u_uart_tx (
        .clk     (clk),
        .rst_n   (rst_n),
        .tx_data (uart_tx_data),
        .tx_start(uart_tx_start),
        .tx      (uart_tx_sig),
        .tx_busy (uart_tx_busy)
    );

    // TX frame state machine
    //   TX_IDLE      : wait 100 ms timer
    //   TX_LATCH     : snapshot voltage digits and LED bar
    //   TX_BYTE_LOAD : put correct byte into uart_tx_data, assert tx_start
    //   TX_BYTE_GAP  : 1-cycle wait for tx_busy to assert
    //   TX_BYTE_WAIT : wait for tx_busy to deassert (byte sent)
    localparam TX_IDLE      = 3'd0,
               TX_LATCH     = 3'd1,
               TX_BYTE_LOAD = 3'd2,
               TX_BYTE_GAP  = 3'd3,
               TX_BYTE_WAIT = 3'd4;

    reg [22:0] tx_timer;
    reg [2:0]  tx_fsm;
    reg [2:0]  tx_byte_idx;
    reg [3:0]  lat_ones, lat_tenths, lat_hundredths;
    reg [9:0]  lat_led;

    localparam TX_PERIOD = 23'd5_000_000;   // 100 ms at 50 MHz

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_timer    <= 23'd0;
            tx_fsm      <= TX_IDLE;
            tx_byte_idx <= 3'd0;
            uart_tx_start <= 1'b0;
            uart_tx_data  <= 8'd0;
            lat_ones       <= 4'd0;
            lat_tenths     <= 4'd0;
            lat_hundredths <= 4'd0;
            lat_led        <= 10'd0;
        end else begin
            uart_tx_start <= 1'b0;   // Default deasserted

            case (tx_fsm)
                TX_IDLE: begin
                    if (tx_timer == TX_PERIOD - 1) begin
                        tx_timer <= 23'd0;
                        tx_fsm   <= TX_LATCH;
                    end else begin
                        tx_timer <= tx_timer + 1;
                    end
                end

                TX_LATCH: begin
                    lat_ones       <= v_ones;
                    lat_tenths     <= v_tenths;
                    lat_hundredths <= v_hundredths;
                    lat_led        <= led_bar;
                    tx_byte_idx    <= 3'd0;
                    tx_fsm         <= TX_BYTE_LOAD;
                end

                TX_BYTE_LOAD: begin
                    // 5-byte ASCII frame: "X.XX\n"
                    //   Byte 0: ones digit   ('0'-'3', 0x30+ones)
                    //   Byte 1: '.'          (0x2E)
                    //   Byte 2: tenths digit ('0'-'9', 0x30+tenths)
                    //   Byte 3: hundredths   ('0'-'9', 0x30+hundredths)
                    //   Byte 4: '\n'         (0x0A) -- frame delimiter
                    // ASCII digits (0x30-0x39) and '.' (0x2E) never equal
                    // '\n' (0x0A), so the ESP32 can re-sync by line.
                    case (tx_byte_idx)
                        3'd0: uart_tx_data <= {4'h3, lat_ones};       // '0'-'3'
                        3'd1: uart_tx_data <= 8'h2E;                  // '.'
                        3'd2: uart_tx_data <= {4'h3, lat_tenths};     // '0'-'9'
                        3'd3: uart_tx_data <= {4'h3, lat_hundredths}; // '0'-'9'
                        3'd4: uart_tx_data <= 8'h0A;                  // '\n'
                        default: uart_tx_data <= 8'h0A;
                    endcase
                    uart_tx_start <= 1'b1;
                    tx_fsm        <= TX_BYTE_GAP;
                end

                TX_BYTE_GAP: begin
                    // 1-cycle delay: uart_tx_busy has not asserted yet
                    tx_fsm <= TX_BYTE_WAIT;
                end

                TX_BYTE_WAIT: begin
                    if (!uart_tx_busy) begin
                        // Byte transmission complete
                        if (tx_byte_idx == 3'd4) begin
                            tx_fsm <= TX_IDLE;   // Full 5-byte ASCII frame sent
                        end else begin
                            tx_byte_idx <= tx_byte_idx + 1;
                            tx_fsm      <= TX_BYTE_LOAD;
                        end
                    end
                end

                default: tx_fsm <= TX_IDLE;
            endcase
        end
    end

endmodule
