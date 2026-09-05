`timescale 1ns / 1ps

// =============================================================================
// AXI_Stream_tb.sv -- standalone verification of AXI_Stream.sv against a
// generic "core" (not the real FIR -- see notes on why the mock must still
// faithfully replicate FIR.sv's specific valid-signal timing).
//
// Two issues fixed here, both found by tracing real failure logs:
//
// 1. MOCK CORE VALID GATING: FIR.sv's data_out_valid is
//        assign data_out_valid = valid_pipe[FIR_LATENCY-1] && en;
//    i.e. it pulses for exactly one cycle per enable, not a level that stays
//    high until consumed. The mock core here now ANDs its own valid with
//    core_en to match exactly, so this testbench is a faithful predictor of
//    what happens with the real FIR.
//
// 2. FLUSH LOGIC: because the core only advances on a genuine accepted
//    sample (never a bare bubble -- see AXI_Stream.sv's core_en comment),
//    the last LATENCY-1 in-flight results need LATENCY-1 more clocked
//    samples (real or zero-padding) to reach the output, same as flushing
//    any real streaming FIR at the end of a burst. The first version of this
//    flush task fed zero-pad samples "while scoreboard non-empty" -- but
//    every fed sample also pushes a NEW scoreboard entry, so the queue can
//    never reach zero that way (confirmed by simulation: it ran until the
//    cycle budget expired with the same ~7-deep backlog throughout). The fix
//    is to stop *scoring* new pushes once the real data is done, while still
//    feeding the pipeline so the genuine backlog can drain out.
// =============================================================================

module AXI_Stream_tb;

    // ---- Parameters (mirror the FIR integration: 16-bit in, 37-bit out, 7-stage latency) ----
    localparam int S_DATA_WIDTH = 16;
    localparam int M_DATA_WIDTH = 37;
    localparam int LATENCY      = 7;
    localparam int CLK_PERIOD   = 10;
    localparam int NUM_SAMPLES  = 200;

    // ---- DUT signals ----
    logic clk, reset;
    logic signed [S_DATA_WIDTH-1:0] s_tdata;
    logic s_tvalid, s_tlast, s_tready;
    logic m_tready;
    logic signed [M_DATA_WIDTH-1:0] m_tdata;
    logic m_tvalid, m_tlast;

    logic signed [S_DATA_WIDTH-1:0] core_in_data;
    logic core_in_valid;
    logic core_en;
    logic signed [M_DATA_WIDTH-1:0] core_out_data;
    logic core_out_valid;

    int unsigned error_count     = 0;
    int unsigned transfer_count  = 0;  // only real, scored transfers
    int unsigned input_count     = 0;  // only real, scored inputs
    bit          scoring_active  = 1'b1;

    // ---- DUT instantiation ----
    AXI_Stream #(
        .S_DATA_WIDTH(S_DATA_WIDTH),
        .M_DATA_WIDTH(M_DATA_WIDTH),
        .LATENCY     (LATENCY)
    ) dut (
        .clk           (clk),
        .reset         (reset),
        .s_tdata       (s_tdata),
        .s_tvalid      (s_tvalid),
        .s_tlast       (s_tlast),
        .s_tready      (s_tready),
        .m_tready      (m_tready),
        .m_tdata       (m_tdata),
        .m_tvalid      (m_tvalid),
        .m_tlast       (m_tlast),
        .core_in_data  (core_in_data),
        .core_in_valid (core_in_valid),
        .core_en       (core_en),
        .core_out_data (core_out_data),
        .core_out_valid(core_out_valid)
    );

    // ---- Clock ----
    always #(CLK_PERIOD / 2) clk = ~clk;

    // =========================================================================
    // Mock core: a generic LATENCY-deep pipeline, valid gated exactly like
    // FIR.sv (see header comment). This is NOT an accumulating core -- it's a
    // pure delay line -- so this testbench only proves the AXI_Stream
    // handshake/skid-buffer logic, not filter math. Use AXI_FIR_Top_tb.sv
    // (real FIR + golden model) for that.
    // =========================================================================
    logic signed [S_DATA_WIDTH-1:0] mock_pipe [LATENCY];
    logic mock_valid[LATENCY];

    always @(posedge clk) begin
        if (!reset) begin
            for (int i = 0; i < LATENCY; i++) begin
                mock_pipe[i]  <= '0;
                mock_valid[i] <= 1'b0;
            end
        end else if (core_en) begin
            mock_pipe[0]  <= core_in_data;
            mock_valid[0] <= 1'b1;
            for (int i = 1; i < LATENCY; i++) begin
                mock_pipe[i]  <= mock_pipe[i-1];
                mock_valid[i] <= mock_valid[i-1];
            end
        end
    end

    assign core_out_data  = mock_pipe[LATENCY-1];
    assign core_out_valid = mock_valid[LATENCY-1] && core_en;  // matches FIR.sv's `&& en`

    // ---- Scoreboard ----
    typedef struct {
        logic signed [S_DATA_WIDTH-1:0] data;
        logic tlast;
    } beat_t;
    beat_t scoreboard[$];

    always @(posedge clk) begin
        if (!reset) begin
            scoreboard.delete();
        end else begin
            // Only push while scoring is active -- flush/zero-pad samples
            // fed after the real data still generate real accepted
            // transfers (needed to keep the pipeline moving), but they are
            // deliberately not tracked, or the queue could never reach zero.
            if (s_tvalid && s_tready && scoring_active) begin
                input_count++;
                scoreboard.push_back('{data: s_tdata, tlast: s_tlast});
                $display("[%0t] INPUT  #%-4d data=%7d tlast=%0b  (accepted)", $time, input_count,
                          s_tdata, s_tlast);
            end

            if (m_tvalid && m_tready) begin
                if (scoreboard.size() == 0) begin
                    // Expected during the flush tail (unscored samples exiting) --
                    // only a real problem if it happens while we still expect
                    // matching data, i.e. while scoring is active.
                    if (scoring_active) begin
                        transfer_count++;
                        $display(
                            "[%0t] OUTPUT #%-4d data=%7d tlast=%0b  expected=<none>       *** FAIL: spurious transfer, empty scoreboard ***",
                            $time, transfer_count, m_tdata, m_tlast);
                        error_count++;
                    end
                end else begin
                    beat_t exp;
                    string verdict;
                    transfer_count++;
                    exp = scoreboard.pop_front();
                    if (m_tdata === exp.data && m_tlast === exp.tlast) begin
                        verdict = "PASS";
                    end else begin
                        verdict = "FAIL";
                        error_count++;
                    end
                    $display("[%0t] OUTPUT #%-4d data=%7d tlast=%0b  expected=%7d/%0b  %s", $time,
                              transfer_count, m_tdata, m_tlast, exp.data, exp.tlast, verdict);
                end
            end
        end
    end

    // ---- Protocol check: AXI-Stream stability rule ----
    logic prev_m_tvalid, prev_m_tlast, prev_m_tready;
    logic signed [M_DATA_WIDTH-1:0] prev_m_tdata;

    always @(posedge clk) begin
        if (!reset) begin
            prev_m_tvalid <= 1'b0;
            prev_m_tready <= 1'b0;
            prev_m_tdata  <= '0;
            prev_m_tlast  <= 1'b0;
        end else begin
            if (prev_m_tvalid && !prev_m_tready) begin
                if (!m_tvalid) begin
                    $display("[%0t] *** PROTOCOL FAIL: m_tvalid dropped while stalled ***", $time);
                    error_count++;
                end
                if (m_tdata !== prev_m_tdata) begin
                    $display("[%0t] *** PROTOCOL FAIL: m_tdata changed while stalled: %0d -> %0d ***",
                              $time, prev_m_tdata, m_tdata);
                    error_count++;
                end
                if (m_tlast !== prev_m_tlast) begin
                    $display("[%0t] *** PROTOCOL FAIL: m_tlast changed while stalled ***", $time);
                    error_count++;
                end
            end
            prev_m_tvalid <= m_tvalid;
            prev_m_tdata  <= m_tdata;
            prev_m_tlast  <= m_tlast;
            prev_m_tready <= m_tready;
        end
    end

    // ---- X-check ----
    always @(posedge clk) begin
        if (reset && m_tvalid && $isunknown(m_tdata)) begin
            $display("[%0t] *** X-CHECK FAIL: m_tdata is X/Z while m_tvalid=1 ***", $time);
            error_count++;
        end
    end

    // =========================================================================
    // Driver: AXI4-Stream protocol-stable -- s_tdata/s_tvalid/s_tlast are only
    // re-randomized once the current beat has actually been accepted, never
    // while a beat is stalled awaiting s_tready.
    // =========================================================================
    task automatic drive_samples(int num_samples);
        int accepted = 0;
        logic pending = 1'b0;
        while (accepted < num_samples) begin
            @(negedge clk);
            if (!pending) begin
                s_tvalid = ($urandom_range(0, 9) < 8);  // ~80% duty cycle
                s_tdata  = $urandom_range(0, 32767) - 16384;
                s_tlast  = (accepted % 8 == 7);
            end
            pending = s_tvalid && !s_tready;
            @(posedge clk);
            if (s_tvalid && s_tready) begin
                accepted++;
                pending = 1'b0;
            end
        end
    endtask

    // Flush: stop scoring, then keep presenting real (zero-data) samples --
    // exactly like padding a real streaming FIR burst -- so the genuine
    // backlog still gets clocked out, until the (now-frozen) scoreboard
    // empties.
    task automatic flush_pipeline(int max_cycles);
        int cycles = 0;
        logic pending = 1'b0;
        scoring_active = 1'b0;
        while (scoreboard.size() != 0 && cycles < max_cycles) begin
            @(negedge clk);
            if (!pending) begin
                s_tvalid = 1'b1;
                s_tdata  = '0;
                s_tlast  = 1'b0;
            end
            pending = s_tvalid && !s_tready;
            @(posedge clk);
            if (s_tvalid && s_tready) pending = 1'b0;
            cycles++;
        end
        @(negedge clk);
        s_tvalid = 0;
        if (scoreboard.size() != 0) begin
            $display("*** FAIL: flush timed out with %0d beats never emerged ***", scoreboard.size());
            error_count++;
        end
    endtask

    // ---- Sink: randomised backpressure on m_tready ----
    initial begin
        m_tready = 0;
        forever begin
            @(negedge clk);
            m_tready = ($urandom_range(0, 9) < 7);  // ~70% ready
        end
    end

    // =========================================================================
    // Main sequence
    // =========================================================================
    initial begin
        clk      = 0;
        reset    = 0;
        s_tvalid = 0;
        s_tdata  = 0;
        s_tlast  = 0;

        $display("=================================================================");
        $display(" AXI_Stream_tb: %0d samples, LATENCY=%0d, S_WIDTH=%0d, M_WIDTH=%0d",
                  NUM_SAMPLES, LATENCY, S_DATA_WIDTH, M_DATA_WIDTH);
        $display("=================================================================");

        repeat (5) @(posedge clk);
        @(negedge clk);
        reset = 1;

        drive_samples(NUM_SAMPLES);

        $display("-----------------------------------------------------------------");
        $display(" All %0d samples presented -- flushing pipeline (feeding zero-pad", input_count);
        $display(" samples, same as flushing a real streaming FIR at end of burst)");
        $display("-----------------------------------------------------------------");

        flush_pipeline(300);

        $display("=================================================================");
        if (error_count == 0 && transfer_count == NUM_SAMPLES) begin
            $display(" PASS: %0d/%0d transfers checked, 0 errors", transfer_count, NUM_SAMPLES);
        end else begin
            $display(" FAIL: %0d/%0d transfers checked, %0d errors", transfer_count, NUM_SAMPLES,
                      error_count);
        end
        $display("=================================================================");

        $finish;
    end

endmodule