module FIFO #(
  parameter DATA_WIDTH = 8,
  parameter DEPTH      = 3
) (
  input                   clk,
  input                   valid_in,
  input  [DATA_WIDTH-1:0] data_in,
  output [DATA_WIDTH-1:0] data_out,
  output                  valid_out
);

reg [DATA_WIDTH:0] not_shift_reg [DEPTH:0];
assign {data_out, valid_out} = not_shift_reg[DEPTH];

integer i;
always @(posedge clk) begin
  not_shift_reg[0] <= {data_in, valid_in};
  for (i = 0; i < DEPTH; i = i + 1) begin
    not_shift_reg[i+1] <= not_shift_reg[i];
  end
end

endmodule
