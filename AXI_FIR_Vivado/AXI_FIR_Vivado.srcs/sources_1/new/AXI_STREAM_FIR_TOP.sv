// Top-level integration: AXI4-Stream wrapper + 32-tap pipelined FIR core.

module AXI_FIR_Top #(
    parameter integer TAPS        = 32,
    parameter integer INPUT_WIDTH = 16,
    parameter integer COEFF_WIDTH = 16,
    parameter integer ACC_WIDTH   = INPUT_WIDTH + COEFF_WIDTH + $clog2(TAPS),
    parameter integer FIR_LATENCY = 2 + $clog2(TAPS)
) (
    input logic clk,
    input logic reset,  // active-low

    // ---- AXI4-Stream slave: filter input ----
    input  logic signed [INPUT_WIDTH-1:0] s_tdata,
    input  logic                          s_tvalid,
    input  logic                          s_tlast,
    output logic                          s_tready,

    // ---- AXI4-Stream master: filtered output ----
    input  logic                          m_tready,
    output logic signed [ACC_WIDTH-1:0]   m_tdata,
    output logic                          m_tvalid,
    output logic                          m_tlast,

    // ---- Coefficient load port ----
    input logic                          coeff_mem_reset, // active-low
    input logic                          coeff_wr_en,
    input logic [$clog2(TAPS)-1:0]        coeff_addr,
    input logic signed [COEFF_WIDTH-1:0] coeff_wr_data
);

    // ---- AXI_Stream <-> FIR core handshake ----
    logic signed [INPUT_WIDTH-1:0] core_in_data;
    logic                          core_in_valid;
    logic                          core_en;
    logic signed [ACC_WIDTH-1:0]   core_out_data;
    logic                          core_out_valid;

    AXI_Stream #(
        .S_DATA_WIDTH(INPUT_WIDTH),
        .M_DATA_WIDTH(ACC_WIDTH),
        .LATENCY     (FIR_LATENCY)
    ) axi_stream_inst (
        .clk            (clk),
        .reset          (reset),
        .s_tdata        (s_tdata),
        .s_tvalid       (s_tvalid),
        .s_tlast        (s_tlast),
        .s_tready       (s_tready),
        .m_tready       (m_tready),
        .m_tdata        (m_tdata),
        .m_tvalid       (m_tvalid),
        .m_tlast        (m_tlast),
        .core_in_data   (core_in_data),
        .core_in_valid  (core_in_valid),
        .core_en        (core_en),
        .core_out_data  (core_out_data),
        .core_out_valid (core_out_valid)
    );

    FIR #(
        .TAPS       (TAPS),
        .INPUT_WIDTH(INPUT_WIDTH),
        .COEFF_WIDTH(COEFF_WIDTH)
    ) fir_inst (
        .clk             (clk),
        .reset           (reset),
        .en              (core_en),
        .coeff_mem_reset (coeff_mem_reset),
        .data_in         (core_in_data),
        .coeff_wr_data   (coeff_wr_data),
        .coeff_addr_ext  (coeff_addr),
        .coeff_wr_en     (coeff_wr_en),
        .data_out        (core_out_data),
        .data_out_valid  (core_out_valid)
    );

endmodule