// AXI stream wrapper for FIR filter core

module AXI_Stream #(
    parameter S_DATA_WIDTH = 16,
    parameter M_DATA_WIDTH = 37,
    parameter LATENCY      = 7
) (
    // Global Signals
    input logic clk,
    input logic reset,

    // Slave Signals - Data comes in
    input  logic signed [S_DATA_WIDTH-1:0] s_tdata,
    input  logic                           s_tvalid,
    input  logic                           s_tlast,
    output logic                           s_tready,

    // Master Signals - Data goes out
    input  logic                           m_tready,
    output logic signed [M_DATA_WIDTH-1:0] m_tdata,
    output logic                           m_tvalid,
    output logic                           m_tlast,

    // Core (To Core)
    output logic signed [S_DATA_WIDTH-1:0] core_in_data,
    output logic                           core_in_valid,
    output logic                           core_en,

    // Core (From Core)
    input logic signed [M_DATA_WIDTH-1:0] core_out_data,
    input logic                           core_out_valid
);

    // ---- Skid Buffer Registers ----
    logic                           skid_valid;
    logic signed [M_DATA_WIDTH-1:0] skid_data;
    logic                           skid_last;

    // ---- TLAST Tracking Shift Register ----
    logic        [     LATENCY-1:0] tlast_pipe;

    // ---- Decoupled Core Control ----
    // Accept new input whenever skid buffer has room
    assign s_tready      = !skid_valid;

    // Pipeline advances only on a genuine accepted input transfer.
    //
    // NOTE: the core is a single globally-enabled pipeline (see FIR.sv: `en`
    // freezes/advances every stage in lockstep, there is no per-stage
    // ready/valid, and no per-cycle "this sample doesn't count" concept).
    // Because of that, core_en must satisfy two things simultaneously:
    //   1. Never advance while the skid buffer is occupied (s_tready=0 in
    //      that case anyway) -- otherwise a beat produced while draining
    //      the skid buffer has nowhere to go and is silently lost.
    //   2. Never advance on an input "bubble" cycle (s_tvalid=0) -- for a
    //      generic pass-through core this is harmless (see AXI_Stream_tb's
    //      mock core, which tracks per-cycle validity itself and can safely
    //      absorb bubbles), but a real accumulating core like FIR.sv has no
    //      such masking: it would shift stale s_tdata into its tap delay
    //      line as if it were a genuine sample, corrupting every output sum
    //      computed over a window that includes it.
    // Tying core_en to the accepted-transfer condition satisfies both.
    assign core_en       = core_in_valid;

    // Input to core is only valid when a slave handshake occurs
    assign core_in_valid = s_tvalid && s_tready;
    assign core_in_data  = s_tdata;

    // ---- Master Output Logic ----
    assign m_tvalid      = skid_valid ? 1'b1 : core_out_valid;
    assign m_tdata       = skid_valid ? skid_data : core_out_data;
    assign m_tlast       = skid_valid ? skid_last : tlast_pipe[LATENCY-1];

    // ---- Sequential Control Logic ----
    always_ff @(posedge clk) begin
        if (!reset) begin
            tlast_pipe <= '0;
            skid_valid <= 1'b0;
            skid_data  <= '0;
            skid_last  <= 1'b0;
        end else begin
            // Shift TLAST pipeline when core advances
            if (core_en) begin
                tlast_pipe <= {tlast_pipe[LATENCY-2:0], (s_tvalid && s_tready) ? s_tlast : 1'b0};
            end

            // Skid buffer management
            if (skid_valid) begin
                if (m_tready) begin
                    skid_valid <= 1'b0;
                end
            end else begin
                if (m_tvalid && !m_tready && core_en) begin
                    skid_valid <= 1'b1;
                    skid_data  <= core_out_data;
                    skid_last  <= tlast_pipe[LATENCY-1];
                end
            end
        end
    end

endmodule