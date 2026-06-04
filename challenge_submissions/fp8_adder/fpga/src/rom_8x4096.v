// ============================================================================
// Simple synchronous ROM with $readmemh initialization
// ============================================================================
// DO NOT MODIFY THIS FILE
//
// Synthesizes to LUT-based ROM. Initialized from .hex file at compile time.
// ============================================================================

module rom_8x4096 #(
    parameter INIT_FILE = "mem/mem_a.hex"
) (
    input  wire        clock,
    input  wire [11:0] address,
    output reg  [7:0]  q
);

    reg [7:0] mem [0:4095];

    initial begin
        $readmemh(INIT_FILE, mem);
    end

    always @(posedge clock) begin
        q <= mem[address];
    end

endmodule
