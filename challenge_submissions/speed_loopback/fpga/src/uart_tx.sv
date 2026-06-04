// UART Transmitter — parameterized baud rate
// 8N1: 1 start bit, 8 data bits, 1 stop bit

module uart_tx #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD     = 9600
)(
    input        clk,
    input        rst_n,
    input        tx_start,
    input  [7:0] tx_data,
    output reg   tx_busy,
    output reg   tx_out
);

    localparam BIT_PERIOD = CLK_FREQ / BAUD;

    reg [15:0] clk_cnt;
    reg [3:0]  bit_idx;     // 0=start, 1-8=data, 9=stop, 10=done
    reg [7:0]  shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_out  <= 1'b1;
            tx_busy <= 1'b0;
            clk_cnt <= 0;
            bit_idx <= 0;
            shift   <= 0;
        end else if (!tx_busy) begin
            if (tx_start) begin
                tx_busy <= 1'b1;
                shift   <= tx_data;
                tx_out  <= 1'b0;        // start bit
                clk_cnt <= 0;
                bit_idx <= 0;
            end
        end else begin
            if (clk_cnt == BIT_PERIOD - 1) begin
                clk_cnt <= 0;
                bit_idx <= bit_idx + 1;
                if (bit_idx < 8) begin
                    tx_out <= shift[0];
                    shift  <= {1'b0, shift[7:1]};
                end else if (bit_idx == 8) begin
                    tx_out <= 1'b1;     // stop bit
                end else begin
                    tx_busy <= 1'b0;
                    tx_out  <= 1'b1;    // idle
                end
            end else begin
                clk_cnt <= clk_cnt + 1;
            end
        end
    end

endmodule
