`timescale 1ns/1ps

module tb_FIR;

    localparam int TAPS        = 32;
    localparam int INPUT_WIDTH = 16;
    localparam int COEFF_WIDTH = 16;
    localparam int ACC_WIDTH   = INPUT_WIDTH + COEFF_WIDTH + $clog2(TAPS);
    localparam int FIR_LATENCY = 1 + 2 + $clog2(TAPS); // shift-reg latch + MAC latency, for reference/printing only

    logic clk;
    logic reset;            // active-low
    logic en;
    logic coeff_mem_reset;  // active-low
    logic signed [INPUT_WIDTH-1:0] data_in;
    logic signed [COEFF_WIDTH-1:0] coeff_wr_data;
    logic [$clog2(TAPS)-1:0]       coeff_addr_ext;
    logic                          coeff_wr_en;
    logic signed [ACC_WIDTH-1:0]   data_out;
    logic                          data_out_valid;

    FIR #(
        .TAPS(TAPS),
        .INPUT_WIDTH(INPUT_WIDTH),
        .COEFF_WIDTH(COEFF_WIDTH)
    ) dut (
        .clk(clk),
        .reset(reset),
        .en(en),
        .coeff_mem_reset(coeff_mem_reset),
        .data_in(data_in),
        .coeff_wr_data(coeff_wr_data),
        .coeff_addr_ext(coeff_addr_ext),
        .coeff_wr_en(coeff_wr_en),
        .data_out(data_out),
        .data_out_valid(data_out_valid)
    );

    // ---------------- Clock ----------------
    initial clk = 0;
    always #5 clk = ~clk;

    // ---------------- Shadow model: mirrors the DUT's own registers ----------------
    logic signed [INPUT_WIDTH-1:0] hist [TAPS-1:0];
    always @(posedge clk) begin
        if (!reset) begin
            for (int i = 0; i < TAPS; i++) begin
                hist[i] <= 0;
            end
        end else if (en) begin
            hist[0] <= data_in;
            for (int i = 1; i < TAPS; i++) begin
                hist[i] <= hist[i-1];
            end
        end
    end

    logic signed [COEFF_WIDTH-1:0] coeff_shadow [TAPS-1:0];
    always @(posedge clk) begin
        if (!coeff_mem_reset) begin
            for (int i = 0; i < TAPS; i++) begin
                coeff_shadow[i] <= 0;
            end
        end else if (coeff_wr_en) begin
            coeff_shadow[coeff_addr_ext] <= coeff_wr_data;
        end
    end

    // ---------------- Scoreboard ----------------
    longint expected_q[$];
    int     pass_count  = 0;
    int     fail_count  = 0;
    int     push_count  = 0;
    int     pop_count   = 0;

    // Push the expected convolution result at the same edge the DUT's shift
    // register captures a new sample -- this is the value that begins
    // propagating through the internal MAC pipeline starting this edge.
    always @(posedge clk) begin
        if (reset && en) begin
            longint acc;
            acc = 0;
            for (int i = 0; i < TAPS; i++) begin
                acc += longint'(hist[i]) * longint'(coeff_shadow[i]);
            end
            expected_q.push_back(acc);
            push_count++;
        end
    end

    // Pop and check whenever the DUT itself claims the output is valid --
    // this checks data_out_valid's timing, not just data_out's value.
    always @(posedge clk) begin
        if (data_out_valid) begin
            if (expected_q.size() > 0) begin
                longint expected;
                expected = expected_q.pop_front();
                pop_count++;
                if (data_out !== expected) begin
                    $display("[%0t] FAIL: expected=%0d got=%0d", $time, expected, data_out);
                    fail_count++;
                end else begin
                    pass_count++;
                end
            end else begin
                $display("[%0t] FAIL: data_out_valid asserted with empty expected queue", $time);
                fail_count++;
            end
        end
    end

    // ---------------- Stimulus helpers ----------------
    task automatic load_coeffs_sequential();
        for (int i = 0; i < TAPS; i++) begin
            coeff_addr_ext = i[$clog2(TAPS)-1:0];
            coeff_wr_data  = i;
            coeff_wr_en    = 1;
            @(posedge clk);
        end
        coeff_wr_en = 0;
        @(posedge clk);
    endtask

    task automatic load_coeffs_random();
        for (int i = 0; i < TAPS; i++) begin
            coeff_addr_ext = i[$clog2(TAPS)-1:0];
            coeff_wr_data  = $urandom_range(0, 200) - 100;
            coeff_wr_en    = 1;
            @(posedge clk);
        end
        coeff_wr_en = 0;
        @(posedge clk);
    endtask

    // ---------------- Waveform dump: every signal, every array element ----------------
    initial begin
        $dumpfile("results/tb_FIR.vcd");

        // Testbench shadow-model arrays
        for (int i = 0; i < TAPS; i++) begin
            $dumpvars(1, hist[i]);
            $dumpvars(1, coeff_shadow[i]);
        end

        // FIR's own internal arrays
        for (int i = 0; i < TAPS; i++) begin
            $dumpvars(1, dut.sample[i]);
            $dumpvars(1, dut.coeff_mem[i]);
        end
        // valid_pipe is sized MAC_LATENCY (2 + $clog2(TAPS)), not TAPS
        for (int i = 0; i < (2 + $clog2(TAPS)); i++) begin
            $dumpvars(1, dut.valid_pipe[i]);
        end

        // MAC submodule's internal pipeline arrays
        // (sum_stage[][] is skipped: Icarus doesn't cleanly support dumping
        // hierarchical references into a 2D unpacked array through a
        // submodule boundary. MAC's internals are already independently
        // verified by tb_MAC, so this isn't needed for FIR-level debugging.)
        for (int i = 0; i < TAPS; i++) begin
            $dumpvars(1, dut.mac.product[i]);
        end

        // Everything else (scalars, ports, etc.) at every level of hierarchy
        $dumpvars(0, tb_FIR);
    end

    // ---------------- Main sequence ----------------
    initial begin
        en             = 0;
        reset          = 0;   // assert reset (active-low)
        coeff_mem_reset= 0;   // assert coeff_mem reset (active-low)
        data_in        = 0;
        coeff_wr_en    = 0;
        coeff_addr_ext = 0;
        coeff_wr_data  = 0;
        repeat (3) @(posedge clk);

        reset           = 1;  // release
        coeff_mem_reset = 1;  // release
        @(posedge clk);

        // ---- Phase 1: simple sequential coefficients, impulse test ----
        load_coeffs_sequential();

        en = 1;
        data_in = 1;
        @(posedge clk);
        data_in = 0;
        repeat (TAPS + FIR_LATENCY + 5) @(posedge clk);

        // ---- Phase 2: reload random coefficients, then random streaming ----
        en = 0;
        @(posedge clk);
        load_coeffs_random();

        en = 1;
        repeat (200) begin
            data_in = $urandom_range(0, 200) - 100;
            @(posedge clk);
        end

        // Drain the pipeline
        en = 0;
        repeat (FIR_LATENCY + 5) @(posedge clk);

        $display("---------------------------------------------");
        $display("FIR_LATENCY (reference) = %0d cycles", FIR_LATENCY);
        $display("Pushed: %0d   Popped: %0d   Outstanding: %0d", push_count, pop_count, expected_q.size());
        $display("TEST COMPLETE: %0d passed, %0d failed", pass_count, fail_count);
        $display("---------------------------------------------");
        $finish;
    end

endmodule
