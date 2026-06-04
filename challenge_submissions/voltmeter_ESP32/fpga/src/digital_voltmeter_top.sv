// Digital Volt-meter Top Module -- DE10-Lite
// Receives 5-byte binary frames via UART from ESP32
// Frame format:
//   Byte 0: Ones digit (BCD 0-3)
//   Byte 1: Tenths digit (BCD 0-9)
//   Byte 2: Hundredths digit (BCD 0-9)
//   Byte 3: LED bar bits [7:0]
//   Byte 4: LED bar bits [9:8]
//
// Displays voltage on HEX3:HEX0 as X.XX (with decimal point on HEX2)
// Shows LED bar graph on LEDR[9:0] proportional to voltage (0.3V per LED)
//
// UART input: ARDUINO_IO[0] via Arduino header (9600 baud)
// Display: HEX3 = ones digit, HEX2 = decimal point, HEX1 = tenths, HEX0 = hundredths
// LEDs: LEDR[9:0] = voltage level indicator
// Reset: SW[9] active-low

module digital_voltmeter_top (
    input           MAX10_CLK1_50,
    input   [9:0]   SW,
    input   [1:0]   KEY,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout   [15:0]  ARDUINO_IO,
    inout           ARDUINO_RESET_N
);

    // ---- Wiring ----
    wire clk   = MAX10_CLK1_50;
    wire rst_n = SW[9];
    wire uart_rx_pin;

    // ARDUINO_IO[0] is UART RX from ESP32
    // ARDUINO_IO[1] reserved for TX (unused)
    assign ARDUINO_IO[15:2] = 14'bz;
    assign ARDUINO_IO[1]    = 1'bz;
    assign ARDUINO_IO[0]    = 1'bz;  // Input
    assign uart_rx_pin = ARDUINO_IO[0];

    // Unused displays off
    assign HEX4 = 8'b11111111;
    assign HEX5 = 8'b11111111;

    // ---- UART Receiver ----
    wire [7:0] rx_byte;
    wire       rx_valid;

    uart_rx #(
        .CLK_FREQ(50_000_000),
        .BAUD(9600)
    ) u_uart_rx (
        .clk      (clk),
        .rst_n    (rst_n),
        .rx       (uart_rx_pin),
        .rx_data  (rx_byte),
        .rx_valid (rx_valid)
    );

    // ---- 5-Byte Frame Receiver ----
    // Accumulate bytes in frame buffer
    reg [3:0] byte_cnt;        // 0-4 counting bytes in frame
    reg [7:0] frame_buf [0:4]; // 5-byte buffer
    reg       frame_valid;
    
    reg [3:0] digit [0:3];     // digit[3]=ones, digit[2]=tenths, digit[1]=hundredths, digit[0]=unused
    reg [9:0] led_bar;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt      <= 0;
            frame_valid   <= 0;
            digit[3] <= 0; digit[2] <= 0; digit[1] <= 0; digit[0] <= 0;
            led_bar  <= 10'b0000000000;
        end else if (rx_valid) begin
            // Store incoming byte in frame buffer
            frame_buf[byte_cnt] <= rx_byte;
            
            if (byte_cnt == 4) begin
                // Frame complete -- latch all 5 bytes
                digit[3] <= frame_buf[0][3:0];  // ones
                digit[2] <= frame_buf[1][3:0];  // tenths
                digit[1] <= frame_buf[2][3:0];  // hundredths
                
                // Combine LED bar bits from bytes 3 and 4
                led_bar <= {frame_buf[4][1:0], frame_buf[3][7:0]};
                
                frame_valid <= 1;
                byte_cnt    <= 0;  // Reset for next frame
            end else begin
                byte_cnt <= byte_cnt + 1;
            end
        end
    end

    // ---- LED Bar Output ----
    assign LEDR = led_bar;

    // ---- 7-Segment Displays ----
    // HEX2 = ones digit with decimal point
    wire [7:0] seg3_out;
    seven_segment seg3 (
        .data(digit[3]),
        .blank(~frame_valid),
        .seg(seg3_out)
    );
    // Light the decimal point (bit 7, active-low) on HEX2 when frame is valid
    assign HEX2 = frame_valid ? (seg3_out & 8'b01111111) : 8'b11111111;

    // HEX3 = blank
    assign HEX3 = 8'b11111111;

    // HEX1 = tenths digit
    seven_segment seg1 (
        .data(digit[2]),
        .blank(~frame_valid),
        .seg(HEX1)
    );

    // HEX0 = hundredths digit
    seven_segment seg0 (
        .data(digit[1]),
        .blank(~frame_valid),
        .seg(HEX0)
    );

endmodule
