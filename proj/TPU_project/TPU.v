`include "Systolic_Array.v"

module TPU #(
  parameter INPUT_DATA_WIDTH  = 8,
  parameter OUTPUT_DATA_WIDTH = 32,
  parameter SYS_ARRAY_SIZE    = 4,
  parameter PARAMS_WIDTH      = 8,
  parameter SRAM_INDEX_WIDTH  = 12
)(
  input          clk,
  input          rst_n,

  input  [31:0]  input_offset,
  input          in_valid,
  input  [PARAMS_WIDTH-1:0] K,
  input  [PARAMS_WIDTH-1:0] M,
  input  [PARAMS_WIDTH-1:0] N,
  output reg     busy,

  output         A_wr_en,
  output [SRAM_INDEX_WIDTH-1:0] A_index,
  output [(INPUT_DATA_WIDTH*SYS_ARRAY_SIZE)-1:0] A_data_in,
  input  [(INPUT_DATA_WIDTH*SYS_ARRAY_SIZE)-1:0] A_data_out,

  output         B_wr_en,
  output [SRAM_INDEX_WIDTH-1:0] B_index,
  output [(INPUT_DATA_WIDTH*SYS_ARRAY_SIZE)-1:0] B_data_in,
  input  [(INPUT_DATA_WIDTH*SYS_ARRAY_SIZE)-1:0] B_data_out,

  output         C_wr_en,
  output [SRAM_INDEX_WIDTH-1:0] C_index,
  output [(OUTPUT_DATA_WIDTH*SYS_ARRAY_SIZE)-1:0] C_data_in,
  input  [(OUTPUT_DATA_WIDTH*SYS_ARRAY_SIZE)-1:0] C_data_out
);

//* Implement your design here
wire  [31:0]  input_offset;

// =================================================
// |                   DATA LOADER                 |
// =================================================
reg [PARAMS_WIDTH-1:0] k_r, m_r, n_r;
reg  [31:0] k_cnt,    m_cnt,    n_cnt,    c_cnt;
wire [31:0] k_cnt_a1, m_cnt_a1;
assign k_cnt_a1 = k_cnt + 1'b1;
assign m_cnt_a1 = m_cnt + 1'b1;

wire [PARAMS_WIDTH-1:0] m_r_roundup;
assign m_r_roundup = (m_r[$clog2(SYS_ARRAY_SIZE)+:PARAMS_WIDTH-$clog2(SYS_ARRAY_SIZE)]+|(m_r[0+:$clog2(SYS_ARRAY_SIZE)]));
wire [PARAMS_WIDTH-1:0] n_r_roundup;
assign n_r_roundup = (n_r[$clog2(SYS_ARRAY_SIZE)+:PARAMS_WIDTH-$clog2(SYS_ARRAY_SIZE)]+|(n_r[0+:$clog2(SYS_ARRAY_SIZE)]));

always @(posedge clk) begin
    if(in_valid) begin
        k_r <= (K < SYS_ARRAY_SIZE) ? SYS_ARRAY_SIZE : K;
        m_r <= M;
        n_r <= N;
    end
end

wire k_reset;
assign k_reset = (k_cnt_a1 == k_r);
wire m_reset;
assign m_reset = (m_cnt_a1 == m_r_roundup);

always @(posedge clk) begin
  if (in_valid || k_reset) begin
    k_cnt <= {PARAMS_WIDTH{1'b0}};
  end
  else begin
    k_cnt <= k_cnt_a1;
  end
end

always @(posedge clk) begin
  if(in_valid) begin
    m_cnt <= {PARAMS_WIDTH{1'b0}};
  end
  else if (k_reset) begin
    m_cnt <= (m_reset) ? {PARAMS_WIDTH{1'b0}} : m_cnt_a1;
  end
end

always @(posedge clk) begin
  if(in_valid) begin
    n_cnt <= {PARAMS_WIDTH{1'b0}};
  end
  else if (k_reset & m_reset) begin
    n_cnt <= n_cnt + 1'b1;
  end
end

assign A_wr_en = 0;
assign A_data_in = 0;
assign B_wr_en = 0;
assign B_data_in = 0;
// assign C_data_out = 0;

assign A_index = m_cnt * k_r + k_cnt;
assign B_index = n_cnt * k_r + k_cnt;
assign C_index = c_cnt;


// Output Signal
wire sys_arr_valid;
assign C_wr_en = sys_arr_valid;

reg sys_arr_valid_r;
always @(posedge clk) begin
  sys_arr_valid_r <= sys_arr_valid;
end

always @(posedge clk, negedge rst_n) begin
  if(~rst_n)
    busy <= 0;
  else if(in_valid)
    busy <= 1;
  else if(c_cnt >= m_r*((n_r+3)/4))
    busy <= 0;
end

always @(posedge clk) begin
  if(in_valid) begin
    c_cnt <= 0;
  end
  else if (sys_arr_valid) begin
    c_cnt <= c_cnt + 1'b1;
  end
end

integer i;
reg [SYS_ARRAY_SIZE-1:0] sys_arr_in_valid;
always @(*) begin
  if (!busy || (n_cnt >= n_r_roundup)) begin
    sys_arr_in_valid = {SYS_ARRAY_SIZE{1'b0}};
  end
  else begin
    for (i = 0; i < SYS_ARRAY_SIZE; i = i + 1) begin
      sys_arr_in_valid[i] = ((m_cnt << 2) + i < m_r);
    end
  end
end


Systolic_Array #(
  .INPUT_DATA_WIDTH(INPUT_DATA_WIDTH),
  .OUTPUT_DATA_WIDTH(OUTPUT_DATA_WIDTH),
  .SYS_ARRAY_SIZE(SYS_ARRAY_SIZE),
  .K_SIZE(PARAMS_WIDTH)
) S_ARR (
    .clk(clk),
    .rst_n(rst_n),
    .input_offset (input_offset),
    .in_valid(sys_arr_in_valid),
    .k(k_r),
    .A(A_data_out),
    .B(B_data_out),
    .out_valid(sys_arr_valid),
    .C(C_data_in)
);



endmodule
