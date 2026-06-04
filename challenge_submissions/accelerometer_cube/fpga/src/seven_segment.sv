// Hex nibble to active-low seven-segment.
// seg = {DP, G, F, E, D, C, B, A}; 0 = segment on.

module seven_segment (
    input  logic [3:0] data,
    input  logic       blank,
    output logic [7:0] seg
);

    logic [7:0] decoded;

    always_comb begin
        case (data)
            4'h0: decoded = 8'b1100_0000;
            4'h1: decoded = 8'b1111_1001;
            4'h2: decoded = 8'b1010_0100;
            4'h3: decoded = 8'b1011_0000;
            4'h4: decoded = 8'b1001_1001;
            4'h5: decoded = 8'b1001_0010;
            4'h6: decoded = 8'b1000_0010;
            4'h7: decoded = 8'b1111_1000;
            4'h8: decoded = 8'b1000_0000;
            4'h9: decoded = 8'b1001_0000;
            4'hA: decoded = 8'b1000_1000;
            4'hB: decoded = 8'b1000_0011;
            4'hC: decoded = 8'b1100_0110;
            4'hD: decoded = 8'b1010_0001;
            4'hE: decoded = 8'b1000_0110;
            4'hF: decoded = 8'b1000_1110;
            default: decoded = 8'b1111_1111;
        endcase
    end

    assign seg = blank ? 8'b1111_1111 : decoded;

endmodule
