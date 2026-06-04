// Seven-Segment Decoder -- BCD digit to active-low 7-segment
// seg = {DP, G, F, E, D, C, B, A}  (active-low: 0 = ON)
// Supports digits 0-9. Non-digit inputs blank the display.

module seven_segment (
    input  logic [3:0] data,
    input  logic       blank,    // 1 = all segments off
    output logic [7:0] seg
);

    logic [7:0] decoded;

    always_comb begin
        case (data)
            4'h0: decoded = 8'b11000000;
            4'h1: decoded = 8'b11111001;
            4'h2: decoded = 8'b10100100;
            4'h3: decoded = 8'b10110000;
            4'h4: decoded = 8'b10011001;
            4'h5: decoded = 8'b10010010;
            4'h6: decoded = 8'b10000010;
            4'h7: decoded = 8'b11111000;
            4'h8: decoded = 8'b10000000;
            4'h9: decoded = 8'b10010000;
            default: decoded = 8'b11111111;  // Blank
        endcase
    end

    assign seg = blank ? 8'b11111111 : decoded;
endmodule
