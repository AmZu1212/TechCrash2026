// ============================================================
// CrashTech VLSI-2026 -- Challenge 8: DOOM Clone Controller
// ============================================================
// Reads KEY[0], KEY[1], SW[9:0] and streams a 6-byte control
// packet to the ESP32 at 115200 baud on ARDUINO_IO[1].
//
// Packet format (6 bytes):
//   0xA5  0x5A  SW_LO  SW_HI  KEYS  CKSUM
//   SW_LO = SW[7:0]
//   SW_HI = {6'b0, SW[9:8]}
//   KEYS  = {6'b0, ~KEY[1], ~KEY[0]}   (active-low → invert)
//   CKSUM = (SW_LO + SW_HI + KEYS) & 0xFF
//
// Packets sent continuously at ~30 Hz.
//
// LEDs mirror current switch state as a quick sanity indicator.
// HEX0 shows KEY[0] press indicator, HEX1 shows KEY[1].
// ============================================================

module doom_clone_top (
    input           MAX10_CLK1_50,
    input   [9:0]   SW,
    input   [1:0]   KEY,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout   [15:0]  ARDUINO_IO,
    inout           ARDUINO_RESET_N
);

    wire clk = MAX10_CLK1_50;

    // SW[9] = hard reset (use internal POR instead for game, SW[9] is debug overlay)
    // Use a simple power-on reset
    reg [3:0] por_cnt = 4'd0;
    reg rst_n = 1'b0;
    always @(posedge clk) begin
        if (!(&por_cnt)) begin
            por_cnt <= por_cnt + 4'd1;
            rst_n   <= 1'b0;
        end else
            rst_n <= 1'b1;
    end

    // ---- Arduino header ----
    wire uart_tx_wire;
    assign ARDUINO_IO[1]    = uart_tx_wire;   // TX -> ESP32 GPIO17
    assign ARDUINO_IO[0]    = 1'bz;
    assign ARDUINO_IO[15:2] = 14'bz;
    assign ARDUINO_RESET_N  = 1'bz;

    // ---- Mirror switches on LEDs ----
    assign LEDR = SW;

    // ---- HEX: show "-" when key released, "0" when pressed ----
    // KEY[0] active-low: LOW = pressed
    assign HEX0 = KEY[0] ? 8'b1011_1111 : 8'b1100_0000;  // '-' or '0'
    assign HEX1 = KEY[1] ? 8'b1011_1111 : 8'b1100_0000;
    assign HEX2 = 8'hFF;
    assign HEX3 = 8'hFF;
    assign HEX4 = 8'hFF;
    assign HEX5 = 8'hFF;

    // ================================================================
    //  UART TX — 115200 baud, inline engine
    // ================================================================
    localparam CLKS_PER_BIT = 17'd434;  // 50_000_000 / 115200

    reg [16:0] tx_clk_cnt;
    reg  [3:0] tx_bit_idx;
    reg  [9:0] tx_shift;
    reg        tx_busy;
    reg        tx_out_reg;
    reg        tx_start;
    reg  [7:0] tx_data;

    assign uart_tx_wire = tx_out_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_busy    <= 1'b0;
            tx_out_reg <= 1'b1;
            tx_clk_cnt <= 17'd0;
            tx_bit_idx <= 4'd0;
        end else if (!tx_busy && tx_start) begin
            tx_shift   <= {1'b1, tx_data, 1'b0};
            tx_busy    <= 1'b1;
            tx_bit_idx <= 4'd0;
            tx_clk_cnt <= 17'd0;
            tx_out_reg <= 1'b0;
        end else if (tx_busy) begin
            if (tx_clk_cnt == CLKS_PER_BIT - 17'd1) begin
                tx_clk_cnt <= 17'd0;
                tx_bit_idx <= tx_bit_idx + 4'd1;
                if (tx_bit_idx < 4'd9)
                    tx_out_reg <= tx_shift[tx_bit_idx + 4'd1];
                else begin
                    tx_busy    <= 1'b0;
                    tx_out_reg <= 1'b1;
                end
            end else
                tx_clk_cnt <= tx_clk_cnt + 17'd1;
        end
    end

    // ================================================================
    //  Packet dispatch — send 6-byte packet at ~30 Hz
    //  Period: 50_000_000 / 30 ≈ 1_666_667 clocks
    // ================================================================
    localparam TX_PERIOD = 24'd1_666_667;

    // Latch inputs at packet-send time to avoid mid-packet glitches
    reg  [7:0] latch_sw_lo;
    reg  [7:0] latch_sw_hi;
    reg  [7:0] latch_keys;
    reg  [7:0] latch_cksum;

    localparam TXD_IDLE = 3'd0,
               TXD_LATCH= 3'd1,
               TXD_LOAD = 3'd2,
               TXD_GAP  = 3'd3,
               TXD_WAIT = 3'd4;

    reg [23:0] tx_timer;
    reg  [2:0] tx_byte_idx;
    reg  [2:0] txd_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_timer    <= 24'd0;
            tx_byte_idx <= 3'd0;
            txd_state   <= TXD_IDLE;
            tx_start    <= 1'b0;
            tx_data     <= 8'd0;
            latch_sw_lo <= 8'd0;
            latch_sw_hi <= 8'd0;
            latch_keys  <= 8'd0;
            latch_cksum <= 8'd0;
        end else begin
            tx_start <= 1'b0;

            case (txd_state)
                TXD_IDLE: begin
                    if (tx_timer == TX_PERIOD - 24'd1) begin
                        tx_timer  <= 24'd0;
                        txd_state <= TXD_LATCH;
                    end else
                        tx_timer <= tx_timer + 24'd1;
                end

                TXD_LATCH: begin
                    latch_sw_lo <= SW[7:0];
                    latch_sw_hi <= {6'b0, SW[9:8]};
                    latch_keys  <= {6'b0, ~KEY[1], ~KEY[0]};
                    latch_cksum <= (SW[7:0] + {6'b0, SW[9:8]} + {6'b0, ~KEY[1], ~KEY[0]}) & 8'hFF;
                    tx_byte_idx <= 3'd0;
                    txd_state   <= TXD_LOAD;
                end

                TXD_LOAD: begin
                    case (tx_byte_idx)
                        3'd0: tx_data <= 8'hA5;
                        3'd1: tx_data <= 8'h5A;
                        3'd2: tx_data <= latch_sw_lo;
                        3'd3: tx_data <= latch_sw_hi;
                        3'd4: tx_data <= latch_keys;
                        3'd5: tx_data <= latch_cksum;
                        default: tx_data <= 8'h00;
                    endcase
                    tx_start  <= 1'b1;
                    txd_state <= TXD_GAP;
                end

                TXD_GAP: begin
                    txd_state <= TXD_WAIT;
                end

                TXD_WAIT: begin
                    if (!tx_busy) begin
                        if (tx_byte_idx == 3'd5)
                            txd_state <= TXD_IDLE;
                        else begin
                            tx_byte_idx <= tx_byte_idx + 3'd1;
                            txd_state   <= TXD_LOAD;
                        end
                    end
                end

                default: txd_state <= TXD_IDLE;
            endcase
        end
    end

endmodule
