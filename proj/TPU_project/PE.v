module PE
#(
    parameter IN_DATA_SZ  = 8,
    parameter OUT_DATA_SZ = 32,
    parameter K_SZ        = 8
)
(
    input                    clk,
    input                    rst_n,
    input                    in_valid,
    input  [OUT_DATA_SZ-1 :0] input_offset,
    input  [IN_DATA_SZ-1 :0] up,
    input  [IN_DATA_SZ-1 :0] left,
    input                    acc_reset,
    output                   out_valid,
    output [IN_DATA_SZ-1 :0] down,
    output [IN_DATA_SZ-1 :0] right,
    output [OUT_DATA_SZ-1:0] acc
);

// =================================================
// |                     DFF                       |
// =================================================
reg                   out_valid_r;
reg [IN_DATA_SZ-1 :0] down_r;
reg [IN_DATA_SZ-1 :0] right_r;
reg [OUT_DATA_SZ-1:0] sum_r;

// =================================================
// |                 CHENG JIA CHI                 |
// =================================================

reg  [OUT_DATA_SZ-1:0] c;
wire [OUT_DATA_SZ-1:0] cheng_jia_chi;
wire  [31:0]           input_offset;

wire [31:0] left_extend;
assign left_extend = {{24{left[7]}}, left};
wire [31:0] up_extend;
assign up_extend = {{24{up[7]}}, up};

assign cheng_jia_chi = ( $signed(left_extend) + $signed(input_offset)) * $signed(up_extend) + $signed(c);

always @(*) begin
    if (!out_valid_r | acc_reset) c = {OUT_DATA_SZ{1'b0}};
    else                             c = sum_r;
end


// =================================================
// |                   LOGICS                      |
// =================================================

always @(posedge clk) begin
    out_valid_r <= in_valid;
end
assign out_valid = out_valid_r;

always @(posedge clk) begin
    down_r <= up;
end
assign down = down_r;

always @(posedge clk) begin
    right_r <= left;
end
assign right = right_r;


always @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
        sum_r <= {K_SZ{1'b0}};
    end
    else begin
        sum_r <= cheng_jia_chi;
    end
end
assign acc = sum_r;




endmodule
