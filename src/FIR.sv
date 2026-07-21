module FIR  #(parameter TAPS = 32,
    INPUT_WIDTH = 16,
    COEFF_WIDTH = 16,
    ACC_WIDTH = INPUT_WIDTH + COEFF_WIDTH + $clog2(TAPS))
(
    input logic clk,
    input logic reset,
    input logic en,
    input logic coeff_mem_reset,
    input logic signed [INPUT_WIDTH-1:0] data_in,
    input logic signed [COEFF_WIDTH-1:0] coeff_wr_data,
    input logic        [$clog2(TAPS)-1:0] coeff_addr_ext,
    input logic                           coeff_wr_en,
    output logic signed [ACC_WIDTH-1:0] data_out,
    output logic data_out_valid
);

logic signed [COEFF_WIDTH-1:0] coeff_mem [TAPS-1:0]; //coeff_mem for internal coeff data transfer to MAC

always_ff @(posedge clk) begin
    if (!coeff_mem_reset) begin              //coeff_mem reset is active low
        for (int i = 0; i < TAPS; i++) begin
            coeff_mem[i] <= 0;
        end
    end
    else if (coeff_wr_en) begin
        coeff_mem[coeff_addr_ext] <= coeff_wr_data;
    end
end

logic signed [INPUT_WIDTH-1:0] sample [TAPS-1:0];   //sample for internal sample data transfer to MAC with clock delay

always_ff @(posedge clk) begin
    if (!reset) begin
        for (int i = 0; i < TAPS; i++) begin
            sample[i] <= 0;
        end
    end
    else if (en) begin
        sample[0] <= data_in;
        for (int i = 1; i < TAPS; i++) begin
            sample[i] <= sample[i-1];
        end
    end
end

MAC #(
    .N(TAPS),
    .INPUT_A_WIDTH(INPUT_WIDTH),
    .INPUT_B_WIDTH(COEFF_WIDTH)
) mac (
    .clk(clk),
    .reset(reset),
    .en(en),
    .a(sample),
    .b(coeff_mem),
    .sum_out(data_out)
);



localparam MAC_LATENCY = 2 + $clog2(TAPS);   // to account for MAC latency (7 clock cycles)

logic valid_pipe [MAC_LATENCY-1:0];

always_ff @(posedge clk) begin
    if (!reset) begin
        for (int i = 0; i < MAC_LATENCY; i++) begin
            valid_pipe[i] <= 0;
        end
    end
    else if (en) begin
        valid_pipe[0] <= 1;
        for (int i = 1; i < MAC_LATENCY; i++) begin
            valid_pipe[i] <= valid_pipe[i-1];
        end
    end
end

assign data_out_valid = valid_pipe[MAC_LATENCY-1]&&en;  //to inform the output is valid




endmodule
