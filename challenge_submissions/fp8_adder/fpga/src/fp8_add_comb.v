// ============================================================================
// FP8 E4M3 Adder -- Pure Combinational Core
// ============================================================================
// Ported directly from the reference fp8_adder.v functions (fp8_to_scaled,
// fp8_from_sum, floor_log2) -- same algorithm, made combinational.
// Quartus synthesizes integer arithmetic in always @(*) as combinational logic.
// ============================================================================

module fp8_add_comb (
    input  wire [7:0] a,
    input  wire [7:0] b,
    output reg  [7:0] result
);

    // ---- floor_log2: index of highest set bit --------------------------------
    function integer floor_log2;
        input integer value;
        integer bit_idx;
        begin
            floor_log2 = 0;
            for (bit_idx = 0; bit_idx < 31; bit_idx = bit_idx + 1)
                if ((value >> bit_idx) != 0)
                    floor_log2 = bit_idx;
        end
    endfunction

    // ---- fp8_to_scaled: FP8 -> signed integer (1 ulp = 2^-3 * 2^1) --------
    // Normal:  scaled = (8 + man) << (exp - 1)
    // Denorm:  scaled = man
    // Negated if sign bit set.
    function integer fp8_to_scaled;
        input [7:0] value;
        integer exp_field, man_field;
        begin
            exp_field = value[6:3];
            man_field = value[2:0];
            if (exp_field == 0)
                fp8_to_scaled = man_field;
            else
                fp8_to_scaled = (8 + man_field) << (exp_field - 1);
            if (value[7])
                fp8_to_scaled = -fp8_to_scaled;
        end
    endfunction

    // ---- fp8_from_sum: signed integer -> FP8 (round-to-nearest-even) -------
    function [7:0] fp8_from_sum;
        input integer sum_scaled;
        integer abs_scaled, sign_bit, exp_biased, shift, base, rem, half, man_int;
        begin
            abs_scaled = 0; sign_bit = 0; exp_biased = 0;
            shift = 0; base = 0; rem = 0; half = 0; man_int = 0;
            fp8_from_sum = 8'h00;

            if (sum_scaled == 0) begin
                fp8_from_sum = 8'h00;
            end else begin
                if (sum_scaled < 0) begin
                    sign_bit   = 1;
                    abs_scaled = -sum_scaled;
                end else begin
                    abs_scaled = sum_scaled;
                end

                if (abs_scaled > 229376) begin
                    // Overflow -> max finite (saturate)
                    fp8_from_sum = (sign_bit ? 8'h80 : 8'h00) | 8'h7E;
                end else if (abs_scaled < 8) begin
                    // Denormal
                    man_int = abs_scaled;
                    fp8_from_sum = (sign_bit ? 8'h80 : 8'h00) | man_int[7:0];
                end else begin
                    // Normal
                    exp_biased = floor_log2(abs_scaled) - 2;
                    shift      = exp_biased - 1;
                    base       = abs_scaled >> shift;

                    if (shift > 0) begin
                        rem  = abs_scaled - (base << shift);
                        half = 1 << (shift - 1);
                        if (rem > half)
                            base = base + 1;
                        else if ((rem == half) && (base[0] == 1'b1))
                            base = base + 1;
                    end

                    if (base >= 16) begin
                        base       = 8;
                        exp_biased = exp_biased + 1;
                    end

                    if (exp_biased > 15) begin
                        fp8_from_sum = (sign_bit ? 8'h80 : 8'h00) | 8'h7E;
                    end else if ((exp_biased == 15) && (base == 15)) begin
                        fp8_from_sum = (sign_bit ? 8'h80 : 8'h00) | 8'h7E;
                    end else begin
                        fp8_from_sum = (sign_bit ? 8'h80 : 8'h00)
                                     | ((exp_biased & 15) << 3)
                                     | ((base - 8) & 7);
                    end
                end
            end
        end
    endfunction

    // ---- Combinational addition ---------------------------------------------
    integer sum_scaled;

    always @(*) begin
        // NaN: exp=1111, man=111
        if (((a[6:3] == 4'hF) && (a[2:0] == 3'h7)) ||
            ((b[6:3] == 4'hF) && (b[2:0] == 3'h7))) begin
            result = 8'h7F;
        // Both zero: -0 only if both negative, else +0
        end else if ((a[6:0] == 7'd0) && (b[6:0] == 7'd0)) begin
            result = (a[7] && b[7]) ? 8'h80 : 8'h00;
        // General case
        end else begin
            sum_scaled = fp8_to_scaled(a) + fp8_to_scaled(b);
            result     = fp8_from_sum(sum_scaled);
        end
    end

endmodule
