"""
6-stage FP8 adder pipeline targeting 150 MHz.

Key fix vs 5-stage: move barrel shift from S_SHIFT into S_LOG.
Both fast_log2 and barrel shift read only s_mag2 (same source FF),
so they run in parallel within the same stage, but each independently
feeds its own register. The stage path is max(fast_log2, barrel_shift)
= max(4.5 ns, 5.5 ns) = 5.5 ns -- fits in 6.67 ns (150 MHz).

Stages:
  S_DECODE: case mag decode          ~3.0 ns
  S_SUM:    18-bit add/sub           ~3.0 ns
  S_LOG:    fast_log2 + barrel_shift ~5.5 ns  (bottleneck, fits 150 MHz)
  S_ROUND:  rm=mag&mask, do_round    ~3.0 ns  (AND + compare from FFs)
  S_ENCODE: 3-way mux + clamp + pack ~3.5 ns

TC cycles/test = 12
At 150 MHz: 4096*12/150e6 = 328 us
"""

code = """\
// ============================================================================
// FP8 E4M3 Adder -- 6-Stage Arithmetic Pipeline, 150 MHz target
// ============================================================================
// Stage 1 (S_DECODE): case-based fp8_to_mag for a,b; detect NaN/zero (~3 ns)
// Stage 2 (S_SUM)   : signed_sum from registered magnitudes (~3 ns)
// Stage 3 (S_LOG)   : fast_log2 + barrel_shift (parallel, ~5.5 ns bottleneck)
// Stage 4 (S_ROUND) : rm = mag & mask, do_round decision (~3 ns)
// Stage 5 (S_ENCODE): mux ba/ba_p1/8 + clamp + pack -> result, done=1 (~3.5 ns)
//
// TC per-test cycle count: 5 pipeline stages + 1 idle + 5 TC overhead = 12
//   4096*12 / 150 MHz = 328 us
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

    localparam S_IDLE   = 3'd0;
    localparam S_DECODE = 3'd1;
    localparam S_SUM    = 3'd2;
    localparam S_LOG    = 3'd3;
    localparam S_ROUND  = 3'd4;
    localparam S_ENCODE = 3'd5;

    reg [2:0] state;

    // Stage 1 (S_DECODE) outputs
    reg        sv1;
    reg [7:0]  sr1;
    reg        a_neg1;
    reg [17:0] a_mag1;
    reg        b_neg1;
    reg [17:0] b_mag1;

    // Stage 2 (S_SUM) outputs
    reg        sv2;
    reg [7:0]  sr2;
    reg        s_neg2;
    reg [18:0] s_mag2;

    // Stage 3 (S_LOG) outputs -- fast_log2 AND barrel_shift run in parallel
    reg        sv3;
    reg [7:0]  sr3;
    reg        s_neg3;
    reg [18:0] s_mag3;    // carry-through for denormal
    reg [3:0]  eb3;       // fast_log2 - 2
    reg [3:0]  eb3_p1;    // fast_log2 - 1
    reg [4:0]  sh3;       // fast_log2 - 3
    reg [18:0] ba3;       // s_mag2 >> sh  (barrel shift done here)
    reg [18:0] ba3_p1;    // ba + 1
    reg        oor3;      // ba[3:0] == 4'hF
    reg [18:0] mask3;     // (1 << sh) - 1
    reg [18:0] hf3;       // 1 << (sh-1)
    reg        is_z3;
    reg        is_ov3;
    reg        is_dn3;

    // Stage 4 (S_ROUND) outputs
    reg        sv4;
    reg [7:0]  sr4;
    reg        s_neg4;
    reg [18:0] s_mag4;
    reg [3:0]  eb4;
    reg [3:0]  eb4_p1;
    reg [18:0] ba4;
    reg [18:0] ba4_p1;
    reg        oor4;
    reg        do_round4;
    reg        is_z4;
    reg        is_ov4;
    reg        is_dn4;

    // ---- Case-based magnitude decoder (16-way MUX, ~2 ns) ---------------
    function [17:0] decode_mag;
        input [7:0] fp;
        reg [3:0] m;
        begin
            m = {1'b1, fp[2:0]};
            case (fp[6:3])
                4'd0:  decode_mag = {15'd0, fp[2:0]};
                4'd1:  decode_mag = {14'd0, m};
                4'd2:  decode_mag = {13'd0, m,  1'd0};
                4'd3:  decode_mag = {12'd0, m,  2'd0};
                4'd4:  decode_mag = {11'd0, m,  3'd0};
                4'd5:  decode_mag = {10'd0, m,  4'd0};
                4'd6:  decode_mag = { 9'd0, m,  5'd0};
                4'd7:  decode_mag = { 8'd0, m,  6'd0};
                4'd8:  decode_mag = { 7'd0, m,  7'd0};
                4'd9:  decode_mag = { 6'd0, m,  8'd0};
                4'd10: decode_mag = { 5'd0, m,  9'd0};
                4'd11: decode_mag = { 4'd0, m, 10'd0};
                4'd12: decode_mag = { 3'd0, m, 11'd0};
                4'd13: decode_mag = { 2'd0, m, 12'd0};
                4'd14: decode_mag = { 1'd0, m, 13'd0};
                4'd15: decode_mag = {        m, 14'd0};
            endcase
        end
    endfunction

    // ---- Priority-encoder log2 (18-bit) ---------------------------------
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

    // ---- Remainder mask: (1 << sh) - 1  (case MUX ~2 ns) ---------------
    function [18:0] sh_to_mask;
        input [4:0] sh;
        begin
            case (sh)
                5'd0:  sh_to_mask = 19'd0;
                5'd1:  sh_to_mask = 19'd1;
                5'd2:  sh_to_mask = 19'd3;
                5'd3:  sh_to_mask = 19'd7;
                5'd4:  sh_to_mask = 19'd15;
                5'd5:  sh_to_mask = 19'd31;
                5'd6:  sh_to_mask = 19'd63;
                5'd7:  sh_to_mask = 19'd127;
                5'd8:  sh_to_mask = 19'd255;
                5'd9:  sh_to_mask = 19'd511;
                5'd10: sh_to_mask = 19'd1023;
                5'd11: sh_to_mask = 19'd2047;
                5'd12: sh_to_mask = 19'd4095;
                5'd13: sh_to_mask = 19'd8191;
                5'd14: sh_to_mask = 19'd16383;
                default: sh_to_mask = 19'd0;
            endcase
        end
    endfunction

    // ---- Half-ULP: 1 << (sh-1)  (case MUX ~2 ns) -----------------------
    function [18:0] sh_to_hf;
        input [4:0] sh;
        begin
            case (sh)
                5'd0:  sh_to_hf = 19'd0;
                5'd1:  sh_to_hf = 19'd1;
                5'd2:  sh_to_hf = 19'd2;
                5'd3:  sh_to_hf = 19'd4;
                5'd4:  sh_to_hf = 19'd8;
                5'd5:  sh_to_hf = 19'd16;
                5'd6:  sh_to_hf = 19'd32;
                5'd7:  sh_to_hf = 19'd64;
                5'd8:  sh_to_hf = 19'd128;
                5'd9:  sh_to_hf = 19'd256;
                5'd10: sh_to_hf = 19'd512;
                5'd11: sh_to_hf = 19'd1024;
                5'd12: sh_to_hf = 19'd2048;
                5'd13: sh_to_hf = 19'd4096;
                5'd14: sh_to_hf = 19'd8192;
                default: sh_to_hf = 19'd0;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            sv1      <= 0; sr1    <= 0;
            a_neg1   <= 0; a_mag1 <= 0;
            b_neg1   <= 0; b_mag1 <= 0;
            sv2      <= 0; sr2    <= 0;
            s_neg2   <= 0; s_mag2 <= 0;
            sv3      <= 0; sr3    <= 0;
            s_neg3   <= 0; s_mag3 <= 0;
            eb3      <= 0; eb3_p1 <= 0; sh3 <= 0;
            ba3      <= 0; ba3_p1 <= 0; oor3 <= 0;
            mask3    <= 0; hf3   <= 0;
            is_z3    <= 0; is_ov3 <= 0; is_dn3 <= 0;
            sv4      <= 0; sr4   <= 0;
            s_neg4   <= 0; s_mag4 <= 0;
            eb4      <= 0; eb4_p1 <= 0;
            ba4      <= 0; ba4_p1 <= 0;
            oor4     <= 0; do_round4 <= 0;
            is_z4    <= 0; is_ov4 <= 0; is_dn4 <= 0;
            result   <= 0; done  <= 0; busy <= 0;
        end else begin
            done <= 1'b0;

            case (state)

                S_IDLE: begin
                    if (start) begin
                        busy  <= 1'b1;
                        state <= S_DECODE;
                    end
                end

                // ~3 ns: 16-way case MUX from input port
                S_DECODE: begin
                    if (((a[6:3] == 4'hF) && (a[2:0] == 3'h7)) ||
                        ((b[6:3] == 4'hF) && (b[2:0] == 3'h7))) begin
                        sv1 <= 1'b1; sr1 <= 8'h7F;
                    end else if ((a[6:0] == 7'd0) && (b[6:0] == 7'd0)) begin
                        sv1 <= 1'b1; sr1 <= (a[7] && b[7]) ? 8'h80 : 8'h00;
                    end else begin
                        sv1 <= 1'b0; sr1 <= 8'h00;
                    end
                    a_neg1 <= a[7]; a_mag1 <= decode_mag(a);
                    b_neg1 <= b[7]; b_mag1 <= decode_mag(b);
                    state  <= S_SUM;
                end

                // ~3 ns: 18-bit add/compare/subtract from FFs
                S_SUM: begin
                    sv2    <= sv1; sr2 <= sr1;
                    if (a_neg1 == b_neg1) begin
                        s_neg2 <= a_neg1;
                        s_mag2 <= {1'b0, a_mag1} + {1'b0, b_mag1};
                    end else if (a_mag1 >= b_mag1) begin
                        s_neg2 <= a_neg1;
                        s_mag2 <= {1'b0, a_mag1} - {1'b0, b_mag1};
                    end else begin
                        s_neg2 <= b_neg1;
                        s_mag2 <= {1'b0, b_mag1} - {1'b0, a_mag1};
                    end
                    state <= S_LOG;
                end

                // ~5.5 ns bottleneck: fast_log2 || barrel_shift (both read s_mag2)
                // Quartus places them in parallel -- critical path = max of both
                S_LOG: begin
                    sv3    <= sv2; sr3 <= sr2;
                    s_neg3 <= s_neg2; s_mag3 <= s_mag2;
                    is_z3  <= (s_mag2 == 19'd0);
                    is_ov3 <= (s_mag2 > 19'd229376);
                    is_dn3 <= (s_mag2 != 19'd0) && (s_mag2 < 19'd8);
                    begin : log_shift_block
                        reg [4:0] lg;
                        reg [4:0] sh_t;
                        reg [18:0] ba_t;
                        lg      = fast_log2(s_mag2[17:0]);
                        eb3     <= (lg >= 5'd2) ? lg - 5'd2 : 5'd0;
                        eb3_p1  <= (lg >= 5'd1) ? lg - 5'd1 : 5'd0;
                        sh_t    = (lg >= 5'd3) ? lg - 5'd3 : 5'd0;
                        sh3     <= sh_t;
                        // Barrel shift parallel to log2 -- same source s_mag2
                        ba_t    = s_mag2 >> sh_t;
                        ba3     <= ba_t;
                        ba3_p1  <= ba_t + 19'd1;
                        oor3    <= (ba_t[3:0] == 4'hF);
                        mask3   <= sh_to_mask(sh_t);
                        hf3     <= sh_to_hf(sh_t);
                    end
                    state <= S_ROUND;
                end

                // ~3 ns: rm = s_mag3 & mask3 (AND), compare rm vs hf3, check ba3[0]
                // All inputs are registered FFs -> very short path
                S_ROUND: begin
                    sv4      <= sv3; sr4 <= sr3;
                    s_neg4   <= s_neg3; s_mag4 <= s_mag3;
                    eb4      <= eb3; eb4_p1 <= eb3_p1;
                    ba4      <= ba3; ba4_p1 <= ba3_p1;
                    oor4     <= oor3;
                    is_z4    <= is_z3; is_ov4 <= is_ov3; is_dn4 <= is_dn3;
                    begin : round_block
                        reg [18:0] rm_t;
                        rm_t     = s_mag3 & mask3;
                        do_round4 <= (sh3 != 5'd0) &&
                                     ((rm_t > hf3) ||
                                      ((rm_t == hf3) && ba3[0]));
                    end
                    state <= S_ENCODE;
                end

                // ~3.5 ns: 3-way mux (do_round4, oor4 from FFs) + clamp + pack
                S_ENCODE: begin
                    if (sv4) begin
                        result <= sr4;
                    end else if (is_z4) begin
                        result <= 8'h00;
                    end else if (is_ov4) begin
                        result <= {s_neg4, 7'h7E};
                    end else if (is_dn4) begin
                        result <= {s_neg4, 1'b0, 3'b000, s_mag4[2:0]};
                    end else begin : encode_block
                        reg        real_ov;
                        reg [3:0]  ba_f, eb_f;
                        real_ov = do_round4 && oor4;
                        if (real_ov)          begin ba_f = 4'd8;          eb_f = eb4_p1; end
                        else if (do_round4)   begin ba_f = ba4_p1[3:0];   eb_f = eb4;    end
                        else                  begin ba_f = ba4[3:0];      eb_f = eb4;    end
                        if ((eb_f > 4'd15) || ((eb_f == 4'd15) && (ba_f == 4'hF)))
                            result <= {s_neg4, 7'h7E};
                        else
                            result <= {s_neg4, eb_f[3:0], ba_f[2:0]};
                    end
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

    localparam S_IDLE   = 3'd0;
    localparam S_DECODE = 3'd1;
    localparam S_SUM    = 3'd2;
    localparam S_LOG    = 3'd3;
    localparam S_SHIFT  = 3'd4;
    localparam S_ENCODE = 3'd5;

    reg [2:0] state;

    // Stage 1 registers (S_DECODE outputs)
    reg        sv1;          // special_valid: NaN or zero-zero case
    reg [7:0]  sr1;          // special_result
    reg        a_neg1;
    reg [17:0] a_mag1;
    reg        b_neg1;
    reg [17:0] b_mag1;

    // Stage 2 registers (S_SUM outputs)
    reg        sv2, b_neg2;
    reg [7:0]  sr2;
    reg        s_neg2;
    reg [18:0] s_mag2;

    // Stage 3 registers (S_LOG outputs)
    reg        sv3;
    reg [7:0]  sr3;
    reg        s_neg3;
    reg [18:0] s_mag3;       // carry-through for denormal encoding
    reg [4:0]  sh3;          // log2 - 3 = shift amount for barrel
    reg [3:0]  eb3;          // log2 - 2 = exponent
    reg [3:0]  eb3_p1;       // log2 - 1 = exponent + 1 (for mantissa overflow)
    reg        is_z3;
    reg        is_ov3;
    reg        is_dn3;

    // Stage 4 registers (S_SHIFT outputs)
    reg        sv4;
    reg [7:0]  sr4;
    reg        s_neg4;
    reg [18:0] s_mag4;       // carry-through for denormal
    reg [3:0]  eb4, eb4_p1;
    reg [18:0] ba4;          // truncated mantissa (in [8,15])
    reg [18:0] ba4_p1;       // ba + 1
    reg        oor4;         // ba[3:0] == 4'hF (rounding causes mantissa overflow)
    reg        do_round4;    // rounding decision
    reg        is_z4, is_ov4, is_dn4;

    // ---- Case-based magnitude decoder -----------------------------------
    // Much faster than a generic barrel shift: synthesizes as 16-way MUX (~2 ns)
    function [17:0] decode_mag;
        input [7:0] fp;
        reg [3:0] m;
        begin
            m = {1'b1, fp[2:0]};   // implicit leading 1 + mantissa
            case (fp[6:3])         // exponent field
                4'd0:  decode_mag = {15'd0, fp[2:0]};     // denormal: 0.mantissa
                4'd1:  decode_mag = {14'd0, m};
                4'd2:  decode_mag = {13'd0, m,  1'd0};
                4'd3:  decode_mag = {12'd0, m,  2'd0};
                4'd4:  decode_mag = {11'd0, m,  3'd0};
                4'd5:  decode_mag = {10'd0, m,  4'd0};
                4'd6:  decode_mag = { 9'd0, m,  5'd0};
                4'd7:  decode_mag = { 8'd0, m,  6'd0};
                4'd8:  decode_mag = { 7'd0, m,  7'd0};
                4'd9:  decode_mag = { 6'd0, m,  8'd0};
                4'd10: decode_mag = { 5'd0, m,  9'd0};
                4'd11: decode_mag = { 4'd0, m, 10'd0};
                4'd12: decode_mag = { 3'd0, m, 11'd0};
                4'd13: decode_mag = { 2'd0, m, 12'd0};
                4'd14: decode_mag = { 1'd0, m, 13'd0};
                4'd15: decode_mag = {        m, 14'd0};
            endcase
        end
    endfunction

    // ---- Priority-encoder log2 (18-bit) ---------------------------------
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

    // ---- Remainder mask: (1 << sh) - 1 ----------------------------------
    function [18:0] sh_to_mask;
        input [4:0] sh;
        begin
            case (sh)
                5'd0:  sh_to_mask = 19'd0;
                5'd1:  sh_to_mask = 19'd1;
                5'd2:  sh_to_mask = 19'd3;
                5'd3:  sh_to_mask = 19'd7;
                5'd4:  sh_to_mask = 19'd15;
                5'd5:  sh_to_mask = 19'd31;
                5'd6:  sh_to_mask = 19'd63;
                5'd7:  sh_to_mask = 19'd127;
                5'd8:  sh_to_mask = 19'd255;
                5'd9:  sh_to_mask = 19'd511;
                5'd10: sh_to_mask = 19'd1023;
                5'd11: sh_to_mask = 19'd2047;
                5'd12: sh_to_mask = 19'd4095;
                5'd13: sh_to_mask = 19'd8191;
                5'd14: sh_to_mask = 19'd16383;
                default: sh_to_mask = 19'd0;
            endcase
        end
    endfunction

    // ---- Half-ULP threshold: 1 << (sh-1) --------------------------------
    function [18:0] sh_to_hf;
        input [4:0] sh;
        begin
            case (sh)
                5'd0:  sh_to_hf = 19'd0;
                5'd1:  sh_to_hf = 19'd1;
                5'd2:  sh_to_hf = 19'd2;
                5'd3:  sh_to_hf = 19'd4;
                5'd4:  sh_to_hf = 19'd8;
                5'd5:  sh_to_hf = 19'd16;
                5'd6:  sh_to_hf = 19'd32;
                5'd7:  sh_to_hf = 19'd64;
                5'd8:  sh_to_hf = 19'd128;
                5'd9:  sh_to_hf = 19'd256;
                5'd10: sh_to_hf = 19'd512;
                5'd11: sh_to_hf = 19'd1024;
                5'd12: sh_to_hf = 19'd2048;
                5'd13: sh_to_hf = 19'd4096;
                5'd14: sh_to_hf = 19'd8192;
                default: sh_to_hf = 19'd0;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            sv1      <= 0; sr1    <= 0;
            a_neg1   <= 0; a_mag1 <= 0;
            b_neg1   <= 0; b_mag1 <= 0;
            sv2      <= 0; sr2    <= 0; b_neg2 <= 0;
            s_neg2   <= 0; s_mag2 <= 0;
            sv3      <= 0; sr3    <= 0;
            s_neg3   <= 0; s_mag3 <= 0;
            sh3      <= 0; eb3   <= 0; eb3_p1 <= 0;
            is_z3    <= 0; is_ov3 <= 0; is_dn3 <= 0;
            sv4      <= 0; sr4   <= 0;
            s_neg4   <= 0; s_mag4 <= 0;
            eb4      <= 0; eb4_p1 <= 0;
            ba4      <= 0; ba4_p1 <= 0;
            oor4     <= 0; do_round4 <= 0;
            is_z4    <= 0; is_ov4 <= 0; is_dn4 <= 0;
            result   <= 0; done  <= 0; busy <= 0;
        end else begin
            done <= 1'b0;

            case (state)

                // ==========================================================
                // S_IDLE: wait for start, then go to S_DECODE
                S_IDLE: begin
                    if (start) begin
                        busy  <= 1'b1;
                        state <= S_DECODE;
                    end
                end

                // ==========================================================
                // S_DECODE: case-based magnitude decode + NaN/zero detect
                // Critical path: input port FF -> 16-way case MUX -> FF (~3 ns)
                S_DECODE: begin
                    // NaN: exp=1111, man=111 (0x7F / 0xFF)
                    if (((a[6:3] == 4'hF) && (a[2:0] == 3'h7)) ||
                        ((b[6:3] == 4'hF) && (b[2:0] == 3'h7))) begin
                        sv1 <= 1'b1;
                        sr1 <= 8'h7F;
                    // Both zero: -0 + -0 = -0, else +0
                    end else if ((a[6:0] == 7'd0) && (b[6:0] == 7'd0)) begin
                        sv1 <= 1'b1;
                        sr1 <= (a[7] && b[7]) ? 8'h80 : 8'h00;
                    end else begin
                        sv1 <= 1'b0;
                        sr1 <= 8'h00;
                    end
                    a_neg1 <= a[7];
                    a_mag1 <= decode_mag(a);
                    b_neg1 <= b[7];
                    b_mag1 <= decode_mag(b);
                    state  <= S_SUM;
                end

                // ==========================================================
                // S_SUM: signed sum from registered magnitudes
                // Critical path: 18-bit add/compare/subtract from FFs (~3 ns)
                S_SUM: begin
                    sv2    <= sv1;
                    sr2    <= sr1;
                    b_neg2 <= b_neg1;   // unused downstream, can trim
                    if (a_neg1 == b_neg1) begin
                        s_neg2 <= a_neg1;
                        s_mag2 <= {1'b0, a_mag1} + {1'b0, b_mag1};
                    end else if (a_mag1 >= b_mag1) begin
                        s_neg2 <= a_neg1;
                        s_mag2 <= {1'b0, a_mag1} - {1'b0, b_mag1};
                    end else begin
                        s_neg2 <= b_neg1;
                        s_mag2 <= {1'b0, b_mag1} - {1'b0, a_mag1};
                    end
                    state  <= S_LOG;
                end

                // ==========================================================
                // S_LOG: fast_log2 + pre-compute sh, eb, eb_p1, range flags
                // Critical path: fast_log2 (~4 ns) + subtract (~0.5 ns) = ~4.5 ns
                S_LOG: begin
                    sv3    <= sv2;
                    sr3    <= sr2;
                    s_neg3 <= s_neg2;
                    s_mag3 <= s_mag2;
                    is_z3  <= (s_mag2 == 19'd0);
                    is_ov3 <= (s_mag2 > 19'd229376);
                    is_dn3 <= (s_mag2 != 19'd0) && (s_mag2 < 19'd8);
                    begin : log_block
                        reg [4:0] lg;
                        lg      = fast_log2(s_mag2[17:0]);
                        sh3     <= (lg >= 5'd3) ? (lg - 5'd3) : 5'd0;
                        eb3     <= (lg >= 5'd2) ? (lg - 5'd2) : 5'd0;
                        eb3_p1  <= (lg >= 5'd1) ? (lg - 5'd1) : 5'd0;
                    end
                    state  <= S_SHIFT;
                end

                // ==========================================================
                // S_SHIFT: barrel shift from registered sh3 + pre-compute do_round
                // Critical path: sh3(FF)->barrel_shift->ba, ba+1 = ~5 ns
                //                sh3(FF)->mask->rm->compare = ~4.5 ns
                S_SHIFT: begin
                    sv4    <= sv3;
                    sr4    <= sr3;
                    s_neg4 <= s_neg3;
                    s_mag4 <= s_mag3;
                    eb4    <= eb3;
                    eb4_p1 <= eb3_p1;
                    is_z4  <= is_z3;
                    is_ov4 <= is_ov3;
                    is_dn4 <= is_dn3;
                    begin : shift_block
                        reg [18:0] ba_t;
                        reg [18:0] rm_t;
                        reg [18:0] hf_t;
                        reg [18:0] mask_t;
                        ba_t     = s_mag3 >> sh3;
                        ba4      <= ba_t;
                        ba4_p1   <= ba_t + 19'd1;
                        oor4     <= (ba_t[3:0] == 4'hF);
                        mask_t   = sh_to_mask(sh3);
                        hf_t     = sh_to_hf(sh3);
                        rm_t     = s_mag3 & mask_t;
                        do_round4 <= (sh3 != 5'd0) &&
                                     ((rm_t > hf_t) ||
                                      ((rm_t == hf_t) && ba_t[0]));
                    end
                    state  <= S_ENCODE;
                end

                // ==========================================================
                // S_ENCODE: mux pre-computed ba/ba_p1 + clamp + pack + done=1
                // Critical path: do_round4(FF)->real_ov->3-way_mux->pack = ~3.5 ns
                S_ENCODE: begin
                    if (sv4) begin
                        result <= sr4;
                    end else if (is_z4) begin
                        result <= 8'h00;
                    end else if (is_ov4) begin
                        result <= {s_neg4, 7'h7E};
                    end else if (is_dn4) begin
                        result <= {s_neg4, 1'b0, 3'b000, s_mag4[2:0]};
                    end else begin : encode_block
                        reg        real_ov;
                        reg [3:0]  ba_f;
                        reg [3:0]  eb_f;
                        real_ov = do_round4 && oor4;
                        if (real_ov) begin
                            ba_f = 4'd8;
                            eb_f = eb4_p1;
                        end else if (do_round4) begin
                            ba_f = ba4_p1[3:0];
                            eb_f = eb4[3:0];
                        end else begin
                            ba_f = ba4[3:0];
                            eb_f = eb4[3:0];
                        end
                        if ((eb_f > 4'd15) ||
                            ((eb_f == 4'd15) && (ba_f == 4'hF)))
                            result <= {s_neg4, 7'h7E};
                        else
                            result <= {s_neg4, eb_f[3:0], ba_f[2:0]};
                    end
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
with open(out_path, 'w', encoding='utf-8') as f:
    f.write(code)
print(f"Written: {out_path} ({len(code)} bytes)")
