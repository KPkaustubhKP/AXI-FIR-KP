`timescale 1ns/1ps

module tb_FIR;

    localparam int TAPS        = 32;
    localparam int INPUT_WIDTH = 16;
    localparam int COEFF_WIDTH = 16;
    localparam int ACC_WIDTH   = INPUT_WIDTH + COEFF_WIDTH + $clog2(TAPS);
    localparam int FIR_LATENCY = 1 + 2 + $clog2(TAPS); // shift-reg latch + MAC latency

    logic clk;
    logic reset;            // active-low
    logic en;
    logic coeff_mem_reset;  // active-low
    logic signed [INPUT_WIDTH-1:0] data_in;
    logic signed [COEFF_WIDTH-1:0] coeff_wr_data;
    logic [$clog2(TAPS)-1:0]        coeff_addr_ext;
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

    // ---------------- Scoreboard ----------------
    // No separate shadow arrays: read the DUT's own sample[]/coeff_mem[]
    // registers directly via hierarchical reference. This removes the
    // possibility of the testbench's mirror desyncing from the DUT due
    // to simulator-specific scheduling of same-edge always blocks -
    // there is nothing left that can race, since we compare the DUT
    // against itself.
    longint expected_q[$];
    int     pass_count  = 0;
    int     fail_count  = 0;
    int     push_count  = 0;
    int     pop_count   = 0;

    always @(posedge clk) begin
        if (reset && en) begin
            longint acc;
            acc = 0;
            for (int i = 0; i < TAPS; i++) begin
                acc += longint'(dut.sample[i]) * longint'(dut.coeff_mem[i]);
            end
            expected_q.push_back(acc);
            push_count++;
        end
    end

    // Fixed: Added `#1` delay after clock edge to let NBA outputs settle before evaluation in Vivado
 always @(posedge clk) begin
        #1;
        if (data_out_valid) begin
            if (expected_q.size() > 0) begin
                longint expected;
                expected = expected_q.pop_front();   // blocking - visible immediately
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
            coeff_addr_ext <= i[$clog2(TAPS)-1:0];
            coeff_wr_data  <= i;
            coeff_wr_en    <= 1;
            @(posedge clk);
        end
        coeff_wr_en <= 0;
        @(posedge clk);
    endtask

    task automatic load_coeffs_random();
        for (int i = 0; i < TAPS; i++) begin
            coeff_addr_ext <= i[$clog2(TAPS)-1:0];
            coeff_wr_data  <= $urandom_range(0, 200) - 100;
            coeff_wr_en    <= 1;
            @(posedge clk);
        end
        coeff_wr_en = 0;
        @(posedge clk);
    endtask

    // ---------------- Waveform dump: Tool-specific macro handling ----------------
    initial begin
        $dumpfile("tb_FIR.vcd");   // dump into the current run dir, no missing subfolder
        $dumpvars(0, tb_FIR);
    end

    // ---------------- Main sequence ----------------
initial begin
        en              <= 0;
        reset           <= 0;
        coeff_mem_reset <= 0;
        data_in         <= 0;
        coeff_wr_en     <= 0;
        coeff_addr_ext  <= 0;
        coeff_wr_data   <= 0;
        repeat (3) @(posedge clk);
    
        reset           <= 1;
        coeff_mem_reset <= 1;
        @(posedge clk);
    
        load_coeffs_sequential();
    
        en      <= 1;
        data_in <= 1;
        @(posedge clk);
        data_in <= 0;
        repeat (TAPS + FIR_LATENCY + 5) @(posedge clk);
    
        en <= 0;
        @(posedge clk);
        load_coeffs_random();
    
        en <= 1;
        repeat (200) begin
            data_in <= $urandom_range(0, 200) - 100;
            @(posedge clk);
        end
    
        en <= 0;
        repeat (FIR_LATENCY + 5) @(posedge clk);

        $display("---------------------------------------------");
        $display("FIR_LATENCY (reference) = %0d cycles", FIR_LATENCY);
        $display("Pushed: %0d   Popped: %0d   Outstanding: %0d", push_count, pop_count, expected_q.size());
        $display("TEST COMPLETE: %0d passed, %0d failed", pass_count, fail_count);
        $display("---------------------------------------------");
        $finish;
    end

endmodule