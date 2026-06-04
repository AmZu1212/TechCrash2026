// ============================================================================
// FP8 Adder Challenge — Seven-Segment Display Driver
// ============================================================================
// DO NOT MODIFY THIS FILE
//
// Displays hex digits on DE10-Lite HEX5..HEX0
// Each input is a 4-bit hex value.
// ============================================================================

module seg7_hex (
    input  wire [3:0] hex,
    output reg  [6:0] seg   // Active low: segments [6]=g, [5]=f, ... [0]=a
);
    always @(*) begin
        case (hex)
            4'h0: seg = 7'b1000000;
            4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100;
            4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001;
            4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010;
            4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000;
            4'h9: seg = 7'b0010000;
            4'hA: seg = 7'b0001000;
            4'hB: seg = 7'b0000011;
            4'hC: seg = 7'b1000110;
            4'hD: seg = 7'b0100001;
            4'hE: seg = 7'b0000110;
            4'hF: seg = 7'b0001110;
            default: seg = 7'b1111111;
        endcase
    end
endmodule
