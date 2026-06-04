// UART Transmitter -- parameterized, 8N1
// tx_start: pulse high for 1 cycle with tx_data valid to begin a byte.
// tx_busy:  high while transmitting; accept new byte only when tx_busy=0.
// tx:       serial output, idle = 1.
//
// Frame: start bit (0), D0..D7, stop bit (1)  -- LSB first

module uart_tx #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD     = 9600
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] tx_data,   // Byte to send (sampled on tx_start rising edge)
    input  logic       tx_start,  // Pulse for 1 clock cycle to load and send
    output logic       tx,         // Serial output
    output logic       tx_busy     // High while frame is in progress
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD;  // 5208 for 9600 @ 50 MHz

    // 10-bit shift register: bit[0] = start(0), bits[8:1] = D0..D7, bit[9] = stop(1)
    logic [15:0] clk_cnt;
    logic [3:0]  bit_cnt;   // counts bits sent (0 = start, 1-8 = data, 9 = stop)
    logic [9:0]  sr;        // shift register, LSB shifted out first

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx      <= 1'b1;
            tx_busy <= 1'b0;
            clk_cnt <= 16'd0;
            bit_cnt <= 4'd0;
            sr      <= 10'h3FF;
        end else if (!tx_busy) begin
            tx <= 1'b1;   // Idle line
            if (tx_start) begin
                // Load: {stop=1, D7..D0, start=0}
                sr      <= {1'b1, tx_data, 1'b0};
                tx_busy <= 1'b1;
                clk_cnt <= 16'd0;
                bit_cnt <= 4'd0;
            end
        end else begin
            // Output current bit (LSB of shift register)
            tx <= sr[0];

            if (clk_cnt == CLKS_PER_BIT - 1) begin
                clk_cnt <= 16'd0;
                // Shift right; fill vacated MSB with 1 (stop/idle level)
                sr <= {1'b1, sr[9:1]};
                if (bit_cnt == 4'd9) begin
                    // All 10 bits sent (start + 8 data + stop)
                    tx_busy <= 1'b0;
                    bit_cnt <= 4'd0;
                end else begin
                    bit_cnt <= bit_cnt + 4'd1;
                end
            end else begin
                clk_cnt <= clk_cnt + 16'd1;
            end
        end
    end

endmodule
