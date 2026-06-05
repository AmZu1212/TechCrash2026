// Hex nibble to active-low seven-segment.
// seg = {DP, G, F, E, D, C, B, A}; 0 = segment on.

module seven_segment (
    input  logic [3:0] value,
    input  logic       blank,
    output logic [7:0] seg
);

    always_comb begin
        if (blank) begin
            seg = 8'hFF;
        end else begin
            case (value)
                4'h0: seg = 8'b1100_0000;
                4'h1: seg = 8'b1111_1001;
                4'h2: seg = 8'b1010_0100;
                4'h3: seg = 8'b1011_0000;
                4'h4: seg = 8'b1001_1001;
                4'h5: seg = 8'b1001_0010;
                4'h6: seg = 8'b1000_0010;
                4'h7: seg = 8'b1111_1000;
                4'h8: seg = 8'b1000_0000;
                4'h9: seg = 8'b1001_0000;
                4'hA: seg = 8'b1000_1000;
                4'hB: seg = 8'b1000_0011;
                4'hC: seg = 8'b1100_0110;
                4'hD: seg = 8'b1010_0001;
                4'hE: seg = 8'b1000_0110;
                4'hF: seg = 8'b1000_1110;
                default: seg = 8'hFF;
            endcase
        end
    end

endmodule
