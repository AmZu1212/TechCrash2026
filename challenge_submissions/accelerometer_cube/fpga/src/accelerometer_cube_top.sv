// Challenge 2: Accelerometer 3D Cube -- FPGA side
// Reads the onboard ADXL345 and streams raw X/Y/Z samples to ESP32.
//
// UART frame, 9600 8N1 on ARDUINO_IO[1]:
//   A5 5A SEQ X0 X1 Y0 Y1 Z0 Z1 SUM
// SUM is the low 8 bits of SEQ + X0 + X1 + Y0 + Y1 + Z0 + Z1.

module accelerometer_cube_top (
    input           MAX10_CLK1_50,
    input   [9:0]   SW,
    input   [1:0]   KEY,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout   [15:0]  ARDUINO_IO,
    inout           ARDUINO_RESET_N,

    output          GSENSOR_SCLK,
    output          GSENSOR_SDI,
    input           GSENSOR_SDO,
    output          GSENSOR_CS_N,
    input           GSENSOR_INT1,
    input           GSENSOR_INT2
);

    wire clk   = MAX10_CLK1_50;
    wire rst_n = SW[9] & KEY[0];

    // ---- Arduino header UART ----
    wire uart_tx_pin;
    assign ARDUINO_IO[0]    = 1'bz;
    assign ARDUINO_IO[1]    = uart_tx_pin;
    assign ARDUINO_IO[15:2] = 14'bz;
    assign ARDUINO_RESET_N  = 1'bz;

    // ---- ADXL345 SPI reader ----
    wire signed [15:0] x_raw;
    wire signed [15:0] y_raw;
    wire signed [15:0] z_raw;
    wire               sample_valid;
    wire               init_done;
    wire               devid_ok;
    wire [7:0]         devid;
    wire [3:0]         adxl_state;

    adxl345_spi #(
        .CLK_FREQ  (50_000_000),
        .SPI_HZ    (1_000_000),
        .SAMPLE_HZ (30)
    ) u_adxl (
        .clk          (clk),
        .rst_n        (rst_n),
        .gsensor_sclk (GSENSOR_SCLK),
        .gsensor_sdi  (GSENSOR_SDI),
        .gsensor_sdo  (GSENSOR_SDO),
        .gsensor_cs_n (GSENSOR_CS_N),
        .x_raw        (x_raw),
        .y_raw        (y_raw),
        .z_raw        (z_raw),
        .sample_valid (sample_valid),
        .init_done    (init_done),
        .devid_ok     (devid_ok),
        .devid        (devid),
        .state_debug  (adxl_state)
    );

    // ---- UART TX ----
    logic [7:0] tx_data;
    logic       tx_start;
    wire        tx_busy;

    uart_tx #(
        .CLK_FREQ (50_000_000),
        .BAUD     (9600)
    ) u_uart_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (tx_data),
        .tx_start (tx_start),
        .tx       (uart_tx_pin),
        .tx_busy  (tx_busy)
    );

    logic [7:0] seq;
    logic [7:0] x0, x1, y0, y1, z0, z1;
    logic [7:0] checksum;
    logic [3:0] frame_idx;
    logic [1:0] tx_state;
    logic       frame_toggle;

    localparam TX_IDLE = 2'd0;
    localparam TX_SEND = 2'd1;

    always_comb begin
        checksum = seq + x0 + x1 + y0 + y1 + z0 + z1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_data      <= 8'h00;
            tx_start     <= 1'b0;
            tx_state     <= TX_IDLE;
            frame_idx    <= 4'd0;
            seq          <= 8'h00;
            x0           <= 8'h00;
            x1           <= 8'h00;
            y0           <= 8'h00;
            y1           <= 8'h00;
            z0           <= 8'h00;
            z1           <= 8'h00;
            frame_toggle <= 1'b0;
        end else begin
            tx_start <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    if (sample_valid) begin
                        x0           <= x_raw[7:0];
                        x1           <= x_raw[15:8];
                        y0           <= y_raw[7:0];
                        y1           <= y_raw[15:8];
                        z0           <= z_raw[7:0];
                        z1           <= z_raw[15:8];
                        seq          <= seq + 8'd1;
                        frame_idx    <= 4'd0;
                        frame_toggle <= ~frame_toggle;
                        tx_state     <= TX_SEND;
                    end
                end

                TX_SEND: begin
                    if (!tx_busy && !tx_start) begin
                        case (frame_idx)
                            4'd0: tx_data <= 8'hA5;
                            4'd1: tx_data <= 8'h5A;
                            4'd2: tx_data <= seq;
                            4'd3: tx_data <= x0;
                            4'd4: tx_data <= x1;
                            4'd5: tx_data <= y0;
                            4'd6: tx_data <= y1;
                            4'd7: tx_data <= z0;
                            4'd8: tx_data <= z1;
                            4'd9: tx_data <= checksum;
                            default: tx_data <= 8'h00;
                        endcase
                        tx_start <= 1'b1;

                        if (frame_idx == 4'd9) begin
                            tx_state  <= TX_IDLE;
                            frame_idx <= 4'd0;
                        end else begin
                            frame_idx <= frame_idx + 4'd1;
                        end
                    end
                end

                default: begin
                    tx_state <= TX_IDLE;
                end
            endcase
        end
    end

    // ---- Tilt LEDs ----
    localparam signed [15:0] TILT_THRESHOLD = 16'sd80;

    assign LEDR[0] = (x_raw < -TILT_THRESHOLD);  // left
    assign LEDR[1] = (x_raw >  TILT_THRESHOLD);  // right
    assign LEDR[2] = (y_raw >  TILT_THRESHOLD);  // forward
    assign LEDR[3] = (y_raw < -TILT_THRESHOLD);  // back
    assign LEDR[4] = frame_toggle;
    assign LEDR[5] = tx_busy;
    assign LEDR[6] = init_done;
    assign LEDR[7] = devid_ok;
    assign LEDR[8] = ~GSENSOR_CS_N;
    assign LEDR[9] = rst_n;

    // ---- Simple debug display ----
    seven_segment seg0 (.data(devid[3:0]), .blank(1'b0), .seg(HEX0));
    seven_segment seg1 (.data(devid[7:4]), .blank(1'b0), .seg(HEX1));
    seven_segment seg2 (.data(seq[3:0]), .blank(1'b0), .seg(HEX2));
    seven_segment seg3 (.data(adxl_state), .blank(1'b0), .seg(HEX3));
    seven_segment seg4 (.data({3'b000, GSENSOR_INT1}), .blank(1'b0), .seg(HEX4));
    seven_segment seg5 (.data({3'b000, GSENSOR_INT2}), .blank(1'b0), .seg(HEX5));

endmodule
