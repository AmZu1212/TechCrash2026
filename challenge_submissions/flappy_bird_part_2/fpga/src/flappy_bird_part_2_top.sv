// Challenge 9 Milestone 2: FPGA difficulty/debug controller.
//
// FPGA -> ESP32 UART packet, 9600 8N1 on ARDUINO_IO[1]:
//   0xA5, TYPE, VALUE, CHECKSUM
//   TYPE 0x01 = finish/save current generation event, VALUE = current difficulty
//   TYPE 0x02 = difficulty update, VALUE = SW[3:0]
//   CHECKSUM = 0xA5 ^ TYPE ^ VALUE

module flappy_bird_part_2_top (
    input           MAX10_CLK1_50,
    input   [9:0]   SW,
    input   [1:0]   KEY,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout   [15:0]  ARDUINO_IO,
    inout           ARDUINO_RESET_N
);

    localparam CLK_FREQ = 50_000_000;
    localparam UART_BAUD = 9600;

    localparam PKT_SYNC = 8'hA5;
    localparam PKT_FLAP = 8'h01;
    localparam PKT_DIFF = 8'h02;

    wire clk = MAX10_CLK1_50;
    wire rst_n = SW[9] & KEY[1];

    // ---- Arduino UART wiring ----
    wire uart_tx_pin;
    assign ARDUINO_IO[0]    = 1'bz;
    assign ARDUINO_IO[1]    = uart_tx_pin;
    assign ARDUINO_IO[15:2] = 14'bz;
    assign ARDUINO_RESET_N  = 1'bz;

    // ---- Difficulty ----
    wire [3:0] difficulty = SW[3:0];
    reg  [3:0] difficulty_prev;
    reg        pending_diff;
    reg        pending_flap;

    // ---- KEY[0] synchronizer and 20 ms debounce ----
    reg key_s1, key_s2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_s1 <= 1'b1;
            key_s2 <= 1'b1;
        end else begin
            key_s1 <= KEY[0];
            key_s2 <= key_s1;
        end
    end

    reg [19:0] debounce_cnt;
    reg        key_debounced;
    reg        key_debounced_prev;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            debounce_cnt       <= 20'd0;
            key_debounced      <= 1'b1;
            key_debounced_prev <= 1'b1;
        end else begin
            key_debounced_prev <= key_debounced;

            if (key_s2 != key_debounced) begin
                if (debounce_cnt == 20'd999_999) begin
                    key_debounced <= key_s2;
                    debounce_cnt  <= 20'd0;
                end else begin
                    debounce_cnt <= debounce_cnt + 20'd1;
                end
            end else begin
                debounce_cnt <= 20'd0;
            end
        end
    end

    wire flap_press = key_debounced_prev & ~key_debounced;

    // ---- Periodic difficulty refresh every 500 ms ----
    reg [24:0] refresh_cnt;
    wire refresh_tick = (refresh_cnt == 25'd24_999_999);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refresh_cnt     <= 25'd0;
            difficulty_prev <= 4'd0;
            pending_diff    <= 1'b1;
            pending_flap    <= 1'b0;
        end else begin
            if (refresh_tick)
                refresh_cnt <= 25'd0;
            else
                refresh_cnt <= refresh_cnt + 25'd1;

            if (difficulty != difficulty_prev) begin
                difficulty_prev <= difficulty;
                pending_diff    <= 1'b1;
            end

            if (refresh_tick) begin
                pending_diff <= 1'b1;
            end

            if (flap_press) begin
                pending_flap <= 1'b1;
            end

            if (packet_accepted_flap)
                pending_flap <= 1'b0;
            if (packet_accepted_diff)
                pending_diff <= 1'b0;
        end
    end

    // ---- UART TX and packet sender ----
    logic [7:0] tx_data;
    logic       tx_start;
    wire        tx_busy;

    uart_tx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD     (UART_BAUD)
    ) u_uart_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (tx_data),
        .tx_start (tx_start),
        .tx       (uart_tx_pin),
        .tx_busy  (tx_busy)
    );

    reg [2:0] tx_state;
    reg [1:0] byte_idx;
    reg [7:0] pkt_type;
    reg [7:0] pkt_value;
    reg       packet_accepted_flap;
    reg       packet_accepted_diff;
    reg       tx_toggle;

    localparam TX_IDLE = 3'd0;
    localparam TX_LOAD = 3'd1;
    localparam TX_GAP  = 3'd2;
    localparam TX_WAIT = 3'd3;

    wire [7:0] pkt_checksum = PKT_SYNC ^ pkt_type ^ pkt_value;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state             <= TX_IDLE;
            byte_idx             <= 2'd0;
            pkt_type             <= 8'd0;
            pkt_value            <= 8'd0;
            tx_data              <= 8'd0;
            tx_start             <= 1'b0;
            packet_accepted_flap <= 1'b0;
            packet_accepted_diff <= 1'b0;
            tx_toggle            <= 1'b0;
        end else begin
            tx_start             <= 1'b0;
            packet_accepted_flap <= 1'b0;
            packet_accepted_diff <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    if (pending_flap) begin
                        pkt_type             <= PKT_FLAP;
                        pkt_value            <= {4'd0, difficulty};
                        byte_idx             <= 2'd0;
                        packet_accepted_flap <= 1'b1;
                        tx_toggle            <= ~tx_toggle;
                        tx_state             <= TX_LOAD;
                    end else if (pending_diff) begin
                        pkt_type             <= PKT_DIFF;
                        pkt_value            <= {4'd0, difficulty};
                        byte_idx             <= 2'd0;
                        packet_accepted_diff <= 1'b1;
                        tx_toggle            <= ~tx_toggle;
                        tx_state             <= TX_LOAD;
                    end
                end

                TX_LOAD: begin
                    if (!tx_busy) begin
                        case (byte_idx)
                            2'd0: tx_data <= PKT_SYNC;
                            2'd1: tx_data <= pkt_type;
                            2'd2: tx_data <= pkt_value;
                            2'd3: tx_data <= pkt_checksum;
                            default: tx_data <= 8'd0;
                        endcase
                        tx_start <= 1'b1;
                        tx_state <= TX_GAP;
                    end
                end

                TX_GAP: begin
                    tx_state <= TX_WAIT;
                end

                TX_WAIT: begin
                    if (!tx_busy) begin
                        if (byte_idx == 2'd3) begin
                            tx_state <= TX_IDLE;
                        end else begin
                            byte_idx <= byte_idx + 2'd1;
                            tx_state <= TX_LOAD;
                        end
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    // ---- Display and LEDs ----
    seven_segment seg0 (.value(difficulty), .blank(1'b0), .seg(HEX0));
    seven_segment seg1 (.value(4'hD),       .blank(1'b0), .seg(HEX1));
    assign HEX2 = 8'hFF;
    assign HEX3 = 8'hFF;
    assign HEX4 = 8'hFF;
    assign HEX5 = 8'hFF;

    assign LEDR[3:0] = difficulty;
    assign LEDR[4]   = pending_diff;
    assign LEDR[5]   = pending_flap;
    assign LEDR[6]   = tx_busy;
    assign LEDR[7]   = tx_toggle;
    assign LEDR[8]   = ~key_debounced;
    assign LEDR[9]   = rst_n;

endmodule
