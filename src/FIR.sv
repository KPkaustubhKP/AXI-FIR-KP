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
    output logic signed [ACC_WIDTH-1:0] data_out
);

logic signed [COEFF_WIDTH-1:0] coeff_mem [TAPS-1:0];

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

logic signed [INPUT_WIDTH-1:0] sample [TAPS-1:0];


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
    .INPUT_WIDTH(INPUT_WIDTH),
    .COEFF_WIDTH(COEFF_WIDTH),
    .ACC_WIDTH(ACC_WIDTH)
) mac (
    .clk(clk),
    .reset(reset),
    .en(en),
    .a(data_in),
    .b(coeff_mem),
    .sum_out(data_out)
);





endmodule


//coeff_mem for internal coeff data transfer to MAC
