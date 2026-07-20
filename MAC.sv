module MAC #(parameter N = 32,
    INPUT_A_WIDTH = 16,
    INPUT_B_WIDTH = 16,
    PRODUCT_WIDTH = INPUT_A_WIDTH + INPUT_B_WIDTH,
    ACC_WIDTH = PRODUCT_WIDTH + $clog2(N)
)
(
    input logic clk,
    input logic reset,
    input logic en,
    input logic signed [INPUT_A_WIDTH-1:0] a [N],
    input logic signed [INPUT_B_WIDTH-1:0] b [N],
    output logic signed [PRODUCT_WIDTH-1:0] sum_out
);

logic signed [PRODUCT_WIDTH-1:0] product [N];
logic signed [PRODUCT_WIDTH-1:0] sum_stage [$clog2(N)];

always_ff @(posedge clk) begin
    if (reset) begin
        product <= '0;
    end
    else if (en) begin
        for (int i = 0; i < N; i++) begin
            product[i] <= a[i] * b[i];
        end
    end
end

always_ff @(posedge clk) begin
    if (reset) begin
        sum_stage <= '0;
    end
    else if (en) begin

        for (int i = 0; i < $clog2(N); i++) begin
            sum_stage[i] <= ;
        end
    end
end






endmodule
