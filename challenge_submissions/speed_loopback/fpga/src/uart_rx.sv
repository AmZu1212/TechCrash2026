// UART Receiver — parameterized baud rate
// 8N1: 1 start bit, 8 data bits, 1 stop bit

module uart_rx #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD     = 9600
)(
    input        clk,
    input        rst_n,
    input        rx_in,
    output reg [7:0] rx_data,
    output reg       rx_valid
);

    localparam BIT_PERIOD = CLK_FREQ / BAUD;
    localparam HALF_BIT   = BIT_PERIOD / 2;

    // Metastability sync
    reg [1:0] rx_sync;
    wire rx_bit = rx_sync[1];
    always @(posedge clk) rx_sync <= {rx_sync[0], rx_in};

    localparam S_IDLE  = 2'd0,
               S_START = 2'd1,
               S_DATA  = 2'd2,
               S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [15:0] clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            rx_data  <= 0;
            rx_valid <= 0;
            clk_cnt  <= 0;
            bit_idx  <= 0;
            shift    <= 0;
        end else begin
            rx_valid <= 0;

            case (state)
                S_IDLE: begin
                    if (!rx_bit) begin          // falling edge = start bit
                        state   <= S_START;
                        clk_cnt <= 0;
                    end
                end

                S_START: begin
                    if (clk_cnt == HALF_BIT - 1) begin
                        if (!rx_bit) begin      // still low at mid-bit
                            state   <= S_DATA;
                            clk_cnt <= 0;
                            bit_idx <= 0;
                        end else
                            state <= S_IDLE;     // glitch
                    end else
                        clk_cnt <= clk_cnt + 1;
                end

                S_DATA: begin
                    if (clk_cnt == BIT_PERIOD - 1) begin
                        clk_cnt <= 0;
                        shift   <= {rx_bit, shift[7:1]};   // LSB first
                        if (bit_idx == 7)
                            state <= S_STOP;
                        else
                            bit_idx <= bit_idx + 1;
                    end else
                        clk_cnt <= clk_cnt + 1;
                end

                S_STOP: begin
                    if (clk_cnt == BIT_PERIOD - 1) begin
                        if (rx_bit) begin       // valid stop bit
                            rx_data  <= shift;
                            rx_valid <= 1;
                        end
                        state <= S_IDLE;
                    end else
                        clk_cnt <= clk_cnt + 1;
                end
            endcase
        end
    end

endmodule
