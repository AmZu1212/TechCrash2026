"""
Generate fp8_adder.v as a 4-stage arithmetic pipeline.

Stages:
  S_IDLE   : decode a/b -> signed sum; register sum_neg, sum_mag, specials
  S_LOG    : fast_log2(sum_mag) -> log2_r; pass others through
  S_SHIFT  : sh=log2-3, eb=log2-2, ba=mag>>sh, ba+1, mask, hf, overflow flag
  S_ENCODE : rounding select, clamp, pack -> result + done=1

10 DUT cycles/test (TC_WAIT_ADD sees done on cycle 4 after start).
4096*10/100MHz = 410 us  |  4096*10/120MHz = 341 us

Critical path per stage (estimated):
  S_LOG:    fast_log2 from FF -> ~4 ns  (easily 200+ MHz)
  S_SHIFT:  log2->sh->barrel_shift+ba_p1 -> ~6 ns  (150+ MHz)
  S_ENCODE: precomputed mask,hf,ba,ba_p1 from FFs -> ~9 ns  (100-110 MHz)

Bottleneck: S_ENCODE at ~9 ns -> Fmax estimate ~100-110 MHz.
"""

code = """\
// ============================================================================
// FP8 E4M3 Adder -- 4-Stage Arithmetic Pipeline
// ============================================================================
// Stage 1 (S_IDLE)  : decode a/b, compute sum, latch specials
// Stage 2 (S_LOG)   : fast_log2(sum_mag) -- very short path (~4 ns)
// Stage 3 (S_SHIFT) : sh, eb, ba=mag>>sh, ba+1, mask, hf, overflow flag
// Stage 4 (S_ENCODE): rounding mux + clamp + pack -> result, done=1
//
// TC overhead: FETCH+WAIT_MEM+LAUNCH+WAIT_ADD(4)+CHECK+NEXT = 10 cycles/test
// 4096*10 / 100 MHz = 410 us
// 4096*10 / 120 MHz = 341 us  (D=5, VCO=600 MHz)
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
    localparam S_LOG    = 2'd1;
    localparam S_SHIFT  = 2'd2;
    localparam S_ENCODE = 2'd3;

    reg [1:0] state;

    // --- Stage 1 registers (S_IDLE -> S_LOG) ---
    reg        sv;       // special_valid
    reg [7:0]  sr;       // special_result
    reg        s_neg;    // sum sign
    reg [18:0] s_mag;    // sum magnitude

    // --- Stage 2 registers (S_LOG -> S_SHIFT) ---
    reg        sv2;
    reg [7:0]  sr2;
    reg        s_neg2;
    reg [18:0] s_mag2;
    reg [4:0]  log2_r;   // fast_log2(s_mag[17:0])

    // --- Stage 3 registers (S_SHIFT -> S_ENCODE) ---
    reg        sv3;
    reg [7:0]  sr3;
    reg        s_neg3;
    reg [18:0] s_mag3;   // pass-through for rounding
    reg [4:0]  eb3;      // exponent = log2_r - 2
    reg [4:0]  eb3_p1;   // eb + 1 (for mantissa overflow)
    reg [4:0]  sh3;      // shift = log2_r - 3
    reg [18:0] ba3;      // truncated mantissa = s_mag >> sh
    reg [18:0] ba3_p1;   // ba + 1 (pre-rounded)
    reg        oor3;     // ba[3:0] == 4'hF (round would overflow mantissa nibble)
    reg [18:0] mask3;    // (1 << sh) - 1  (remainder mask)
    reg [18:0] hf3;      // 1 << (sh-1)    (half-ULP threshold)
    reg        is_z3;    // sum_mag == 0
    reg        is_ov3;   // sum_mag > 229376 (above max FP8)
    reg        is_dn3;   // 0 < sum_mag < 8 (denormal)

    // ---- Priority-encoder log2 (18-bit input) ----------------------------
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

    // ---- FP8 -> unsigned magnitude + sign --------------------------------
    function [18:0] fp8_to_mag;
        input [7:0] fp;
        reg [3:0] exp_f, man_f;
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

    // ---- Signed sum (unsigned magnitude + sign) --------------------------
    function [19:0] signed_sum;
        input [18:0] ap;
        input [18:0] bp;
        reg an, bn;
        reg [17:0] am, bm;
        reg rn;
        reg [18:0] rm;
        begin
            an = ap[18]; am = ap[17:0];
            bn = bp[18]; bm = bp[17:0];
            if (an == bn) begin
                rn = an; rm = {1'b0, am} + {1'b0, bm};
            end else if (am >= bm) begin
                rn = an; rm = {1'b0, am} - {1'b0, bm};
            end else begin
                rn = bn; rm = {1'b0, bm} - {1'b0, am};
            end
            signed_sum = {rn, rm};
        end
    endfunction

    // ---- Combinational decode: mask = (1<<sh)-1 --------------------------
    // Implemented as case to avoid long dependency chains
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

    // ---- Combinational decode: hf = 1<<(sh-1) --------------------------
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

    // ---- Wires: compute sum from input ports combinationally -------------
    wire [18:0] a_pack_w = fp8_to_mag(a);
    wire [18:0] b_pack_w = fp8_to_mag(b);
    wire [19:0] sum_w    = signed_sum(a_pack_w, b_pack_w);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            sv      <= 1'b0; sr    <= 8'd0;
            s_neg   <= 1'b0; s_mag <= 19'd0;
            sv2     <= 1'b0; sr2   <= 8'd0;
            s_neg2  <= 1'b0; s_mag2 <= 19'd0; log2_r <= 5'd0;
            sv3     <= 1'b0; sr3   <= 8'd0;
            s_neg3  <= 1'b0; s_mag3 <= 19'd0;
            eb3     <= 5'd0; eb3_p1 <= 5'd0;
            sh3     <= 5'd0;
            ba3     <= 19'd0; ba3_p1 <= 19'd0;
            oor3    <= 1'b0;
            mask3   <= 19'd0; hf3  <= 19'd0;
            is_z3   <= 1'b0; is_ov3 <= 1'b0; is_dn3 <= 1'b0;
            result  <= 8'd0; done <= 1'b0; busy <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)

                // ─────────────────────────────────────────────────────────
                S_IDLE: begin
                    if (start) begin
                        if (((a[6:3] == 4'hF) && (a[2:0] == 3'h7)) ||
                            ((b[6:3] == 4'hF) && (b[2:0] == 3'h7))) begin
                            sv <= 1'b1; sr <= 8'h7F;
                        end else if ((a[6:0] == 7'd0) && (b[6:0] == 7'd0)) begin
                            sv <= 1'b1;
                            sr <= (a[7] && b[7]) ? 8'h80 : 8'h00;
                        end else begin
                            sv <= 1'b0; sr <= 8'h00;
                        end
                        s_neg <= sum_w[19];
                        s_mag <= sum_w[18:0];
                        busy  <= 1'b1;
                        state <= S_LOG;
                    end
                end

                // ─────────────────────────────────────────────────────────
                // Short path: only fast_log2 (~4 ns from s_mag FF)
                S_LOG: begin
                    sv2     <= sv;
                    sr2     <= sr;
                    s_neg2  <= s_neg;
                    s_mag2  <= s_mag;
                    log2_r  <= fast_log2(s_mag[17:0]);
                    state   <= S_SHIFT;
                end

                // ─────────────────────────────────────────────────────────
                // From log2_r FF: sh, eb (~1 ns), then barrel-shift (~5 ns)
                // ba_p1 adds 1 more ns -> total ~6 ns bottleneck
                S_SHIFT: begin
                    sv3    <= sv2;
                    sr3    <= sr2;
                    s_neg3 <= s_neg2;
                    s_mag3 <= s_mag2;
                    is_z3  <= (s_mag2 == 19'd0);
                    is_ov3 <= (s_mag2 > 19'd229376);
                    is_dn3 <= (s_mag2 != 19'd0) && (s_mag2 < 19'd8);
                    begin : shift_block
                        reg [4:0]  sh_t;
                        reg [18:0] ba_t;
                        sh_t   = log2_r - 5'd3;
                        eb3    <= log2_r - 5'd2;
                        eb3_p1 <= log2_r - 5'd1;
                        sh3    <= sh_t;
                        ba_t   = s_mag2 >> sh_t;
                        ba3    <= ba_t;
                        ba3_p1 <= ba_t + 19'd1;
                        oor3   <= (ba_t[3:0] == 4'hF);
                        mask3  <= sh_to_mask(sh_t);
                        hf3    <= sh_to_hf(sh_t);
                    end
                    state <= S_ENCODE;
                end

                // ─────────────────────────────────────────────────────────
                // All inputs from FFs -> fast paths:
                //   rm = s_mag3 & mask3  (~1 ns AND)
                //   do_round from rm,hf3,ba3[0]  (~4 ns)
                //   select ba/eb using precomputed ba3,ba3_p1,oor3,eb3,eb3_p1  (~6 ns)
                //   clamp + pack  (~9 ns total)
                S_ENCODE: begin
                    if (sv3) begin
                        result <= sr3;
                    end else if (is_z3) begin
                        result <= 8'h00;
                    end else if (is_ov3) begin
                        result <= {s_neg3, 7'h7E};
                    end else if (is_dn3) begin
                        result <= {s_neg3, 1'b0, 3'b000, s_mag3[2:0]};
                    end else begin : encode_block
                        reg [18:0] rm_t;
                        reg        do_round;
                        reg        real_ov;
                        reg [3:0]  ba_f;
                        reg [4:0]  eb_f;

                        rm_t     = s_mag3 & mask3;
                        do_round = (sh3 != 5'd0) &&
                                   ((rm_t > hf3) ||
                                    ((rm_t == hf3) && ba3[0]));
                        real_ov  = do_round && oor3;

                        if (real_ov) begin
                            ba_f = 4'd8;
                            eb_f = eb3_p1[3:0];
                        end else if (do_round) begin
                            ba_f = ba3_p1[3:0];
                            eb_f = eb3[3:0];
                        end else begin
                            ba_f = ba3[3:0];
                            eb_f = eb3[3:0];
                        end

                        if ((eb_f > 4'd15) ||
                            ((eb_f == 4'd15) && (ba_f == 4'hF)))
                            result <= {s_neg3, 7'h7E};
                        else
                            result <= {s_neg3, eb_f[3:0], ba_f[2:0]};
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
