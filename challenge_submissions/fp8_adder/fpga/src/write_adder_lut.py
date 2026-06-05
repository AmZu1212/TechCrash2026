"""
Generate fp8_adder.v as a full 256x256 lookup table (65536 entries).

All FP8 E4M3 addition results are precomputed in Python and embedded
as a Verilog initial block that Quartus infers into M9K block RAM.

M9K RAM runs at 200+ MHz with 1-cycle registered read latency.
Design: S_IDLE latches {a,b} address + triggers M9K read,
        S_ENCODE captures registered M9K output as result + pulses done.

Predicted performance:
  8 cycles/test (FETCH+WAIT_MEM+LAUNCH+WAIT_ADD(2)+CHECK+NEXT + 1 TC overhead)
  At 150 MHz (D=4): 4096*8/150e6 = 219 us
  At 200 MHz (D=3): 4096*8/200e6 = 164 us
"""

def fast_log2(v):
    v = v & 0x3FFFF
    if v == 0:
        return 0
    return v.bit_length() - 1

def fp8_to_mag(fp):
    fp = fp & 0xFF
    exp_f = (fp >> 3) & 0xF
    man_f = fp & 0x7
    if exp_f == 0:
        mag = man_f
    else:
        mag = (8 + man_f) << (exp_f - 1)
    sign = (fp >> 7) & 1
    return (sign, mag)

def signed_sum(a_neg, a_mag, b_neg, b_mag):
    if a_neg == b_neg:
        return a_neg, a_mag + b_mag
    else:
        if a_mag >= b_mag:
            return a_neg, a_mag - b_mag
        else:
            return b_neg, b_mag - a_mag

def fp8_encode(neg, mag):
    if mag == 0:
        return 0x00
    if mag > 229376:
        return (0x80 if neg else 0x00) | 0x7E
    if mag < 8:
        return (0x80 if neg else 0x00) | (mag & 0xFF)
    eb = fast_log2(mag & 0x3FFFF) - 2
    sh = eb - 1
    ba = mag >> sh
    if sh > 0:
        rm = mag - (ba << sh)
        hf = 1 << (sh - 1)
        if rm > hf:
            ba += 1
        elif rm == hf and (ba & 1):
            ba += 1
    if ba >= 16:
        ba = 8
        eb += 1
    if eb > 15:
        return (0x80 if neg else 0x00) | 0x7E
    if eb == 15 and (ba & 0xF) == 15:
        return (0x80 if neg else 0x00) | 0x7E
    return (0x80 if neg else 0x00) | ((eb & 0xF) << 3) | (ba & 0x7)

def fp8_add(a, b):
    a_nan = (a & 0x7F) == 0x7F
    b_nan = (b & 0x7F) == 0x7F
    if a_nan or b_nan:
        return 0x7F
    if (a & 0x7F) == 0 and (b & 0x7F) == 0:
        if (a & 0x80) and (b & 0x80):
            return 0x80
        return 0x00
    a_neg, a_mag = fp8_to_mag(a)
    b_neg, b_mag = fp8_to_mag(b)
    neg, mag = signed_sum(a_neg, a_mag, b_neg, b_mag)
    return fp8_encode(neg, mag)

print("Computing 65536 FP8 addition results...")
lut = []
for a in range(256):
    for b in range(256):
        lut.append(fp8_add(a, b))
print(f"Done. Non-zero entries: {sum(1 for x in lut if x != 0)}")

# Emit initial block in 16-values-per-line groups
lines = []
for i in range(0, 65536, 16):
    row = ", ".join(f"8'h{lut[i+j]:02X}" for j in range(16))
    lines.append(f"        // [{i}..{i+15}]\n        lut[{i:5d}:{i+15:5d}] = '{{{row}}};")

lut_block = "\n".join(lines)

verilog = f"""\
// ============================================================================
// FP8 E4M3 Adder -- Full Lookup Table (65536 entries, M9K block RAM)
// ============================================================================
// All 256x256 = 65536 FP8 addition results are precomputed and stored in a
// Verilog initial block that Quartus infers as M9K block RAM.
//
// M9K read latency = 1 registered clock cycle -> same 2-state design works.
//
// Pipeline per test (TC cycles):
//   FETCH(1) + WAIT_MEM(1) + LAUNCH(1) + WAIT_ADD(2) + CHECK(1) + NEXT(1) = 8
//
// Predicted scores:
//   150 MHz (D=4):  4096*8/150e6 = 219 us
//   200 MHz (D=3):  4096*8/200e6 = 164 us
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
    reg [15:0] addr_reg;   // latched {{a,b}} address for ROM

    // ---- Precomputed FP8 addition lookup table (Quartus infers M9K ROM) ----
    // 65536 entries x 8 bits = 512 Kbits = ~29 M9K blocks (50 available on DE10-Lite)
    reg [7:0] lut [0:65535];

    // Quartus infers M9K ROM from this initial block pattern.
    // Do NOT use for simulation reset — synthesis-only initialisation.
    integer _i;
    initial begin
        for (_i = 0; _i < 65536; _i = _i + 1)
            lut[_i] = 8'h00;

        // All precomputed FP8 E4M3 addition results (a in [7:0], b in [15:8] of address)
        // Address = {{a, b}}  i.e. lut[{{a,b}}] = fp8_add(a,b)
"""

# Write each address individually (most reliable for Quartus M9K inference)
addr_lines = []
for idx, val in enumerate(lut):
    if val != 0:  # sparse: only write non-zero entries (0x00 is already default)
        addr_lines.append(f"        lut[16'h{idx:04X}] = 8'h{val:02X};")

verilog += "\n".join(addr_lines)

verilog += """
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            addr_reg <= 16'd0;
            result   <= 8'd0;
            done     <= 1'b0;
            busy     <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        addr_reg <= {a, b};   // latch address; M9K read starts
                        busy     <= 1'b1;
                        state    <= S_ENCODE;
                    end
                end

                S_ENCODE: begin
                    // M9K registered output is valid now (1-cycle latency from addr latch)
                    result <= lut[addr_reg];
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
    f.write(verilog)

print(f"Written: {out_path}")
print(f"File size: {len(verilog):,} bytes")
print(f"Non-zero LUT entries written: {sum(1 for v in lut if v != 0)}")
