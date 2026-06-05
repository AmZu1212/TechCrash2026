// Challenge 9 Milestone 3: FPGA neural-network inference controller.
//
// FPGA -> ESP32 UART packets, 9600 8N1 on ARDUINO_IO[1]:
//   0xA5, TYPE, VALUE, CHECKSUM
//   TYPE 0x01 = reset training/inference event, VALUE = current difficulty
//   TYPE 0x02 = difficulty update, VALUE = SW[3:0]
//   TYPE 0x03 = mode update, VALUE bit0 = SW[8] inference mode
//   TYPE 0x04 = inference response, VALUE = {state_seq[6:0], flap}
//
// ESP32 -> FPGA UART packets, 9600 8N1 on ARDUINO_IO[0]:
//   weight: 0x5A, 0x10, index, signed_q4_4_value, CHECKSUM
//   load:   0x5A, 0x11, 0x00, 25, CHECKSUM
//   state:  0x5A, 0x20, seq, in0, in1, in2, in3, CHECKSUM
//   CHECKSUM is XOR of all previous bytes in the packet.

module flappy_bird_part_3_top (
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

    localparam FP_SYNC  = 8'hA5;
    localparam FP_RESET = 8'h01;
    localparam FP_DIFF  = 8'h02;
    localparam FP_MODE  = 8'h03;
    localparam FP_INFER = 8'h04;

    localparam ESP_SYNC   = 8'h5A;
    localparam ESP_WEIGHT = 8'h10;
    localparam ESP_LOAD   = 8'h11;
    localparam ESP_STATE  = 8'h20;
    localparam signed [19:0] NN_FLAP_THRESHOLD = 20'sd103; // logit threshold for ESP32 sigmoid > 0.55

    wire clk = MAX10_CLK1_50;
    wire rst_n = SW[9] & KEY[1];

    // ---- Arduino UART wiring ----
    wire uart_rx_pin = ARDUINO_IO[0];
    wire uart_tx_pin;
    assign ARDUINO_IO[0]    = 1'bz;
    assign ARDUINO_IO[1]    = uart_tx_pin;
    assign ARDUINO_IO[15:2] = 14'bz;
    assign ARDUINO_RESET_N  = 1'bz;

    wire [3:0] difficulty = SW[3:0];
    wire       inference_mode = SW[8];

    reg  [3:0] difficulty_prev;
    reg        mode_prev;
    reg        pending_diff;
    reg        pending_mode;
    reg        pending_reset;
    reg        pending_infer;

    reg        packet_accepted_diff;
    reg        packet_accepted_mode;
    reg        packet_accepted_reset;
    reg        packet_accepted_infer;

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

    wire reset_press = key_debounced_prev & ~key_debounced;

    // ---- UART RX from ESP32 ----
    wire [7:0] rx_data;
    wire       rx_valid;

    uart_rx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD     (UART_BAUD)
    ) u_uart_rx (
        .clk      (clk),
        .rst_n    (rst_n),
        .rx       (uart_rx_pin),
        .rx_data  (rx_data),
        .rx_valid (rx_valid)
    );

    reg signed [7:0] nn_weight [0:24];
    reg signed [7:0] state_input [0:3];
    reg [6:0]        state_seq;
    reg [6:0]        response_seq;
    reg [4:0]        loaded_weights;
    reg              rx_toggle;
    reg              state_update_toggle;
    reg              infer_done_toggle;
    reg              infer_flap_reg;

    reg [2:0] rx_state;
    reg [2:0] rx_count;
    reg [2:0] rx_expected;
    reg [7:0] rx_type;
    reg [7:0] rx_checksum;
    reg [7:0] rx_buf0;
    reg [7:0] rx_buf1;
    reg [7:0] rx_buf2;
    reg [7:0] rx_buf3;
    reg [7:0] rx_buf4;

    localparam RX_WAIT_SYNC = 3'd0;
    localparam RX_READ_TYPE = 3'd1;
    localparam RX_PAYLOAD   = 3'd2;
    localparam RX_CHECKSUM  = 3'd3;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nn_weight[0]  <= 8'sd0;
            nn_weight[1]  <= 8'sd0;
            nn_weight[2]  <= 8'sd0;
            nn_weight[3]  <= 8'sd0;
            nn_weight[4]  <= 8'sd0;
            nn_weight[5]  <= 8'sd0;
            nn_weight[6]  <= 8'sd0;
            nn_weight[7]  <= 8'sd0;
            nn_weight[8]  <= 8'sd0;
            nn_weight[9]  <= 8'sd0;
            nn_weight[10] <= 8'sd0;
            nn_weight[11] <= 8'sd0;
            nn_weight[12] <= 8'sd0;
            nn_weight[13] <= 8'sd0;
            nn_weight[14] <= 8'sd0;
            nn_weight[15] <= 8'sd0;
            nn_weight[16] <= 8'sd0;
            nn_weight[17] <= 8'sd0;
            nn_weight[18] <= 8'sd0;
            nn_weight[19] <= 8'sd0;
            nn_weight[20] <= 8'sd0;
            nn_weight[21] <= 8'sd0;
            nn_weight[22] <= 8'sd0;
            nn_weight[23] <= 8'sd0;
            nn_weight[24] <= 8'sd0;
            state_input[0] <= 8'sd0;
            state_input[1] <= 8'sd0;
            state_input[2] <= 8'sd0;
            state_input[3] <= 8'sd0;
            state_seq      <= 7'd0;
            loaded_weights <= 5'd0;
            rx_toggle      <= 1'b0;
            state_update_toggle <= 1'b0;
            rx_state       <= RX_WAIT_SYNC;
            rx_count       <= 3'd0;
            rx_expected    <= 3'd0;
            rx_type        <= 8'd0;
            rx_checksum    <= 8'd0;
            rx_buf0        <= 8'd0;
            rx_buf1        <= 8'd0;
            rx_buf2        <= 8'd0;
            rx_buf3        <= 8'd0;
            rx_buf4        <= 8'd0;
        end else if (rx_valid) begin
            case (rx_state)
                RX_WAIT_SYNC: begin
                    if (rx_data == ESP_SYNC) begin
                        rx_checksum <= ESP_SYNC;
                        rx_state    <= RX_READ_TYPE;
                    end
                end

                RX_READ_TYPE: begin
                    rx_type     <= rx_data;
                    rx_checksum <= rx_checksum ^ rx_data;
                    rx_count    <= 3'd0;
                    if (rx_data == ESP_WEIGHT || rx_data == ESP_LOAD) begin
                        rx_expected <= 3'd2;
                        rx_state    <= RX_PAYLOAD;
                    end else if (rx_data == ESP_STATE) begin
                        rx_expected <= 3'd5;
                        rx_state    <= RX_PAYLOAD;
                    end else begin
                        rx_state    <= RX_WAIT_SYNC;
                    end
                end

                RX_PAYLOAD: begin
                    case (rx_count)
                        3'd0: rx_buf0 <= rx_data;
                        3'd1: rx_buf1 <= rx_data;
                        3'd2: rx_buf2 <= rx_data;
                        3'd3: rx_buf3 <= rx_data;
                        3'd4: rx_buf4 <= rx_data;
                        default: rx_buf0 <= rx_buf0;
                    endcase
                    rx_checksum <= rx_checksum ^ rx_data;
                    if (rx_count == rx_expected - 3'd1)
                        rx_state <= RX_CHECKSUM;
                    else
                        rx_count <= rx_count + 3'd1;
                end

                RX_CHECKSUM: begin
                    if (rx_data == rx_checksum) begin
                        rx_toggle <= ~rx_toggle;
                        if (rx_type == ESP_LOAD) begin
                            loaded_weights <= 5'd0;
                        end else if (rx_type == ESP_WEIGHT) begin
                            if (rx_buf0 < 8'd25) begin
                                nn_weight[rx_buf0[4:0]] <= rx_buf1;
                                if (loaded_weights < 5'd25)
                                    loaded_weights <= loaded_weights + 5'd1;
                            end
                        end else if (rx_type == ESP_STATE) begin
                            state_seq      <= rx_buf0[6:0];
                            state_input[0] <= rx_buf1;
                            state_input[1] <= rx_buf2;
                            state_input[2] <= rx_buf3;
                            state_input[3] <= rx_buf4;
                            state_update_toggle <= ~state_update_toggle;
                        end
                    end
                    rx_state <= RX_WAIT_SYNC;
                end

                default: rx_state <= RX_WAIT_SYNC;
            endcase
        end
    end

    // ---- Fixed-point 4-4-1 neural network inference ----
    function automatic signed [7:0] hard_tanh_q2_5(input signed [19:0] value);
        begin
            if (value > 20'sd32)
                hard_tanh_q2_5 = 8'sd32;
            else if (value < -20'sd32)
                hard_tanh_q2_5 = -8'sd32;
            else
                hard_tanh_q2_5 = value[7:0];
        end
    endfunction

    reg signed [7:0] work_input [0:3];
    reg signed [7:0] hidden [0:3];
    reg signed [19:0] infer_acc;
    reg [4:0] infer_phase;
    reg infer_busy;
    reg state_update_seen_infer;

    wire [1:0] hidden_idx = infer_phase[3:2];
    wire [1:0] input_idx = infer_phase[1:0];
    wire signed [7:0] mac_weight = (infer_phase < 5'd16)
                                 ? nn_weight[infer_phase]
                                 : nn_weight[5'd20 + infer_phase[1:0]];
    wire signed [7:0] mac_input = (infer_phase < 5'd16)
                                ? work_input[input_idx]
                                : hidden[infer_phase[1:0]];
    wire signed [15:0] mac_product = mac_weight * mac_input;
    wire signed [19:0] mac_product_ext = {{4{mac_product[15]}}, mac_product};
    wire signed [19:0] hidden_bias_ext = {{12{nn_weight[5'd16 + hidden_idx][7]}}, nn_weight[5'd16 + hidden_idx]} <<< 5;
    wire signed [19:0] output_bias_ext = {{12{nn_weight[24][7]}}, nn_weight[24]} <<< 5;
    wire signed [19:0] next_hidden_acc = (input_idx == 2'd0)
                                       ? (hidden_bias_ext + mac_product_ext)
                                       : (infer_acc + mac_product_ext);
    wire signed [19:0] next_output_acc = (infer_phase == 5'd16)
                                       ? (output_bias_ext + mac_product_ext)
                                       : (infer_acc + mac_product_ext);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            work_input[0] <= 8'sd0;
            work_input[1] <= 8'sd0;
            work_input[2] <= 8'sd0;
            work_input[3] <= 8'sd0;
            hidden[0] <= 8'sd0;
            hidden[1] <= 8'sd0;
            hidden[2] <= 8'sd0;
            hidden[3] <= 8'sd0;
            response_seq <= 7'd0;
            infer_done_toggle <= 1'b0;
            infer_flap_reg <= 1'b0;
            infer_acc <= 20'sd0;
            infer_phase <= 5'd0;
            infer_busy <= 1'b0;
            state_update_seen_infer <= 1'b0;
        end else begin
            if (!infer_busy && (state_update_seen_infer != state_update_toggle)) begin
                state_update_seen_infer <= state_update_toggle;
                work_input[0] <= state_input[0];
                work_input[1] <= state_input[1];
                work_input[2] <= state_input[2];
                work_input[3] <= state_input[3];
                response_seq <= state_seq;
                infer_phase <= 5'd0;
                infer_acc <= 20'sd0;
                infer_busy <= 1'b1;
            end else if (infer_busy) begin
                if (infer_phase < 5'd16) begin
                    infer_acc <= next_hidden_acc;
                    if (input_idx == 2'd3)
                        hidden[hidden_idx] <= hard_tanh_q2_5(next_hidden_acc >>> 4);
                    infer_phase <= infer_phase + 5'd1;
                end else begin
                    infer_acc <= next_output_acc;
                    if (infer_phase == 5'd19) begin
                        infer_flap_reg <= inference_mode && (loaded_weights == 5'd25) && (next_output_acc > NN_FLAP_THRESHOLD);
                        infer_done_toggle <= ~infer_done_toggle;
                        infer_busy <= 1'b0;
                    end else begin
                        infer_phase <= infer_phase + 5'd1;
                    end
                end
            end
        end
    end

    // ---- Difficulty/mode/reset packet scheduling ----
    reg [24:0] refresh_cnt;
    reg        infer_done_seen;
    wire refresh_tick = (refresh_cnt == 25'd24_999_999);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refresh_cnt     <= 25'd0;
            difficulty_prev <= 4'd0;
            mode_prev       <= 1'b0;
            pending_diff    <= 1'b1;
            pending_mode    <= 1'b1;
            pending_reset   <= 1'b0;
            pending_infer   <= 1'b0;
            infer_done_seen <= 1'b0;
        end else begin
            if (refresh_tick)
                refresh_cnt <= 25'd0;
            else
                refresh_cnt <= refresh_cnt + 25'd1;

            if (difficulty != difficulty_prev) begin
                difficulty_prev <= difficulty;
                pending_diff    <= 1'b1;
            end

            if (inference_mode != mode_prev) begin
                mode_prev     <= inference_mode;
                pending_mode  <= 1'b1;
            end

            if (refresh_tick) begin
                pending_diff <= 1'b1;
                pending_mode <= 1'b1;
            end

            if (reset_press)
                pending_reset <= 1'b1;

            if (infer_done_seen != infer_done_toggle) begin
                infer_done_seen <= infer_done_toggle;
                pending_infer   <= 1'b1;
            end

            if (packet_accepted_reset)
                pending_reset <= 1'b0;
            if (packet_accepted_diff)
                pending_diff <= 1'b0;
            if (packet_accepted_mode)
                pending_mode <= 1'b0;
            if (packet_accepted_infer)
                pending_infer <= 1'b0;
        end
    end

    // ---- UART TX to ESP32 ----
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
    reg       tx_toggle;

    localparam TX_IDLE = 3'd0;
    localparam TX_LOAD = 3'd1;
    localparam TX_GAP  = 3'd2;
    localparam TX_WAIT = 3'd3;

    wire [7:0] pkt_checksum = FP_SYNC ^ pkt_type ^ pkt_value;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state              <= TX_IDLE;
            byte_idx              <= 2'd0;
            pkt_type              <= 8'd0;
            pkt_value             <= 8'd0;
            tx_data               <= 8'd0;
            tx_start              <= 1'b0;
            packet_accepted_reset <= 1'b0;
            packet_accepted_diff  <= 1'b0;
            packet_accepted_mode  <= 1'b0;
            packet_accepted_infer <= 1'b0;
            tx_toggle             <= 1'b0;
        end else begin
            tx_start              <= 1'b0;
            packet_accepted_reset <= 1'b0;
            packet_accepted_diff  <= 1'b0;
            packet_accepted_mode  <= 1'b0;
            packet_accepted_infer <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    if (pending_reset) begin
                        pkt_type              <= FP_RESET;
                        pkt_value             <= {4'd0, difficulty};
                        byte_idx              <= 2'd0;
                        packet_accepted_reset <= 1'b1;
                        tx_toggle             <= ~tx_toggle;
                        tx_state              <= TX_LOAD;
                    end else if (pending_diff) begin
                        pkt_type             <= FP_DIFF;
                        pkt_value            <= {4'd0, difficulty};
                        byte_idx             <= 2'd0;
                        packet_accepted_diff <= 1'b1;
                        tx_toggle            <= ~tx_toggle;
                        tx_state             <= TX_LOAD;
                    end else if (pending_mode) begin
                        pkt_type             <= FP_MODE;
                        pkt_value            <= {7'd0, inference_mode};
                        byte_idx             <= 2'd0;
                        packet_accepted_mode <= 1'b1;
                        tx_toggle            <= ~tx_toggle;
                        tx_state             <= TX_LOAD;
                    end else if (pending_infer) begin
                        pkt_type              <= FP_INFER;
                        pkt_value             <= {response_seq, infer_flap_reg};
                        byte_idx              <= 2'd0;
                        packet_accepted_infer <= 1'b1;
                        tx_toggle             <= ~tx_toggle;
                        tx_state              <= TX_LOAD;
                    end
                end

                TX_LOAD: begin
                    if (!tx_busy) begin
                        case (byte_idx)
                            2'd0: tx_data <= FP_SYNC;
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
    seven_segment seg0 (.value(difficulty),                  .blank(1'b0), .seg(HEX0));
    seven_segment seg1 (.value(4'hD),                        .blank(1'b0), .seg(HEX1));
    seven_segment seg2 (.value(inference_mode ? 4'hA : 4'h0), .blank(1'b0), .seg(HEX2));
    seven_segment seg3 (.value((loaded_weights == 5'd25) ? 4'hF : loaded_weights[3:0]), .blank(1'b0), .seg(HEX3));
    assign HEX4 = 8'hFF;
    assign HEX5 = 8'hFF;

    assign LEDR[3:0] = difficulty;
    assign LEDR[4]   = inference_mode;
    assign LEDR[5]   = infer_flap_reg;
    assign LEDR[6]   = tx_busy;
    assign LEDR[7]   = rx_toggle ^ tx_toggle;
    assign LEDR[8]   = (loaded_weights == 5'd25);
    assign LEDR[9]   = rst_n;

endmodule
