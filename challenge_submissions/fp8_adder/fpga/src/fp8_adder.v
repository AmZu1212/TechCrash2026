// ==========================================================================
// FP8 E4M3 Adder -- 5-Stage Pipeline with Parallel Precomputed Shift Bank
// ==========================================================================
// S_DECODE : case-based mag decode + NaN/zero detect
// S_SUM    : signed sum from registered magnitudes
// S_LOG    : fast_log2 || 15 parallel fixed shifts + do_round flags
//            All registered. Bottleneck = fast_log2 ~4.5 ns.
// S_ROUND  : 15:1 MUX select from registered shift bank  ~2.5 ns
// S_ENCODE : 3-way mux + clamp + pack -> result, done=1  ~3.5 ns
//
// TC cycles per test: 12   At 150 MHz: 4096*12/150e6 = 328 us
// ==========================================================================

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

    // Stage registers -- S_DECODE outputs
    reg        sv1; reg [7:0] sr1;
    reg        a_neg1; reg [17:0] a_mag1;
    reg        b_neg1; reg [17:0] b_mag1;

    // Stage registers -- S_SUM outputs
    reg        sv2; reg [7:0] sr2;
    reg        s_neg2; reg [18:0] s_mag2;

    // Stage registers -- S_LOG outputs (fast_log2 path)
    reg        sv3; reg [7:0] sr3;
    reg        s_neg3; reg [18:0] s_mag3;
    reg [4:0]  sh3; reg [3:0] eb3; reg [3:0] eb3_p1;
    reg        is_z3; reg is_ov3; reg is_dn3;

    // Parallel shift bank -- set in S_LOG from s_mag2 (pure wiring + small logic)
    // ba_arr[k]  = s_mag2[k+3:k]        (4 bits, zero logic delay = fixed bit-slice)
    // bp_arr[k]  = ba_arr[k] + 1        (4-bit +1 adder, ~0.5 ns)
    // oor_arr[k] = (ba_arr[k] == 4'hF)  (4-XNOR + AND, ~0.3 ns)
    // dr_arr[k]  = round-to-nearest-even decision for shift k (~1.5 ns)
    reg [3:0] ba_arr  [0:14];
    reg [3:0] bp_arr  [0:14];
    reg       oor_arr [0:14];
    reg       dr_arr  [0:14];

    // Stage registers -- S_ROUND outputs (15:1 MUX selects)
    reg        sv4; reg [7:0] sr4;
    reg        s_neg4; reg [18:0] s_mag4;
    reg [3:0]  eb4; reg [3:0] eb4_p1;
    reg [3:0]  ba4;       // selected ba nibble
    reg [3:0]  bp4;       // selected ba+1 nibble
    reg        oor4;      // selected overflow flag
    reg        dr4;       // selected do_round flag
    reg        is_z4; reg is_ov4; reg is_dn4;

    // ---- Case-based magnitude decode (16-way MUX, ~2 ns from input FFs) ----
    function [17:0] decode_mag;
        input [7:0] fp;
        reg [3:0] m;
        begin
            m = {1'b1, fp[2:0]};
            case (fp[6:3])
                4'd0:  decode_mag = {15'd0, fp[2:0]};
                4'd1:  decode_mag = {14'd0, m};
                4'd2:  decode_mag = {13'd0, m,  1'b0};
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

    // ---- Priority-encoder log2 (18-bit casez, ~4.5 ns) -----------------
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            sv1 <= 0; sr1 <= 0; a_neg1 <= 0; a_mag1 <= 0; b_neg1 <= 0; b_mag1 <= 0;
            sv2 <= 0; sr2 <= 0; s_neg2 <= 0; s_mag2 <= 0;
            sv3 <= 0; sr3 <= 0; s_neg3 <= 0; s_mag3 <= 0;
            sh3 <= 0; eb3 <= 0; eb3_p1 <= 0; is_z3 <= 0; is_ov3 <= 0; is_dn3 <= 0;
            sv4 <= 0; sr4 <= 0; s_neg4 <= 0; s_mag4 <= 0;
            eb4 <= 0; eb4_p1 <= 0; ba4 <= 0; bp4 <= 0; oor4 <= 0; dr4 <= 0;
            is_z4 <= 0; is_ov4 <= 0; is_dn4 <= 0;
            result <= 0; done <= 0; busy <= 0;
        end else begin
            done <= 1'b0;
            case (state)

                // Wait for start pulse
                S_IDLE: begin
                    if (start) begin busy <= 1'b1; state <= S_DECODE; end
                end

                // ~3 ns: 16-way case MUX from input ports
                S_DECODE: begin
                    if (((a[6:3] == 4'hF) && (a[2:0] == 3'h7)) ||
                        ((b[6:3] == 4'hF) && (b[2:0] == 3'h7)))
                        begin sv1 <= 1'b1; sr1 <= 8'h7F; end
                    else if ((a[6:0] == 7'd0) && (b[6:0] == 7'd0))
                        begin sv1 <= 1'b1; sr1 <= (a[7] && b[7]) ? 8'h80 : 8'h00; end
                    else
                        begin sv1 <= 1'b0; sr1 <= 8'h00; end
                    a_neg1 <= a[7]; a_mag1 <= decode_mag(a);
                    b_neg1 <= b[7]; b_mag1 <= decode_mag(b);
                    state  <= S_SUM;
                end

                // ~3 ns: 18-bit add/compare/subtract from FFs
                S_SUM: begin
                    sv2 <= sv1; sr2 <= sr1;
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

                // Bottleneck ~4.5 ns (fast_log2 path).
                // Parallel shift bank computed simultaneously -- each is just
                // a fixed bit-slice of s_mag2 (zero logic delay = pure wiring)
                // plus a small comparison/adder (~0.5-1.5 ns), all in parallel.
                S_LOG: begin
                    sv3    <= sv2; sr3 <= sr2;
                    s_neg3 <= s_neg2; s_mag3 <= s_mag2;
                    is_z3  <= (s_mag2 == 19'd0);
                    is_ov3 <= (s_mag2 > 19'd229376);
                    is_dn3 <= (s_mag2 != 19'd0) && (s_mag2 < 19'd8);
                    begin : log_block
                        reg [4:0] lg;
                        lg      = fast_log2(s_mag2[17:0]);
                        sh3     <= (lg >= 5'd3) ? lg - 5'd3 : 5'd0;
                        eb3     <= (lg >= 5'd2) ? lg[3:0] - 4'd2 : 4'd0;
                        eb3_p1  <= (lg >= 5'd1) ? lg[3:0] - 4'd1 : 4'd0;
                    end
                    // k=0: ba = s_mag2[3:0]
                    ba_arr[0]  <= s_mag2[3:0];
                    bp_arr[0]  <= s_mag2[3:0] + 4'd1;
                    oor_arr[0] <= (s_mag2[3:0] == 4'hF);
                    dr_arr[0]  <= 1'b0;
                    // k=1: ba = s_mag2[4:1]
                    ba_arr[1]  <= s_mag2[4:1];
                    bp_arr[1]  <= s_mag2[4:1] + 4'd1;
                    oor_arr[1] <= (s_mag2[4:1] == 4'hF);
                    dr_arr[1]  <= (1'b0) | ((s_mag2[0]) & s_mag2[1]);
                    // k=2: ba = s_mag2[5:2]
                    ba_arr[2]  <= s_mag2[5:2];
                    bp_arr[2]  <= s_mag2[5:2] + 4'd1;
                    oor_arr[2] <= (s_mag2[5:2] == 4'hF);
                    dr_arr[2]  <= (s_mag2[1] & s_mag2[0]) | ((s_mag2[1] & ~s_mag2[0]) & s_mag2[2]);
                    // k=3: ba = s_mag2[6:3]
                    ba_arr[3]  <= s_mag2[6:3];
                    bp_arr[3]  <= s_mag2[6:3] + 4'd1;
                    oor_arr[3] <= (s_mag2[6:3] == 4'hF);
                    dr_arr[3]  <= (s_mag2[2] & (|s_mag2[1:0])) | ((s_mag2[2] & (~|s_mag2[1:0])) & s_mag2[3]);
                    // k=4: ba = s_mag2[7:4]
                    ba_arr[4]  <= s_mag2[7:4];
                    bp_arr[4]  <= s_mag2[7:4] + 4'd1;
                    oor_arr[4] <= (s_mag2[7:4] == 4'hF);
                    dr_arr[4]  <= (s_mag2[3] & (|s_mag2[2:0])) | ((s_mag2[3] & (~|s_mag2[2:0])) & s_mag2[4]);
                    // k=5: ba = s_mag2[8:5]
                    ba_arr[5]  <= s_mag2[8:5];
                    bp_arr[5]  <= s_mag2[8:5] + 4'd1;
                    oor_arr[5] <= (s_mag2[8:5] == 4'hF);
                    dr_arr[5]  <= (s_mag2[4] & (|s_mag2[3:0])) | ((s_mag2[4] & (~|s_mag2[3:0])) & s_mag2[5]);
                    // k=6: ba = s_mag2[9:6]
                    ba_arr[6]  <= s_mag2[9:6];
                    bp_arr[6]  <= s_mag2[9:6] + 4'd1;
                    oor_arr[6] <= (s_mag2[9:6] == 4'hF);
                    dr_arr[6]  <= (s_mag2[5] & (|s_mag2[4:0])) | ((s_mag2[5] & (~|s_mag2[4:0])) & s_mag2[6]);
                    // k=7: ba = s_mag2[10:7]
                    ba_arr[7]  <= s_mag2[10:7];
                    bp_arr[7]  <= s_mag2[10:7] + 4'd1;
                    oor_arr[7] <= (s_mag2[10:7] == 4'hF);
                    dr_arr[7]  <= (s_mag2[6] & (|s_mag2[5:0])) | ((s_mag2[6] & (~|s_mag2[5:0])) & s_mag2[7]);
                    // k=8: ba = s_mag2[11:8]
                    ba_arr[8]  <= s_mag2[11:8];
                    bp_arr[8]  <= s_mag2[11:8] + 4'd1;
                    oor_arr[8] <= (s_mag2[11:8] == 4'hF);
                    dr_arr[8]  <= (s_mag2[7] & (|s_mag2[6:0])) | ((s_mag2[7] & (~|s_mag2[6:0])) & s_mag2[8]);
                    // k=9: ba = s_mag2[12:9]
                    ba_arr[9]  <= s_mag2[12:9];
                    bp_arr[9]  <= s_mag2[12:9] + 4'd1;
                    oor_arr[9] <= (s_mag2[12:9] == 4'hF);
                    dr_arr[9]  <= (s_mag2[8] & (|s_mag2[7:0])) | ((s_mag2[8] & (~|s_mag2[7:0])) & s_mag2[9]);
                    // k=10: ba = s_mag2[13:10]
                    ba_arr[10]  <= s_mag2[13:10];
                    bp_arr[10]  <= s_mag2[13:10] + 4'd1;
                    oor_arr[10] <= (s_mag2[13:10] == 4'hF);
                    dr_arr[10]  <= (s_mag2[9] & (|s_mag2[8:0])) | ((s_mag2[9] & (~|s_mag2[8:0])) & s_mag2[10]);
                    // k=11: ba = s_mag2[14:11]
                    ba_arr[11]  <= s_mag2[14:11];
                    bp_arr[11]  <= s_mag2[14:11] + 4'd1;
                    oor_arr[11] <= (s_mag2[14:11] == 4'hF);
                    dr_arr[11]  <= (s_mag2[10] & (|s_mag2[9:0])) | ((s_mag2[10] & (~|s_mag2[9:0])) & s_mag2[11]);
                    // k=12: ba = s_mag2[15:12]
                    ba_arr[12]  <= s_mag2[15:12];
                    bp_arr[12]  <= s_mag2[15:12] + 4'd1;
                    oor_arr[12] <= (s_mag2[15:12] == 4'hF);
                    dr_arr[12]  <= (s_mag2[11] & (|s_mag2[10:0])) | ((s_mag2[11] & (~|s_mag2[10:0])) & s_mag2[12]);
                    // k=13: ba = s_mag2[16:13]
                    ba_arr[13]  <= s_mag2[16:13];
                    bp_arr[13]  <= s_mag2[16:13] + 4'd1;
                    oor_arr[13] <= (s_mag2[16:13] == 4'hF);
                    dr_arr[13]  <= (s_mag2[12] & (|s_mag2[11:0])) | ((s_mag2[12] & (~|s_mag2[11:0])) & s_mag2[13]);
                    // k=14: ba = s_mag2[17:14]
                    ba_arr[14]  <= s_mag2[17:14];
                    bp_arr[14]  <= s_mag2[17:14] + 4'd1;
                    oor_arr[14] <= (s_mag2[17:14] == 4'hF);
                    dr_arr[14]  <= (s_mag2[13] & (|s_mag2[12:0])) | ((s_mag2[13] & (~|s_mag2[12:0])) & s_mag2[14]);
                    state <= S_ROUND;
                end

                // ~2.5 ns: 15:1 MUX select on sh3 from registered shift bank.
                // sh3 is a registered FF; each ba_arr/dr_arr element is a FF.
                // Quartus synthesizes variable index as a balanced MUX tree.
                S_ROUND: begin
                    sv4     <= sv3; sr4 <= sr3;
                    s_neg4  <= s_neg3; s_mag4 <= s_mag3;
                    eb4     <= eb3; eb4_p1 <= eb3_p1;
                    is_z4   <= is_z3; is_ov4 <= is_ov3; is_dn4 <= is_dn3;
                    ba4     <= ba_arr[sh3];
                    bp4     <= bp_arr[sh3];
                    oor4    <= oor_arr[sh3];
                    dr4     <= (sh3 == 5'd0) ? 1'b0 : dr_arr[sh3];
                    state   <= S_ENCODE;
                end

                // ~3.5 ns: 3-way mux (all inputs registered) + clamp + pack
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
                        real_ov = dr4 && oor4;
                        if (real_ov)        begin ba_f = 4'd8;    eb_f = eb4_p1; end
                        else if (dr4)       begin ba_f = bp4;     eb_f = eb4;    end
                        else                begin ba_f = ba4;     eb_f = eb4;    end
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
