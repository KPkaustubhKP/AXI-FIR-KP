`timescale 1ns/1ps

module tb_MAC;

    localparam int N              = 32;
    localparam int INPUT_A_WIDTH  = 16;
    localparam int INPUT_B_WIDTH  = 16;
    localparam int PRODUCT_WIDTH  = INPUT_A_WIDTH + INPUT_B_WIDTH;
    localparam int ACC_WIDTH      = PRODUCT_WIDTH + $clog2(N);
    localparam int STAGES         = $clog2(N);
    localparam int LATENCY        = STAGES + 2; // product reg + stage0 seed reg + tree stages

    logic clk;
    logic reset;   // active-low, per MAC's current convention
    logic en;
    logic signed [INPUT_A_WIDTH-1:0] a [N];
    logic signed [INPUT_B_WIDTH-1:0] b [N];
    logic signed [ACC_WIDTH-1:0]     sum_out;

    MAC #(
        .N(N),
        .INPUT_A_WIDTH(INPUT_A_WIDTH),
        .INPUT_B_WIDTH(INPUT_B_WIDTH)
    ) dut (
        .clk     (clk),
        .reset   (reset),
        .en      (en),
        .a       (a),
        .b       (b),
        .sum_out (sum_out)
    );

    // ---------------- Clock ----------------
    initial clk = 0;
    always #5 clk = ~clk;

    // ---------------- Scoreboard ----------------
    longint expected_q[$];
    int     pass_count  = 0;
    int     fail_count  = 0;
    int     cycle_count = 0;

    // Push the expected result whenever the pipeline is actually advancing.
    // Computed inline (not via a function) since Icarus doesn't yet support
    // unpacked-array function ports.
    always @(posedge clk) begin
        if (reset && en) begin
            longint acc;
            acc = 0;
            for (int i = 0; i < N; i++) begin
                acc += longint'(a[i]) * longint'(b[i]);
            end
            expected_q.push_back(acc);
        end
    end

    // Pop and check once enough enabled cycles have elapsed
    always @(posedge clk) begin
        if (!reset) begin
            cycle_count <= 0;
        end else if (en) begin
            cycle_count <= cycle_count + 1;
            if (cycle_count >= LATENCY && expected_q.size() > 0) begin
                longint expected;
                expected = expected_q.pop_front();
                if (sum_out !== expected) begin
                    $display("[%0t] FAIL: expected=%0d got=%0d", $time, expected, sum_out);
                    fail_count++;
                end else begin
                    pass_count++;
                end
            end
        end
    end

    // ---------------- Stimulus helpers ----------------
    task automatic drive_all(input logic signed [INPUT_A_WIDTH-1:0] a_val,
                              input logic signed [INPUT_B_WIDTH-1:0] b_val);
        for (int i = 0; i < N; i++) begin
            a[i] = a_val;
            b[i] = b_val;
        end
    endtask

    task automatic drive_random();
        for (int i = 0; i < N; i++) begin
            a[i] = $urandom_range(0, (1 << INPUT_A_WIDTH) - 1);
            b[i] = $urandom_range(0, (1 << INPUT_B_WIDTH) - 1);
        end
    endtask

    // ---------------- Main sequence ----------------
    initial begin
        en    = 0;
        reset = 0;              // assert reset (active-low)
        drive_all(0, 0);
        repeat (3) @(posedge clk);
        reset = 1;              // release reset
        @(posedge clk);

        en = 1;

        // Directed: all zeros
        drive_all(0, 0);
        @(posedge clk);

        // Directed: all ones
        drive_all(1, 1);
        @(posedge clk);

        // Directed: max positive values (near overflow boundary)
        drive_all((1 << (INPUT_A_WIDTH - 1)) - 1, (1 << (INPUT_B_WIDTH - 1)) - 1);
        @(posedge clk);

        // Directed: negative operands (sign handling)
        drive_all(-1, 1);
        @(posedge clk);
        drive_all(-5, -5);
        @(posedge clk);

        // Directed: single active tap, rest zero
        drive_all(0, 0);
        a[0] = 100;
        b[0] = 100;
        @(posedge clk);

        // Randomized cases
        repeat (50) begin
            drive_random();
            @(posedge clk);
        end

        // Drain the pipeline before checking is done
        en = 0;
        repeat (LATENCY + 5) @(posedge clk);

        $display("---------------------------------------------");
        $display("TEST COMPLETE: %0d passed, %0d failed", pass_count, fail_count);
        $display("---------------------------------------------");
        $finish;
    end
    initial begin
        $dumpfile("results/mac_tb.vcd");
        for (int i = 0; i < N; i++) begin
            $dumpvars(1, a[i]);
            $dumpvars(1, b[i]);
        end
        $dumpvars(0, tb_MAC);
    end

endmodule
