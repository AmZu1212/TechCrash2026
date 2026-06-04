`timescale 1ns/1ps

module fp8_adder_tb;

    localparam integer NUM_VECTORS = 4096;
    localparam integer TIMEOUT_CYCLES = 128;

    reg clk;
    reg rst_n;
    reg start;
    reg [7:0] a;
    reg [7:0] b;
    wire [7:0] result;
    wire done;
    wire busy;

    reg [7:0] mem_a [0:NUM_VECTORS-1];
    reg [7:0] mem_b [0:NUM_VECTORS-1];
    reg [7:0] mem_expected [0:NUM_VECTORS-1];

    integer idx;
    integer cycle_count;
    integer pass_count;
    integer fail_count;
    integer wait_cycles;

    reg [7:0] expected;

    fp8_adder dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .start  (start),
        .a      (a),
        .b      (b),
        .result (result),
        .done   (done),
        .busy   (busy)
    );

    initial begin
        clk = 1'b0;
        forever #10 clk = ~clk;
    end

    function is_nan;
        input [7:0] value;
        begin
            is_nan = (value[6:0] == 7'h7F);
        end
    endfunction

    task drive_reset;
        begin
            rst_n = 1'b0;
            start = 1'b0;
            a = 8'h00;
            b = 8'h00;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task run_one_vector;
        input integer vector_index;
        begin
            a = mem_a[vector_index];
            b = mem_b[vector_index];
            expected = mem_expected[vector_index];

            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;

            wait_cycles = 0;
            while (!done && wait_cycles < TIMEOUT_CYCLES) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end

            cycle_count = cycle_count + wait_cycles;

            if (!done) begin
                fail_count = fail_count + 1;
                $display("TIMEOUT idx=%0d a=%02x b=%02x expected=%02x busy=%0b state stalled", vector_index, a, b, expected, busy);
            end else if ((result == expected) || (is_nan(result) && is_nan(expected))) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                if (fail_count <= 20) begin
                    $display("MISMATCH idx=%0d a=%02x b=%02x got=%02x expected=%02x waited=%0d", vector_index, a, b, result, expected, wait_cycles);
                end
            end

            @(posedge clk);
        end
    endtask

    initial begin
        $readmemh("../mem/mem_a.hex", mem_a);
        $readmemh("../mem/mem_b.hex", mem_b);
        $readmemh("../mem/mem_expected.hex", mem_expected);

        cycle_count = 0;
        pass_count = 0;
        fail_count = 0;

        drive_reset();

        for (idx = 0; idx < NUM_VECTORS; idx = idx + 1) begin
            run_one_vector(idx);
        end

        $display("SUMMARY pass=%0d fail=%0d total_wait_cycles=%0d", pass_count, fail_count, cycle_count);

        if (fail_count != 0) begin
            $fatal(1, "FP8 adder testbench detected %0d failures", fail_count);
        end

        $display("FP8 adder testbench PASSED");
        $finish;
    end

endmodule