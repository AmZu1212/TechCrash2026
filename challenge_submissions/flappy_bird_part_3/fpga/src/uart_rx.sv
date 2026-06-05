// UART receiver, 8N1, idle high.

module uart_rx #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD     = 9600
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx,
    output logic [7:0] rx_data,
    output logic       rx_valid
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD;
    localparam HALF_BIT     = CLKS_PER_BIT / 2;

    logic rx_s1, rx_s2;
    logic [15:0] clk_cnt;
    logic [2:0]  bit_cnt;
    logic [7:0]  shift;
    logic [1:0]  state;

    localparam RX_IDLE  = 2'd0;
    localparam RX_START = 2'd1;
    localparam RX_DATA  = 2'd2;
    localparam RX_STOP  = 2'd3;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s1 <= 1'b1;
            rx_s2 <= 1'b1;
        end else begin
            rx_s1 <= rx;
            rx_s2 <= rx_s1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_data  <= 8'd0;
            rx_valid <= 1'b0;
            clk_cnt  <= 16'd0;
            bit_cnt  <= 3'd0;
            shift    <= 8'd0;
            state    <= RX_IDLE;
        end else begin
            rx_valid <= 1'b0;

            case (state)
                RX_IDLE: begin
                    clk_cnt <= 16'd0;
                    bit_cnt <= 3'd0;
                    if (!rx_s2)
                        state <= RX_START;
                end

                RX_START: begin
                    if (clk_cnt == HALF_BIT - 1) begin
                        clk_cnt <= 16'd0;
                        if (!rx_s2)
                            state <= RX_DATA;
                        else
                            state <= RX_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end

                RX_DATA: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt        <= 16'd0;
                        shift[bit_cnt] <= rx_s2;
                        if (bit_cnt == 3'd7)
                            state <= RX_STOP;
                        else
                            bit_cnt <= bit_cnt + 3'd1;
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end

                RX_STOP: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 16'd0;
                        state   <= RX_IDLE;
                        if (rx_s2) begin
                            rx_data  <= shift;
                            rx_valid <= 1'b1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end

                default: state <= RX_IDLE;
            endcase
        end
    end

endmodule
