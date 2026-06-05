// UART transmitter, 8N1, idle high.

module uart_tx #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD     = 9600
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] tx_data,
    input  logic       tx_start,
    output logic       tx,
    output logic       tx_busy
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD;

    logic [15:0] clk_cnt;
    logic [3:0]  bit_cnt;
    logic [9:0]  shift;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx      <= 1'b1;
            tx_busy <= 1'b0;
            clk_cnt <= 16'd0;
            bit_cnt <= 4'd0;
            shift   <= 10'h3FF;
        end else if (!tx_busy) begin
            tx <= 1'b1;
            if (tx_start) begin
                shift   <= {1'b1, tx_data, 1'b0};
                tx_busy <= 1'b1;
                clk_cnt <= 16'd0;
                bit_cnt <= 4'd0;
            end
        end else begin
            tx <= shift[0];
            if (clk_cnt == CLKS_PER_BIT - 1) begin
                clk_cnt <= 16'd0;
                shift   <= {1'b1, shift[9:1]};
                if (bit_cnt == 4'd9) begin
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
