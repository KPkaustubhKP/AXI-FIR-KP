module MAC #(
    parameter N = 32,
    INPUT_A_WIDTH = 16,
    INPUT_B_WIDTH = 16,
    PRODUCT_WIDTH = INPUT_A_WIDTH + INPUT_B_WIDTH,
    ACC_WIDTH = PRODUCT_WIDTH + $clog2(N)
) (
    input logic clk,
    input logic reset,
    input logic en,
    input logic signed [INPUT_A_WIDTH-1:0] a[N],
    input logic signed [INPUT_B_WIDTH-1:0] b[N],
    output logic signed [ACC_WIDTH-1:0] sum_out
);

    logic signed [PRODUCT_WIDTH-1:0] product[N];
    logic signed [ACC_WIDTH-1:0] sum_stage[$clog2(N)+1][N];

    always_ff @(posedge clk) begin
        if (!reset) begin
            for (int i = 0; i < N; i++) begin
                product[i] <= '0;
            end
        end else if (en) begin
            for (int i = 0; i < N; i++) begin
                product[i] <= a[i] * b[i];
            end
        end
    end

    //Seed stage 0

    always_ff @(posedge clk) begin
        if (!reset) begin
            for (int i = 0; i < N; i++) begin
                sum_stage[0][i] <= '0;
            end
        end else if (en) begin
            for (int i = 0; i < N; i++) begin
                sum_stage[0][i] <= product[i];
            end
        end
    end


    //Adder Tree
    generate
        for (genvar s = 0; s < $clog2(N); s++) begin : gen_sum_stages
            localparam int Pairs = N >> (s + 1);
            always_ff @(posedge clk) begin
                if (!reset) begin
                    for (int i = 0; i < Pairs; i++) begin
                        sum_stage[s+1][i] <= 0;
                    end
                end else if (en) begin
                    for (int i = 0; i < Pairs; i++) begin
                        sum_stage[s+1][i] <= sum_stage[s][i*2] + sum_stage[s][i*2+1];
                    end
                end
            end
        end
    endgenerate


    assign sum_out = sum_stage[$clog2(N)][0];




endmodule
