// ============================================================================
// FP8 Adder Challenge — Test Controller & Performance Counter
// ============================================================================
// DO NOT MODIFY THIS FILE — this is the test harness.
// Teams may only modify fp8_adder.v and challenge_pll.v
//
// This module:
//   1. Reads operands A, B from memory
//   2. Feeds them to the fp8_adder
//   3. Compares result against expected value from memory
//   4. Counts total clock cycles (debug/performance insight)
//   5. Reports pass/fail count
// ============================================================================

module test_controller (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,       // KEY press to start test

    // Memory interfaces (directly wired to ROM)
    output reg  [11:0] mem_addr,    // 4096 vectors
    input  wire [7:0]  mem_a_data,
    input  wire [7:0]  mem_b_data,
    input  wire [7:0]  mem_exp_data,

    // FP8 adder interface
    output reg  [7:0]  adder_a,
    output reg  [7:0]  adder_b,
    output reg         adder_start,
    input  wire [7:0]  adder_result,
    input  wire        adder_done,
    input  wire        adder_busy,

    // Status outputs
    output reg  [31:0] cycle_count,   // Total cycles from start to finish
    output reg  [11:0] pass_count,    // Vectors that matched
    output reg  [11:0] fail_count,    // Vectors that mismatched
    output reg  [11:0] test_index,    // Current test being run
    output reg         running,       // Test in progress
    output reg         finished       // All tests complete
);

    localparam NUM_VECTORS = 12'd4096;

    // States
    localparam TC_IDLE     = 3'd0;
    localparam TC_FETCH    = 3'd1;
    localparam TC_WAIT_MEM = 3'd2;
    localparam TC_LAUNCH   = 3'd3;
    localparam TC_WAIT_ADD = 3'd4;
    localparam TC_CHECK    = 3'd5;
    localparam TC_NEXT     = 3'd6;
    localparam TC_DONE     = 3'd7;

    reg [2:0] state;
    reg [7:0] expected_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= TC_IDLE;
            mem_addr     <= 12'd0;
            adder_a      <= 8'd0;
            adder_b      <= 8'd0;
            adder_start  <= 1'b0;
            cycle_count  <= 32'd0;
            pass_count   <= 12'd0;
            fail_count   <= 12'd0;
            test_index   <= 12'd0;
            running      <= 1'b0;
            finished     <= 1'b0;
            expected_reg <= 8'd0;
        end else begin
            adder_start <= 1'b0;  // default: no start pulse

            case (state)
                // ─────────────────────────────────────────────
                TC_IDLE: begin
                    if (start) begin
                        running     <= 1'b1;
                        finished    <= 1'b0;
                        cycle_count <= 32'd0;
                        pass_count  <= 12'd0;
                        fail_count  <= 12'd0;
                        test_index  <= 12'd0;
                        mem_addr    <= 12'd0;
                        state       <= TC_FETCH;
                    end
                end

                // ─────────────────────────────────────────────
                TC_FETCH: begin
                    // Address is set, wait 1 cycle for ROM latency
                    mem_addr <= test_index;
                    cycle_count <= cycle_count + 32'd1;
                    state <= TC_WAIT_MEM;
                end

                // ─────────────────────────────────────────────
                TC_WAIT_MEM: begin
                    // Memory data available now
                    adder_a      <= mem_a_data;
                    adder_b      <= mem_b_data;
                    expected_reg <= mem_exp_data;
                    cycle_count  <= cycle_count + 32'd1;
                    state        <= TC_LAUNCH;
                end

                // ─────────────────────────────────────────────
                TC_LAUNCH: begin
                    adder_start <= 1'b1;
                    cycle_count <= cycle_count + 32'd1;
                    state       <= TC_WAIT_ADD;
                end

                // ─────────────────────────────────────────────
                TC_WAIT_ADD: begin
                    cycle_count <= cycle_count + 32'd1;
                    if (adder_done) begin
                        state <= TC_CHECK;
                    end
                end

                // ─────────────────────────────────────────────
                TC_CHECK: begin
                    cycle_count <= cycle_count + 32'd1;
                    // Compare result to expected
                    // Special NaN handling: any NaN matches any NaN
                    if ((adder_result == expected_reg) ||
                        (adder_result[6:0] == 7'h7F && expected_reg[6:0] == 7'h7F)) begin
                        pass_count <= pass_count + 12'd1;
                    end else begin
                        fail_count <= fail_count + 12'd1;
                    end
                    state <= TC_NEXT;
                end

                // ─────────────────────────────────────────────
                TC_NEXT: begin
                    cycle_count <= cycle_count + 32'd1;
                    if (test_index == NUM_VECTORS - 12'd1) begin
                        state <= TC_DONE;
                    end else begin
                        test_index <= test_index + 12'd1;
                        state      <= TC_FETCH;
                    end
                end

                // ─────────────────────────────────────────────
                TC_DONE: begin
                    running  <= 1'b0;
                    finished <= 1'b1;
                    state    <= TC_IDLE;  // Can restart with another KEY press
                end

                default: state <= TC_IDLE;
            endcase
        end
    end

endmodule
