module AXI_SLAVE #(
    parameter INPUT_WIDTH = 16
) (
    input logic clk,
    input logic rst,

    input logic [INPUT_WIDTH -1:0]TDATA,
    input logic TVALID,
    output logic TREADY
);
assign TREADY = 1'b1;
logic [INPUT_WIDTH -1:0] TDATA_reg;


always @(posedge clk) begin


    if(!rst) begin
        TDATA_reg <= 0;
    end
    else begin
        if(TVALID && TREADY) begin
             TDATA_reg <= TDATA;
        end
    end
end

endmodule
