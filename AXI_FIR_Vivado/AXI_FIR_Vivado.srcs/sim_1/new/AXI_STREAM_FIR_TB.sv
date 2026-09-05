`timescale 1ns / 1ps

// =============================================================================
// AXI_FIR_Top_tb.sv
//
// Fix vs. the previous version, found from a real failure log (not guessed):
//
// 1. FLUSH: `drain_pipeline` used to just assert m_tready and wait with
//    s_tvalid=0. The core only ever advances on a genuine accepted sample
//    (see AXI_Stream.sv's core_en comment), so nothing could flush without
//    continued input -- the old task always timed out with residual beats
//    stuck in the pipe. Fixed by continuing to feed zero-pad samples (same
//    idea as flushing a real streaming FIR at the end of a burst) until the
//    *scored* backlog empties.
//
// 2. COEFFICIENT-CHANGE HAZARD: because the flush above never actually
//    completed, Phase 2's load_coeffs() started overwriting coeff_mem while
//    Phase 1 data was still mid-flight through the MAC's product/adder-tree
//    pipeline -- some in-flight partial computations then used a mix of old
//    and new coefficients, which is a genuine hazard for this core (there is
//    no double-buffered coefficient memory or pipeline-drain interlock).
//    Fixed by extending the flush with a fixed LATENCY-cycle settle margin
//    *after* the scored backlog empties, guaranteeing every in-flight
//    computation (scored or not) has fully retired before any coefficients
//    are changed.
// =============================================================================

module AXI_FIR_Top_tb;

    // ---- Parameters (match DUT defaults) ----
    localparam integer TAPS        = 32;
    localparam integer INPUT_WIDTH = 16;
    localparam integer COEFF_WIDTH = 16;
    localparam integer ACC_WIDTH   = INPUT_WIDTH + COEFF_WIDTH + $clog2(TAPS);
    localparam integer FIR_LATENCY = 2 + $clog2(TAPS);
    localparam integer CLK_PERIOD  = 10;

    // ---- DUT signals ----
    logic clk, reset;
    logic signed [INPUT_WIDTH-1:0] s_tdata;
    logic s_tvalid, s_tlast, s_tready;
    logic m_tready;
    logic signed [ACC_WIDTH-1:0] m_tdata;
    logic m_tvalid, m_tlast;
    logic coeff_mem_reset, coeff_wr_en;
    logic [$clog2(TAPS)-1:0] coeff_addr;
    logic signed [COEFF_WIDTH-1:0] coeff_wr_data;

    int unsigned error_count    = 0;
    int unsigned transfer_count = 0;  // only real, scored transfers
    bit          scoring_active = 1'b1;

    // ---- DUT instantiation ----
    AXI_FIR_Top #(
        .TAPS(TAPS),
        .INPUT_WIDTH(INPUT_WIDTH),
        .COEFF_WIDTH(COEFF_WIDTH)
    ) dut (
        .clk(clk),
        .reset(reset),
        .s_tdata(s_tdata),
        .s_tvalid(s_tvalid),
        .s_tlast(s_tlast),
        .s_tready(s_tready),
        .m_tready(m_tready),
        .m_tdata(m_tdata),
        .m_tvalid(m_tvalid),
        .m_tlast(m_tlast),
        .coeff_mem_reset(coeff_mem_reset),
        .coeff_wr_en(coeff_wr_en),
        .coeff_addr(coeff_addr),
        .coeff_wr_data(coeff_wr_data)
    );

    // ---- Clock ----
    always #(CLK_PERIOD / 2) clk = ~clk;

    // ---- Golden reference model ----
    logic signed [INPUT_WIDTH-1:0] sw_sample[TAPS];
    logic signed [COEFF_WIDTH-1:0] sw_coeff[TAPS];

    typedef struct {
        logic signed [ACC_WIDTH-1:0] data;
        logic tlast;
    } beat_t;
    beat_t scoreboard[$];

    function automatic logic signed [ACC_WIDTH-1:0] golden_sum();
        logic signed [ACC_WIDTH-1:0] acc;
        acc = '0;
        for (int i = 0; i < TAPS; i++) begin
            acc += sw_sample[i] * sw_coeff[i];
        end
        return acc;
    endfunction

    // ---- Coefficient load task ----
    // NOTE: only safe to call once the pipeline is fully flushed (see
    // flush_pipeline below) -- otherwise in-flight computations can end up
    // using a mix of old and new coefficients.
    task automatic load_coeffs(input logic signed [COEFF_WIDTH-1:0] coeffs[TAPS]);
        @(negedge clk);
        coeff_mem_reset = 1'b0;  // active-low clear
        @(negedge clk);
        coeff_mem_reset = 1'b1;
        for (int i = 0; i < TAPS; i++) begin
            @(negedge clk);
            coeff_wr_en   = 1'b1;
            coeff_addr    = i[$clog2(TAPS)-1:0];
            coeff_wr_data = coeffs[i];
            sw_coeff[i]   = coeffs[i];
        end
        @(negedge clk);
        coeff_wr_en = 1'b0;
    endtask

    // ---- Scoreboard ----
    always @(posedge clk) begin
        if (!reset) begin
            for (int i = 0; i < TAPS; i++) sw_sample[i] = '0;
            scoreboard.delete();
        end else begin
            if (s_tvalid && s_tready) begin
                // Always shift the software tap-line model, matching real
                // hardware exactly, regardless of whether this particular
                // sample is being scored (flush/zero-pad samples still
                // physically shift through the real tap line).
                for (int i = TAPS - 1; i > 0; i--) sw_sample[i] = sw_sample[i-1];
                sw_sample[0] = s_tdata;
                if (scoring_active) begin
                    beat_t push_item;
                    push_item.data  = golden_sum();
                    push_item.tlast = s_tlast;
                    scoreboard.push_back(push_item);
                end
            end

            if (m_tvalid && m_tready) begin
                if (scoreboard.size() == 0) begin
                    // Expected during the flush settle margin (unscored
                    // stragglers exiting) -- only a real problem while we
                    // still expect matching data.
                    if (scoring_active) begin
                        transfer_count++;
                        $error("[%0t] Output beat with empty scoreboard - spurious transfer", $time);
                        error_count++;
                    end
                end else begin
                    beat_t exp;
                    transfer_count++;
                    exp = scoreboard.pop_front();
                    if (m_tdata !== exp.data) begin
                        $error("[%0t] DATA mismatch: got %0d expected %0d", $time, m_tdata, exp.data);
                        error_count++;
                    end
                    if (m_tlast !== exp.tlast) begin
                        $error("[%0t] TLAST mismatch: got %0b expected %0b (data=%0d)", $time,
                                m_tlast, exp.tlast, exp.data);
                        error_count++;
                    end
                end
            end
        end
    end

    // ---- Protocol check ----
    logic prev_m_tvalid, prev_m_tlast, prev_m_tready;
    logic signed [ACC_WIDTH-1:0] prev_m_tdata;

    always @(posedge clk) begin
        if (!reset) begin
            prev_m_tvalid <= 1'b0;
            prev_m_tready <= 1'b0;
            prev_m_tdata  <= '0;
            prev_m_tlast  <= 1'b0;
        end else begin
            if (prev_m_tvalid && !prev_m_tready) begin
                if (!m_tvalid) begin
                    $error("[%0t] m_tvalid dropped while stalled", $time);
                    error_count++;
                end
                if (m_tdata !== prev_m_tdata) begin
                    $error("[%0t] m_tdata changed while stalled: %0d -> %0d", $time, prev_m_tdata,
                            m_tdata);
                    error_count++;
                end
                if (m_tlast !== prev_m_tlast) begin
                    $error("[%0t] m_tlast changed while stalled", $time);
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
            $error("[%0t] m_tdata is X/Z while m_tvalid=1", $time);
            error_count++;
        end
    end

    // =========================================================================
    // Driver: AXI4-Stream protocol-stable -- s_tdata/s_tvalid/s_tlast only
    // re-randomize once the current beat has actually been accepted, never
    // while stalled awaiting s_tready.
    // =========================================================================
    task automatic drive_input(int num_samples, int data_lo, int data_hi);
        int accepted = 0;
        logic pending = 1'b0;
        while (accepted < num_samples) begin
            @(negedge clk);
            if (!pending) begin
                s_tvalid = ($urandom_range(0, 9) < 8);  // ~80% duty cycle
                s_tdata  = $urandom_range(data_lo, data_hi);
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

    // ---- Sink ----
    logic force_mready = 1'b0;

    initial begin
        m_tready = 0;
        forever begin
            @(negedge clk);
            m_tready = force_mready ? 1'b1 : ($urandom_range(0, 9) < 7);  // ~70% ready
        end
    end

    // Flush: stop scoring, keep feeding real (zero-data) samples so the
    // scored backlog can drain, then feed a fixed LATENCY-cycle settle
    // margin so any still-in-flight computation (scored or not) fully
    // retires before it's safe to change coefficients or reset again.
    task automatic flush_pipeline(int max_cycles);
        int cycles = 0;
        logic pending = 1'b0;
        scoring_active = 1'b0;
        force_mready = 1'b1;

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

        if (scoreboard.size() != 0) begin
            $error("Scoreboard not empty after flush: %0d beats never emerged", scoreboard.size());
            error_count++;
        end

        // Settle margin: guarantee no straggler (scored or not) is still
        // mid-pipeline before returning -- otherwise it could retire during
        // the next phase and get mismatched against unrelated real data.
        for (int i = 0; i < FIR_LATENCY; i++) begin
            @(negedge clk);
            if (!pending) begin
                s_tvalid = 1'b1;
                s_tdata  = '0;
                s_tlast  = 1'b0;
            end
            pending = s_tvalid && !s_tready;
            @(posedge clk);
            if (s_tvalid && s_tready) pending = 1'b0;
        end

        @(negedge clk);
        s_tvalid = 0;
        force_mready = 1'b0;
        scoring_active = 1'b1;
    endtask

    // ---- Main sequence ----
    logic signed [COEFF_WIDTH-1:0] impulse_coeffs[TAPS];
    logic signed [COEFF_WIDTH-1:0] random_coeffs [TAPS];

    initial begin
        clk = 0;
        reset = 0;
        s_tvalid = 0;
        s_tdata = 0;
        s_tlast = 0;
        coeff_mem_reset = 0;
        coeff_wr_en = 0;
        coeff_addr = 0;
        coeff_wr_data = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        reset = 1;

        // ---- Phase 1: impulse response ----
        impulse_coeffs[0] = 16'sd1;
        for (int i = 1; i < TAPS; i++) impulse_coeffs[i] = 16'sd0;
        load_coeffs(impulse_coeffs);

        drive_input(64, -16384, 16383);
        flush_pipeline(300);

        $display("---- Phase 1 (impulse response) done: %0d transfers, %0d errors so far ----",
                 transfer_count, error_count);

        // ---- Phase 2: randomized coefficients, randomized data ----
        // Safe to reload coefficients now -- flush_pipeline guarantees the
        // pipeline is fully idle, no in-flight computation left over.
        for (int i = 0; i < TAPS; i++) random_coeffs[i] = $urandom_range(0, 2000) - 1000;
        load_coeffs(random_coeffs);

        drive_input(300, -16384, 16383);
        flush_pipeline(300);

        if (error_count == 0) $display("PASS: %0d transfers checked, 0 errors", transfer_count);
        else $display("FAIL: %0d transfers checked, %0d errors", transfer_count, error_count);

        $finish;
    end

endmodule