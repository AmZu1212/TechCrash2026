// bin_to_bcd.sv -- 11-bit unsigned binary to 4-digit BCD (double-dabble)
// Input range: 0-2047 (used for 0-2000 Hz)

module bin_to_bcd (
    input  logic [10:0] bin,
    output logic [3:0]  thou,   // thousands
    output logic [3:0]  hund,   // hundreds
    output logic [3:0]  tens,   // tens
    output logic [3:0]  ones    // ones
);
    // Scratch: [26:23]=thou, [22:19]=hund, [18:15]=tens, [14:11]=ones, [10:0]=binary
    logic [26:0] s;
    integer i;

    always_comb begin
        s = {16'b0, bin};
        for (i = 0; i < 11; i = i + 1) begin
            if (s[26:23] >= 4'd5) s[26:23] = s[26:23] + 4'd3;
            if (s[22:19] >= 4'd5) s[22:19] = s[22:19] + 4'd3;
            if (s[18:15] >= 4'd5) s[18:15] = s[18:15] + 4'd3;
            if (s[14:11] >= 4'd5) s[14:11] = s[14:11] + 4'd3;
            s = s << 1;
        end
        thou = s[26:23];
        hund = s[22:19];
        tens = s[18:15];
        ones = s[14:11];
    end
endmodule
