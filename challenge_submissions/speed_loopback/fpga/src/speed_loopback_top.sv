// Speed Loopback Top Module
// FPGA generates N random bytes, sends to ESP32 via UART.
// ESP32 sums them and sends back checksum (LSB 8 bits).
// FPGA compares and displays elapsed time in ms.
//
// Protocol: FPGA sends 4-byte header (N, little-endian) then N random bytes.
//           ESP32 sends back 1 byte (sum & 0xFF).
//
// Fixed count: 10,000 bytes
// SW[9]   debug mode: in DONE, show expected/received checksums instead of timer
// KEY[0]  start / restart
// KEY[1]  reset (active low)
// HEX5-0  show timer_ms (hex) in DONE, progress during send, count in IDLE
// LEDR[9] running, LEDR[0] pass, LEDR[1] fail

module speed_loopback_top(
    input         MAX10_CLK1_50,
    input  [1:0]  KEY,
    input  [9:0]  SW,
    output [9:0]  LEDR,
    output [7:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout  [15:0] ARDUINO_IO
);

    localparam UART_BAUD = 921600;

    wire clk   = MAX10_CLK1_50;
    wire rst_n  = KEY[1];

    // ---- Edge detect KEY[0] (active-low button) ----
    reg key0_r, key0_rr;
    always @(posedge clk) begin
        key0_r  <= KEY[0];
        key0_rr <= key0_r;
    end
    wire start_pulse = key0_rr & ~key0_r;   // falling edge

    // ---- Fixed data count: 10,000 bytes ----
    wire [31:0] total_count = 32'd10_000;

    // ---- LFSR-16 (x^16 + x^15 + x^13 + x^4 + 1) ----
    reg [15:0] lfsr;
    wire lfsr_feedback = lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3];

    // ---- Checksum accumulator ----
    reg [31:0] sum;

    // ---- UART TX (FPGA -> ESP32 on GPIO[1]) ----
    reg        tx_start;
    reg  [7:0] tx_data;
    wire       tx_busy;
    wire       tx_out;

    uart_tx #(.CLK_FREQ(50_000_000), .BAUD(UART_BAUD)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .tx_start(tx_start), .tx_data(tx_data),
        .tx_busy(tx_busy),   .tx_out(tx_out)
    );

    // ---- UART RX (ESP32 -> FPGA on GPIO[0]) ----
    wire [7:0] rx_data;
    wire       rx_valid;

    uart_rx #(.CLK_FREQ(50_000_000), .BAUD(UART_BAUD)) u_rx (
        .clk(clk), .rst_n(rst_n),
        .rx_in(ARDUINO_IO[0]),
        .rx_data(rx_data), .rx_valid(rx_valid)
    );

    // ---- Arduino Header IO ----
    assign ARDUINO_IO[0]    = 1'bz;          // RX input
    assign ARDUINO_IO[1]    = tx_out;        // TX output
    assign ARDUINO_IO[15:2] = {14{1'bz}};   // unused

    // ---- Millisecond timer ----
    reg [31:0] timer_ms;
    reg [15:0] timer_pre;
    reg        timer_running, timer_reset;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer_ms  <= 0;
            timer_pre <= 0;
        end else if (timer_reset) begin
            timer_ms  <= 0;
            timer_pre <= 0;
        end else if (timer_running) begin
            if (timer_pre == 16'd49_999) begin
                timer_pre <= 0;
                timer_ms  <= timer_ms + 1;
            end else
                timer_pre <= timer_pre + 1;
        end
    end

    // ---- State machine ----
    localparam S_IDLE = 3'd0,
               S_HDR  = 3'd1,
               S_DATA = 3'd2,
               S_WAIT = 3'd3,
               S_DONE = 3'd4;

    reg [2:0]  state;
    reg [31:0] send_count;
    reg [1:0]  hdr_idx;
    reg        pass;
    reg [7:0]  rx_checksum;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            lfsr          <= 16'hACE1;
            sum           <= 0;
            send_count    <= 0;
            hdr_idx       <= 0;
            pass          <= 0;
            rx_checksum   <= 0;
            tx_start      <= 0;
            timer_running <= 0;
            timer_reset   <= 0;
        end else begin
            tx_start    <= 0;       // default: one-cycle pulse
            timer_reset <= 0;

            // ---- Start / Restart ----
            if (start_pulse && (state == S_IDLE || state == S_DONE)) begin
                state         <= S_HDR;
                lfsr          <= 16'hACE1;
                sum           <= 0;
                send_count    <= 0;
                hdr_idx       <= 0;
                pass          <= 0;
                timer_reset   <= 1;
                timer_running <= 1;
            end else begin
                case (state)
                    S_IDLE: ;   // wait for start_pulse (handled above)

                    // Send 4-byte header: total_count little-endian
                    S_HDR: begin
                        if (!tx_busy && !tx_start) begin
                            case (hdr_idx)
                                2'd0: tx_data <= total_count[7:0];
                                2'd1: tx_data <= total_count[15:8];
                                2'd2: tx_data <= total_count[23:16];
                                2'd3: tx_data <= total_count[31:24];
                            endcase
                            tx_start <= 1;
                            if (hdr_idx == 2'd3)
                                state <= S_DATA;
                            hdr_idx <= hdr_idx + 1;
                        end
                    end

                    // Send N random bytes
                    S_DATA: begin
                        if (!tx_busy && !tx_start) begin
                            if (send_count < total_count) begin
                                tx_data    <= lfsr[7:0];
                                tx_start   <= 1;
                                sum        <= sum + {24'd0, lfsr[7:0]};
                                lfsr       <= {lfsr[14:0], lfsr_feedback};
                                send_count <= send_count + 1;
                            end else begin
                                state <= S_WAIT;
                            end
                        end
                    end

                    // Wait for ESP32 checksum byte
                    S_WAIT: begin
                        if (rx_valid) begin
                            rx_checksum   <= rx_data;
                            timer_running <= 0;
                            pass          <= (rx_data == sum[7:0]);
                            state         <= S_DONE;
                        end
                    end

                    S_DONE: ;   // wait for start_pulse (handled above)
                endcase
            end
        end
    end

    // ---- Display mux ----
    reg [23:0] disp;
    always @(*) begin
        case (state)
            S_IDLE:  disp = total_count[23:0];
            S_HDR:   disp = 24'd0;
            S_DATA:  disp = send_count[23:0];
            S_WAIT:  disp = send_count[23:0];
            S_DONE:  disp = SW[9] ? {8'd0, sum[7:0], rx_checksum}   // debug
                                  : timer_ms[23:0];                  // elapsed ms
            default: disp = 24'd0;
        endcase
    end

    seven_segment seg0(.value(disp[3:0]),   .segments(HEX0));
    seven_segment seg1(.value(disp[7:4]),   .segments(HEX1));
    seven_segment seg2(.value(disp[11:8]),  .segments(HEX2));
    seven_segment seg3(.value(disp[15:12]), .segments(HEX3));
    seven_segment seg4(.value(disp[19:16]), .segments(HEX4));
    seven_segment seg5(.value(disp[23:20]), .segments(HEX5));

    // ---- LEDs ----
    assign LEDR[9]   = timer_running;
    assign LEDR[8]   = (state == S_DONE);
    assign LEDR[7:2] = 6'd0;
    assign LEDR[1]   = (state == S_DONE) & ~pass;
    assign LEDR[0]   = (state == S_DONE) &  pass;

endmodule
