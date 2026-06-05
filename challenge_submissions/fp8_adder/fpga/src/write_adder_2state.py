"""Regenerate fp8_adder.v as 2-state arithmetic design (no LUT)."""

code = r"""// ============================================================================
// FP8 E4M3 Adder -- 2-State Design, Unsigned-Only Critical Path
// ============================================================================
// S_IDLE  : when start=1, decode a/b + compute signed sum combinationally,
//           latch sum_neg/sum_mag (or special result). One clock.
// S_ENCODE: fp8_encode(sum_neg, sum_mag) -> result; done=1 for 1 cycle.
//           Returns to IDLE immediately.
//
// TC cycle breakdown (per test):
//   FETCH(1)+WAIT_MEM(1)+LAUNCH(1)+WAIT_ADD(3)+CHECK(1)+NEXT(1) = 8 cycles
// 4096*8/50MHz = 655 us
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

    localparam S_IDLE   = 1'b0;
    localparam S_ENCODE = 1'b1;

    reg        state;
    reg        special_valid;
    reg [7:0]  special_result;

    // Pipeline register: signed sum in unsigned magnitude + sign-bit form
    reg        sum_neg;
    reg [18:0] sum_mag;

    // ---- priority-encoder log2 (18-bit input) ------------------------------
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

    // ---- fp8 -> unsigned magnitude and sign --------------------------------
    // Returns {sign, magnitude[17:0]} as 19-bit packed result
    function [18:0] fp8_to_mag;
        input [7:0] fp;
        reg [3:0] exp_f;
        reg [3:0] man_f;
        reg [17:0] mag;
        begin
            exp_f = fp[6:3];
            man_f = {1'b0, fp[2:0]};
            if (exp_f == 4'd0)
                mag = {15'd0, fp[2:0]};
            else
                mag = ({11'd0, (4'd8 + man_f)} << (exp_f - 4'd1));
            fp8_to_mag = {fp[7], mag};
        end
    endfunction

    // ---- Compute signed sum magnitude from two fp8 magnitudes/signs --------
    // Returns {neg, magnitude[18:0]} in 20-bit packed form
    function [19:0] signed_sum;
        input [18:0] a_packed;
        input [18:0] b_packed;
        reg a_neg, b_neg;
        reg [17:0] a_mag, b_mag;
        reg result_neg;
        reg [18:0] result_mag;
        begin
            a_neg = a_packed[18];
            a_mag = a_packed[17:0];
            b_neg = b_packed[18];
            b_mag = b_packed[17:0];

            if (a_neg == b_neg) begin
                result_neg = a_neg;
                result_mag = {1'b0, a_mag} + {1'b0, b_mag};
            end else begin
                if (a_mag >= b_mag) begin
                    result_neg = a_neg;
                    result_mag = {1'b0, a_mag} - {1'b0, b_mag};
                end else begin
                    result_neg = b_neg;
                    result_mag = {1'b0, b_mag} - {1'b0, a_mag};
                end
            end
            signed_sum = {result_neg, result_mag};
        end
    endfunction

    // ---- Encode magnitude + sign into FP8 ----------------------------------
    function [7:0] fp8_encode;
        input        neg;
        input [18:0] mag;
        reg [4:0] eb;
        reg [4:0] sh;
        reg [18:0] ba;
        reg [18:0] rm;
        reg [18:0] hf;
        begin
            if (mag == 19'd0) begin
                fp8_encode = 8'h00;
            end else if (mag > 19'd229376) begin
                fp8_encode = {neg, 7'h7E};
            end else if (mag < 19'd8) begin
                fp8_encode = {neg, 1'b0, 3'b000, mag[2:0]};
            end else begin
                eb = fast_log2(mag[17:0]) - 5'd2;
                sh = eb - 5'd1;
                ba = mag >> sh;

                if (sh > 5'd0) begin
                    rm = mag - (ba << sh);
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
                    fp8_encode = {neg, 7'h7E};
                end else if ((eb == 5'd15) && (ba[3:0] == 4'd15)) begin
                    fp8_encode = {neg, 7'h7E};
                end else begin
                    fp8_encode = {neg, eb[3:0], ba[2:0]};
                end
            end
        end
    endfunction

    // ---- Wire: compute sum from a/b inputs directly ------------------------
    wire [18:0] a_pack_w, b_pack_w;
    wire [19:0] sum_w;
    assign a_pack_w = fp8_to_mag(a);
    assign b_pack_w = fp8_to_mag(b);
    assign sum_w    = signed_sum(a_pack_w, b_pack_w);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            special_valid  <= 1'b0;
            special_result <= 8'd0;
            sum_neg        <= 1'b0;
            sum_mag        <= 19'd0;
            result         <= 8'd0;
            done           <= 1'b0;
            busy           <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        if (((a[6:3] == 4'hF) && (a[2:0] == 3'h7)) ||
                            ((b[6:3] == 4'hF) && (b[2:0] == 3'h7))) begin
                            special_valid  <= 1'b1;
                            special_result <= 8'h7F;
                            sum_neg        <= 1'b0;
                            sum_mag        <= 19'd0;
                        end else if ((a[6:0] == 7'd0) && (b[6:0] == 7'd0)) begin
                            special_valid  <= 1'b1;
                            special_result <= (a[7] && b[7]) ? 8'h80 : 8'h00;
                            sum_neg        <= 1'b0;
                            sum_mag        <= 19'd0;
                        end else begin
                            special_valid  <= 1'b0;
                            special_result <= 8'h00;
                            sum_neg        <= sum_w[19];
                            sum_mag        <= sum_w[18:0];
                        end
                        busy  <= 1'b1;
                        state <= S_ENCODE;
                    end
                end

                S_ENCODE: begin
                    result <= special_valid ? special_result : fp8_encode(sum_neg, sum_mag);
                    done   <= 1'b1;
                    busy   <= 1'b0;
                    state  <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
"""

out_path = r'c:\Users\Administrator\Desktop\Hackathon 2026\Our Fork\TechCrash2026\challenge_submissions\fp8_adder\fpga\src\fp8_adder.v'
with open(out_path, 'w') as f:
    f.write(code)
print(f"Written: {out_path} ({len(code)} bytes)")
