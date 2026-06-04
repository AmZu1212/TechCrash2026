"""Write optimized fp8_adder.v using signed fixed-width types (not integer) for timing closure."""

content = r"""
// ============================================================================
// FP8 E4M3 Adder -- 3-Cycle Pipelined, Fixed-Width Signed Arithmetic
// ============================================================================
// Uses signed [19:0] instead of `integer` for sum_scaled to close timing.
// Max fp8_to_scaled magnitude: (8+7)<<14 = 245760 (< 2^18), needs 19-bit signed.
// Sum of two: range [-491520, +491520], fits in signed [19:0] (max 2^19-1 = 524287).
//
// Pipeline: S_PREP (1) -> S_ENCODE (1) -> S_DONE (1) = 3 cycles/add
// ============================================================================

module fp8_adder (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] a,
    input  wire [7:0] b,
    output reg  [7:0] result,
    output reg        done,
    output reg        busy
);

    localparam S_IDLE   = 2'd0;
    localparam S_PREP   = 2'd1;
    localparam S_ENCODE = 2'd2;
    localparam S_DONE   = 2'd3;

    reg [1:0]         state;
    reg [7:0]         a_reg, b_reg;
    reg               special_valid;
    reg [7:0]         special_result;
    reg signed [19:0] sum_scaled_reg;

    // ---- fast priority-encoder log2 (18-bit input) -------------------------
    function [4:0] fast_log2;
        input [17:0] v;
        begin
            casez (v)
                18'b1?????????????????: fast_log2 = 5'd17;
                18'b01????????????????: fast_log2 = 5'd16;
                18'b001???????????????: fast_log2 = 5'd15;
                18'b0001??????????????: fast_log2 = 5'd14;
                18'b00001?????????????: fast_log2 = 5'd13;
                18'b000001????????????: fast_log2 = 5'd12;
                18'b0000001???????????: fast_log2 = 5'd11;
                18'b00000001??????????: fast_log2 = 5'd10;
                18'b000000001?????????: fast_log2 = 5'd9;
                18'b0000000001????????: fast_log2 = 5'd8;
                18'b00000000001???????: fast_log2 = 5'd7;
                18'b000000000001??????: fast_log2 = 5'd6;
                18'b0000000000001?????: fast_log2 = 5'd5;
                18'b00000000000001????: fast_log2 = 5'd4;
                18'b000000000000001???: fast_log2 = 5'd3;
                18'b0000000000000001??: fast_log2 = 5'd2;
                18'b00000000000000001?: fast_log2 = 5'd1;
                default:               fast_log2 = 5'd0;
            endcase
        end
    endfunction

    // ---- FP8 -> signed 20-bit scaled integer ------------------------------
    // Max magnitude: (8+7) << (15-1) = 15 << 14 = 245760
    function signed [19:0] fp8_to_scaled;
        input [7:0] fp;
        reg [3:0]  exp_f;
        reg [3:0]  man_f;
        reg [17:0] mag;
        begin
            exp_f = fp[6:3];
            man_f = {1'b0, fp[2:0]};
            if (exp_f == 4'd0)
                mag = {15'd0, fp[2:0]};
            else
                mag = {11'd0, (4'd8 + man_f)} << (exp_f - 4'd1);
            if (fp[7])
                fp8_to_scaled = -$signed({2'b00, mag});
            else
                fp8_to_scaled = $signed({2'b00, mag});
        end
    endfunction

    // ---- Encode signed 20-bit scaled integer back to FP8 ------------------
    function [7:0] fp8_from_sum;
        input signed [19:0] ss;
        reg        sb;
        reg [18:0] av;
        reg [4:0]  eb;
        reg [4:0]  sh;
        reg [18:0] ba;
        reg [18:0] rm;
        reg [18:0] hf;
        begin
            if (ss == 20'sh0) begin
                fp8_from_sum = 8'h00;
            end else begin
                if (ss[19]) begin
                    sb = 1'b1;
                    av = (~ss[18:0]) + 19'd1;  // two's complement negate
                end else begin
                    sb = 1'b0;
                    av = ss[18:0];
                end

                if (av > 19'd229376) begin
                    fp8_from_sum = {sb, 7'h7E};
                end else if (av < 19'd8) begin
                    fp8_from_sum = {sb, 1'b0, 3'b000, av[2:0]};
                end else begin
                    eb = fast_log2(av[17:0]) - 5'd2;
                    sh = eb - 5'd1;
                    ba = av >> sh;

                    if (sh > 5'd0) begin
                        rm = av - (ba << sh);
                        hf = 19'd1 << (sh - 5'd1);
                        if (rm > hf)
                            ba = ba + 19'd1;
                        else if ((rm == hf) && ba[0])
                            ba = ba + 19'd1;
                    end

                    if (ba >= 19'd16) begin
                        ba = 19'd8;
                        eb = eb + 5'd1;
                    end

                    if (eb > 5'd15) begin
                        fp8_from_sum = {sb, 7'h7E};
                    end else if ((eb == 5'd15) && (ba[3:0] == 4'd15)) begin
                        fp8_from_sum = {sb, 7'h7E};
                    end else begin
                        fp8_from_sum = {sb, eb[3:0], (ba[3:0] - 4'd8)};
                    end
                end
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            a_reg          <= 8'd0;
            b_reg          <= 8'd0;
            special_valid  <= 1'b0;
            special_result <= 8'd0;
            sum_scaled_reg <= 20'sh0;
            result         <= 8'd0;
            done           <= 1'b0;
            busy           <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        a_reg <= a;
                        b_reg <= b;
                        busy  <= 1'b1;
                        state <= S_PREP;
                    end
                end

                S_PREP: begin
                    if (((a_reg[6:3] == 4'hF) && (a_reg[2:0] == 3'h7)) ||
                        ((b_reg[6:3] == 4'hF) && (b_reg[2:0] == 3'h7))) begin
                        special_valid  <= 1'b1;
                        special_result <= 8'h7F;
                        sum_scaled_reg <= 20'sh0;
                    end else if ((a_reg[6:0] == 7'd0) && (b_reg[6:0] == 7'd0)) begin
                        special_valid  <= 1'b1;
                        special_result <= (a_reg[7] && b_reg[7]) ? 8'h80 : 8'h00;
                        sum_scaled_reg <= 20'sh0;
                    end else begin
                        special_valid  <= 1'b0;
                        special_result <= 8'h00;
                        sum_scaled_reg <= fp8_to_scaled(a_reg) + fp8_to_scaled(b_reg);
                    end
                    state <= S_ENCODE;
                end

                S_ENCODE: begin
                    result <= special_valid ? special_result : fp8_from_sum(sum_scaled_reg);
                    state  <= S_DONE;
                end

                S_DONE: begin
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
"""

out_path = r'c:\Users\Administrator\Desktop\Hackathon 2026\Our Fork\TechCrash2026\challenge_submissions\fp8_adder\fpga\src\fp8_adder.v'
with open(out_path, 'w') as f:
    f.write(content.lstrip('\n'))
print('wrote', len(content.lstrip('\n')), 'bytes')
