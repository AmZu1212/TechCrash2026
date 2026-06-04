// Challenge 6: Frequency Detector -- FPGA top
//
// Receives 256 signed 8-bit samples at 115200 baud from ESP32 (ARDUINO_IO[0]).
// Detects signal frequency using zero-crossing counting.
//
//   freq_hz = zero_crossings * 15.625
//           = zero_crossings * 125 / 8
//           (derived from: zc * sample_rate / (2 * window)
//                        = zc * 8000 / 512)
//
// Normal mode (SW[9]=0): HEX3..0 = detected frequency in Hz
// Debug mode  (SW[9]=1): HEX3..0 = raw zero-crossing count
// LED bar: LEDR[9:0] = frequency band (more LEDs = higher frequency)
// Reset: KEY[0] active-low.

module frequency_detector_top (
    input           MAX10_CLK1_50,
    input   [9:0]   SW,
    input   [1:0]   KEY,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout   [15:0]  ARDUINO_IO,
    inout           ARDUINO_RESET_N
);
    wire clk   = MAX10_CLK1_50;
    wire rst_n = KEY[0];
    wire debug = SW[9];

    // ARDUINO_IO[0] = UART RX from ESP32 GPIO16 (TX)
    assign ARDUINO_IO    = 16'bz;
    assign ARDUINO_RESET_N = 1'bz;
    wire uart_rx_pin = ARDUINO_IO[0];

    // ---- UART RX at 115200 baud ----
    wire [7:0] rx_byte;
    wire       rx_valid;

    uart_rx #(
        .CLK_FREQ (50_000_000),
        .BAUD     (115_200)
    ) u_uart_rx (
        .clk     (clk),
        .rst_n   (rst_n),
        .rx      (uart_rx_pin),
        .rx_data (rx_byte),
        .rx_valid(rx_valid)
    );

    // ---- Frame collection + zero-crossing detection ----
    // 256-byte frame: count consecutive sign-bit (bit[7]) changes.
    // Gap timer resets the frame if no byte arrives for >5 ms mid-frame.

    localparam GAP_CYCLES = 250_000;  // 5 ms at 50 MHz (18-bit: max 262143)

    logic [7:0]  byte_cnt;
    logic [7:0]  zc_count;
    logic        prev_sign;
    logic [7:0]  zc_latched;
    logic [17:0] gap_timer;
    logic        in_frame;

    // Combinational: zero-crossing indicator for the current incoming byte
    wire zc_this = rx_valid && (byte_cnt != 8'd0) && (rx_byte[7] != prev_sign);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt   <= 8'd0;
            zc_count   <= 8'd0;
            prev_sign  <= 1'b0;
            zc_latched <= 8'd0;
            gap_timer  <= 18'd0;
            in_frame   <= 1'b0;
        end else if (rx_valid) begin
            gap_timer <= 18'd0;
            in_frame  <= 1'b1;

            if (byte_cnt == 8'd0) begin
                // First byte: initialise; no crossing yet
                prev_sign <= rx_byte[7];
                zc_count  <= 8'd0;
                byte_cnt  <= 8'd1;
            end else begin
                prev_sign <= rx_byte[7];

                if (byte_cnt == 8'd255) begin
                    // 256th byte: latch final zero-crossing count
                    zc_latched <= zc_count + {7'b0, zc_this};
                    byte_cnt   <= 8'd0;
                    in_frame   <= 1'b0;
                end else begin
                    zc_count <= zc_count + {7'b0, zc_this};
                    byte_cnt <= byte_cnt + 8'd1;
                end
            end
        end else if (in_frame) begin
            // Gap detection: reset mid-frame sync on long pause
            if (gap_timer >= GAP_CYCLES) begin
                byte_cnt  <= 8'd0;
                zc_count  <= 8'd0;
                in_frame  <= 1'b0;
                gap_timer <= 18'd0;
            end else begin
                gap_timer <= gap_timer + 18'd1;
            end
        end
    end

    // ---- Frequency calculation ----
    // freq = zc * 125 / 8  (= zc * 15.625 Hz per crossing)
    // max: 128 * 125 = 16000, >> 3 = 2000 (fits in 11 bits)
    wire [15:0] freq_calc = {8'd0, zc_latched} * 16'd125;
    wire [10:0] freq_hz   = freq_calc[13:3];  // logical right-shift by 3

    // ---- BCD conversion ----
    wire [3:0] freq_thou, freq_hund, freq_tens, freq_ones;
    wire [3:0] zc_thou,   zc_hund,   zc_tens,   zc_ones;

    bin_to_bcd u_freq_bcd (
        .bin  (freq_hz),
        .thou (freq_thou),
        .hund (freq_hund),
        .tens (freq_tens),
        .ones (freq_ones)
    );

    bin_to_bcd u_zc_bcd (
        .bin  ({3'b0, zc_latched}),
        .thou (zc_thou),
        .hund (zc_hund),
        .tens (zc_tens),
        .ones (zc_ones)
    );

    // ---- LED bar: LEDR[i] lights when freq exceeds threshold ----
    // Range ~190-1900 Hz (10 bands, step ≈ 190 Hz each, shifted -100 from centre)
    assign LEDR[0] = (freq_hz >= 11'd190);
    assign LEDR[1] = (freq_hz >= 11'd380);
    assign LEDR[2] = (freq_hz >= 11'd570);
    assign LEDR[3] = (freq_hz >= 11'd760);
    assign LEDR[4] = (freq_hz >= 11'd950);
    assign LEDR[5] = (freq_hz >= 11'd1140);
    assign LEDR[6] = (freq_hz >= 11'd1330);
    assign LEDR[7] = (freq_hz >= 11'd1520);
    assign LEDR[8] = (freq_hz >= 11'd1710);
    assign LEDR[9] = (freq_hz >= 11'd1900);

    // ---- Leading-zero blanking ----
    // Normal: blank upper digits when zero
    wire freq_blank3 = (freq_thou == 4'd0);
    wire freq_blank2 = freq_blank3 && (freq_hund == 4'd0);
    wire freq_blank1 = freq_blank2 && (freq_tens == 4'd0);
    // Debug: zc max = 128 → 3 digits max, thousands always blank
    wire zc_blank2   = (zc_hund == 4'd0);
    wire zc_blank1   = zc_blank2 && (zc_tens == 4'd0);

    // ---- 7-segment display ----
    seven_segment seg0 (
        .data  (debug ? zc_ones  : freq_ones),
        .blank (1'b0),
        .seg   (HEX0)
    );
    seven_segment seg1 (
        .data  (debug ? zc_tens  : freq_tens),
        .blank (debug ? zc_blank1  : freq_blank1),
        .seg   (HEX1)
    );
    seven_segment seg2 (
        .data  (debug ? zc_hund  : freq_hund),
        .blank (debug ? zc_blank2  : freq_blank2),
        .seg   (HEX2)
    );
    seven_segment seg3 (
        .data  (debug ? 4'd0     : freq_thou),
        .blank (debug ? 1'b1     : freq_blank3),
        .seg   (HEX3)
    );

    assign HEX4 = 8'hFF;
    assign HEX5 = 8'hFF;

endmodule
