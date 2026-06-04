// ============================================================
// CrashTech VLSI-2026 -- Challenge 4: Press Right
// ============================================================
// A counter increments every 10 ms (100 counts/second), shown
// on HEX3..HEX0 as a 4-digit decimal number.
//
// KEY[0] (active-low, DE10-Lite pushbutton):
//   - Press once    → start counter from 0
//   - Press again   → stop / freeze counter
//   - Press again   → restart game (clear display, counter = 0)
//
// Goal: stop exactly at 1000 (= 10.00 seconds).
// Win window: 990 – 1010.
//
// UART TX: when stopped, send "XXXX\n" every 100 ms to ESP32.
//   ARDUINO_IO[1] = TX → ESP32 GPIO17 (UART2 RX), 9600 8N1.
//
// LEDs (STOPPED state only): proximity thermometer.
//   LEDR[9] = within ±10 (win zone)
//   LEDR[8] = within ±25
//   LEDR[7] = within ±50
//   ...down to LEDR[0] = within ±500
//
// SW[9] = hard reset (active-low).
// ============================================================

module press_right_top (
    input           MAX10_CLK1_50,
    input   [9:0]   SW,
    input   [1:0]   KEY,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout   [15:0]  ARDUINO_IO,
    inout           ARDUINO_RESET_N
);

    wire clk   = MAX10_CLK1_50;
    wire rst_n = SW[9];

    // ---- Arduino I/O ----
    wire uart_tx_out;
    assign ARDUINO_IO[1]    = uart_tx_out;   // UART TX → ESP32 GPIO17
    assign ARDUINO_IO[0]    = 1'bz;          // not used (ESP32 does not TX back)
    assign ARDUINO_IO[15:2] = 14'bz;
    assign ARDUINO_RESET_N  = 1'bz;

    // ================================================================
    //  KEY[0] two-stage synchroniser + 20 ms debounce + edge detect
    //  KEY[0] is active-low: normally HIGH, goes LOW when pressed.
    //  key_press = single-cycle HIGH pulse on each press (falling edge).
    // ================================================================
    reg key_s1, key_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin key_s1 <= 1'b1; key_s2 <= 1'b1; end
        else        begin key_s1 <= KEY[0]; key_s2 <= key_s1; end
    end

    // Debounce: register the stable level only after 20 ms of stability.
    reg [19:0] deb_cnt;          // 20-bit: 20ms at 50 MHz = 1_000_000 clocks
    reg        key_deb;          // debounced level
    reg        key_deb_r;        // previous debounced level

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            deb_cnt   <= 20'd0;
            key_deb   <= 1'b1;
            key_deb_r <= 1'b1;
        end else begin
            key_deb_r <= key_deb;
            if (key_s2 != key_deb) begin
                if (deb_cnt == 20'd999_999) begin   // 20 ms
                    key_deb <= key_s2;
                    deb_cnt <= 20'd0;
                end else
                    deb_cnt <= deb_cnt + 20'd1;
            end else
                deb_cnt <= 20'd0;
        end
    end

    // Falling edge of debounced signal = button press
    wire key_press = key_deb_r & ~key_deb;

    // ================================================================
    //  Game state machine
    // ================================================================
    localparam IDLE    = 2'd0,   // display blank, waiting for first press
               RUNNING = 2'd1,   // counter counting, display live
               STOPPED = 2'd2;   // counter frozen, UART sending, press to restart

    reg [1:0] state;

    // ================================================================
    //  Counter (0 – 9999, ticks every 10 ms)
    // ================================================================
    localparam TICK_10MS = 20'd500_000;  // 10 ms at 50 MHz
    localparam CNT_MAX   = 14'd9999;

    reg [19:0] tick_cnt;    // 10ms tick divider
    reg [13:0] counter;     // live counter
    reg [13:0] lat_count;   // latched value when stopped

    wire tick = (tick_cnt == TICK_10MS - 20'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            tick_cnt  <= 20'd0;
            counter   <= 14'd0;
            lat_count <= 14'd0;
        end else begin
            case (state)
                // ---- IDLE: display blank, counter reset ----
                IDLE: begin
                    tick_cnt <= 20'd0;
                    counter  <= 14'd0;
                    if (key_press) state <= RUNNING;
                end

                // ---- RUNNING: count every 10 ms ----
                RUNNING: begin
                    if (tick) begin
                        tick_cnt <= 20'd0;
                        counter  <= (counter == CNT_MAX) ? CNT_MAX
                                                         : counter + 14'd1;
                    end else
                        tick_cnt <= tick_cnt + 20'd1;

                    if (key_press) begin
                        lat_count <= counter;   // snapshot on press
                        state     <= STOPPED;
                    end
                end

                // ---- STOPPED: frozen, UART sending ----
                STOPPED: begin
                    if (key_press) begin
                        counter  <= 14'd0;
                        tick_cnt <= 20'd0;
                        state    <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    // ================================================================
    //  BCD digit extraction
    //  In IDLE/RUNNING: show live counter.  In STOPPED: show lat_count.
    // ================================================================
    wire [13:0] disp_val = (state == STOPPED) ? lat_count : counter;

    wire [3:0] dig3 = 4'(disp_val / 14'd1000);
    wire [3:0] dig2 = 4'((disp_val % 14'd1000) / 14'd100);
    wire [3:0] dig1 = 4'((disp_val % 14'd100)  / 14'd10);
    wire [3:0] dig0 = 4'(disp_val % 14'd10);

    // Leading-zero suppression flags
    wire lz3 = (dig3 == 4'd0);
    wire lz2 = lz3 & (dig2 == 4'd0);
    wire lz1 = lz2 & (dig1 == 4'd0);

    wire show = (state != IDLE);   // blank everything in IDLE

    // ================================================================
    //  7-segment decoder (active-low, bit7 = DP, 8'hFF = blank)
    // ================================================================
    function [7:0] seg7;
        input [3:0] d;
        input       blank;
        begin
            if (blank)
                seg7 = 8'hFF;
            else
                case (d)
                    4'd0: seg7 = 8'b1100_0000;
                    4'd1: seg7 = 8'b1111_1001;
                    4'd2: seg7 = 8'b1010_0100;
                    4'd3: seg7 = 8'b1011_0000;
                    4'd4: seg7 = 8'b1001_1001;
                    4'd5: seg7 = 8'b1001_0010;
                    4'd6: seg7 = 8'b1000_0010;
                    4'd7: seg7 = 8'b1111_1000;
                    4'd8: seg7 = 8'b1000_0000;
                    4'd9: seg7 = 8'b1001_0000;
                    default: seg7 = 8'hFF;
                endcase
        end
    endfunction

    assign HEX3 = seg7(dig3, (~show) | lz3);
    assign HEX2 = seg7(dig2, (~show) | lz2);
    assign HEX1 = seg7(dig1, (~show) | lz1);
    assign HEX0 = seg7(dig0, ~show);     // ones: always show when running/stopped
    assign HEX4 = 8'hFF;
    assign HEX5 = 8'hFF;

    // ================================================================
    //  LED proximity indicator (STOPPED state only)
    //  LEDR[9] = within ±10 (win zone), ..., LEDR[0] = within ±500
    // ================================================================
    wire [13:0] distance = (lat_count >= 14'd1000)
                         ? (lat_count - 14'd1000)
                         : (14'd1000 - lat_count);

    wire [9:0] prox;
    // Every 20 counts from target: within ±20 → all 10 on; +20 removes one LED
    assign prox[0] = (distance <= 14'd200);
    assign prox[1] = (distance <= 14'd180);
    assign prox[2] = (distance <= 14'd160);
    assign prox[3] = (distance <= 14'd140);
    assign prox[4] = (distance <= 14'd120);
    assign prox[5] = (distance <= 14'd100);
    assign prox[6] = (distance <= 14'd80);
    assign prox[7] = (distance <= 14'd60);
    assign prox[8] = (distance <= 14'd40);
    assign prox[9] = (distance <= 14'd20);

    assign LEDR = (state == STOPPED) ? prox : 10'd0;

    // ================================================================
    //  UART TX — 9600 baud inline engine (9600 8N1, 50 MHz clock)
    // ================================================================
    localparam CLKS_PER_BIT = 13'd5208;  // 50_000_000 / 9600

    reg [12:0] tx_clk_cnt;
    reg  [3:0] tx_bit_idx;
    reg  [9:0] tx_shift;
    reg        tx_busy;
    reg        tx_out_reg;
    // tx_start and tx_data are driven by the TX dispatch block below
    reg        tx_start;
    reg  [7:0] tx_data;

    assign uart_tx_out = tx_out_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_busy    <= 1'b0;
            tx_out_reg <= 1'b1;
            tx_clk_cnt <= 13'd0;
            tx_bit_idx <= 4'd0;
        end else if (!tx_busy && tx_start) begin
            // Load: stop(1) | D7..D0 | start(0)
            tx_shift   <= {1'b1, tx_data, 1'b0};
            tx_busy    <= 1'b1;
            tx_bit_idx <= 4'd0;
            tx_clk_cnt <= 13'd0;
            tx_out_reg <= 1'b0;          // drive start bit
        end else if (tx_busy) begin
            if (tx_clk_cnt == CLKS_PER_BIT - 13'd1) begin
                tx_clk_cnt <= 13'd0;
                tx_bit_idx <= tx_bit_idx + 4'd1;
                if (tx_bit_idx < 4'd9)
                    tx_out_reg <= tx_shift[tx_bit_idx + 4'd1];
                else begin
                    tx_busy    <= 1'b0;
                    tx_out_reg <= 1'b1;  // idle high
                end
            end else
                tx_clk_cnt <= tx_clk_cnt + 13'd1;
        end
    end

    // ================================================================
    //  TX dispatch: send "XXXX\n" every 100 ms in STOPPED state
    //  Frame: lat_dig3 lat_dig2 lat_dig1 lat_dig0 '\n'
    //         (5 ASCII bytes: digits as '0'–'9', newline = 0x0A)
    // ================================================================
    localparam TX_PERIOD = 23'd5_000_000;  // 100 ms at 50 MHz

    // Digit extraction from lat_count (stable while STOPPED)
    wire [3:0] lat_dig3 = 4'(lat_count / 14'd1000);
    wire [3:0] lat_dig2 = 4'((lat_count % 14'd1000) / 14'd100);
    wire [3:0] lat_dig1 = 4'((lat_count % 14'd100)  / 14'd10);
    wire [3:0] lat_dig0 = 4'(lat_count % 14'd10);

    localparam TXD_IDLE = 3'd0,
               TXD_LOAD = 3'd1,
               TXD_GAP  = 3'd2,   // 1-cycle: wait for tx_busy to assert
               TXD_WAIT = 3'd3;   // wait for byte to finish

    reg [22:0] tx_timer;
    reg  [2:0] tx_byte_idx;
    reg  [2:0] txd_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_timer    <= 23'd0;
            tx_byte_idx <= 3'd0;
            txd_state   <= TXD_IDLE;
            tx_start    <= 1'b0;
            tx_data     <= 8'd0;
        end else begin
            tx_start <= 1'b0;    // default: deasserted

            if (state != STOPPED) begin
                // Not stopped: reset timer so first TX fires quickly after stop
                tx_timer  <= 23'd0;
                txd_state <= TXD_IDLE;
            end else begin
                case (txd_state)
                    TXD_IDLE: begin
                        if (tx_timer == TX_PERIOD - 23'd1) begin
                            tx_timer    <= 23'd0;
                            tx_byte_idx <= 3'd0;
                            txd_state   <= TXD_LOAD;
                        end else
                            tx_timer <= tx_timer + 23'd1;
                    end

                    TXD_LOAD: begin
                        // Select byte for current index
                        case (tx_byte_idx)
                            3'd0: tx_data <= {4'h3, lat_dig3};  // '0'–'9'
                            3'd1: tx_data <= {4'h3, lat_dig2};
                            3'd2: tx_data <= {4'h3, lat_dig1};
                            3'd3: tx_data <= {4'h3, lat_dig0};
                            3'd4: tx_data <= 8'h0A;              // '\n'
                            default: tx_data <= 8'h0A;
                        endcase
                        tx_start  <= 1'b1;
                        txd_state <= TXD_GAP;
                    end

                    TXD_GAP: begin
                        // tx_busy has not asserted yet (1-cycle propagation)
                        txd_state <= TXD_WAIT;
                    end

                    TXD_WAIT: begin
                        if (!tx_busy) begin
                            if (tx_byte_idx == 3'd4)
                                txd_state <= TXD_IDLE;   // frame complete
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
    end

endmodule
