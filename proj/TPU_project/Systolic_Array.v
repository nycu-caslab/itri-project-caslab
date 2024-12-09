`include "FIFO.v"
`include "PE.v"

module Systolic_Array #(
  parameter INPUT_DATA_WIDTH  = 8,
  parameter OUTPUT_DATA_WIDTH = 32,
  parameter SYS_ARRAY_SIZE    = 4,
  parameter K_SIZE            = 8
) (
  input                                           clk,
  input                                           rst_n,
  input  [OUTPUT_DATA_WIDTH-1                 :0] input_offset,
  input  [SYS_ARRAY_SIZE-1                    :0] in_valid,
  input  [K_SIZE-1                            :0] k,
  input  [(INPUT_DATA_WIDTH*SYS_ARRAY_SIZE)-1 :0] A,
  input  [(INPUT_DATA_WIDTH*SYS_ARRAY_SIZE)-1 :0] B,
  output                                          out_valid,
  output [(OUTPUT_DATA_WIDTH*SYS_ARRAY_SIZE)-1:0] C
);

localparam ACC_SR_SIZE = SYS_ARRAY_SIZE+SYS_ARRAY_SIZE-1;

/*
 * F: FIFOs
 * P: PEs
 *           BBBB
 *           ||||
 *           vvvv
 *           ****
 *           ***F
 *           **FF
 *           *FFF
 * A -> **** PPPP
 * A -> ***F PPPP
 * A -> **FF PPPP
 * A -> *FFF PPPP
 *           FFFF
 *           FFF*
 *           FF**
 *           F***
 *           ||||
 *           vvvv
 *           CCCC
*/

wire [INPUT_DATA_WIDTH-1:0]  top_dataflow  [0:SYS_ARRAY_SIZE  ][0:SYS_ARRAY_SIZE  ];
wire [INPUT_DATA_WIDTH-1:0]  left_dataflow [0:SYS_ARRAY_SIZE  ][0:SYS_ARRAY_SIZE  ];
wire                         left_valid    [0:SYS_ARRAY_SIZE  ][0:SYS_ARRAY_SIZE  ];
wire                         top_valid     [0:SYS_ARRAY_SIZE  ][0:SYS_ARRAY_SIZE  ];
wire                         acc_valid     [0:SYS_ARRAY_SIZE-1][0:SYS_ARRAY_SIZE-1];
wire [OUTPUT_DATA_WIDTH-1:0] acc           [0:SYS_ARRAY_SIZE-1][0:SYS_ARRAY_SIZE-1];


reg  [OUTPUT_DATA_WIDTH-1:0] bottom        [0:SYS_ARRAY_SIZE-1];
reg                          s_valid       [0:SYS_ARRAY_SIZE-1];

wire                         out_valid_DE  [0:SYS_ARRAY_SIZE-1];

// =================================================
// |           CENTRAL CONTROL LOGICS              |
// =================================================
reg  [K_SIZE-1:0] acc_counter;
wire              acc_valid_test;

wire [K_SIZE-1:0] acc_counter_add_1;
assign acc_counter_add_1 = acc_counter + 1'b1;

always @(posedge clk, negedge rst_n) begin
  if (!rst_n) begin
    acc_counter <= 0;
  end
  else begin
    if (left_valid[0][0]) begin
      if (acc_counter_add_1 == k) begin
        acc_counter <= 0;
      end
      else begin
        acc_counter <= acc_counter_add_1;
      end
    end
  end
end
assign acc_valid_test = (acc_counter_add_1 == k);

reg [ACC_SR_SIZE-1:0] acc_valid_shift_reg;
always @(posedge clk, negedge rst_n) begin
  if (!rst_n) begin
    acc_valid_shift_reg <= 0;
  end
  else begin
    acc_valid_shift_reg <= {acc_valid_shift_reg[ACC_SR_SIZE-2:0], acc_valid_test};
  end
end


// =================================================
// |             FIFOs and wire routing            |
// =================================================
genvar fifo_idx;
generate
  for (fifo_idx = 0; fifo_idx < SYS_ARRAY_SIZE; fifo_idx = fifo_idx + 1) begin
    FIFO #(INPUT_DATA_WIDTH, fifo_idx) left_fifo(
      .clk       (clk),
      .valid_in  (in_valid      [fifo_idx]),
      .data_in   (A[((SYS_ARRAY_SIZE-1 - fifo_idx)*INPUT_DATA_WIDTH)+:INPUT_DATA_WIDTH]),
      .data_out  (left_dataflow [fifo_idx][0]),
      .valid_out (left_valid    [fifo_idx][0])
    );

    FIFO #(INPUT_DATA_WIDTH, fifo_idx) top_fifo(
      .clk       (clk),
      .valid_in  (in_valid[0]), // to some global valid_in
      .data_in   (B[((SYS_ARRAY_SIZE-1 - fifo_idx)*INPUT_DATA_WIDTH)+:INPUT_DATA_WIDTH]),
      .data_out  (top_dataflow[0][fifo_idx])
      // .valid_out (top_valid[0][fifo_idx])
    );

    FIFO #(OUTPUT_DATA_WIDTH, fifo_idx) out_fifo(
      .clk       (clk),
      .valid_in  (s_valid[(SYS_ARRAY_SIZE-1 - fifo_idx)]),
      .data_in   (bottom[(SYS_ARRAY_SIZE-1- fifo_idx)]),
      .data_out  (C[fifo_idx*OUTPUT_DATA_WIDTH+:OUTPUT_DATA_WIDTH]),
      .valid_out (out_valid_DE[(SYS_ARRAY_SIZE-1 - fifo_idx)])
    );

    genvar mux_valid_idx;
    wire [SYS_ARRAY_SIZE-1:0] sys_arrr_valid_row;
    for (mux_valid_idx = 0; mux_valid_idx < SYS_ARRAY_SIZE; mux_valid_idx = mux_valid_idx + 1) begin
      assign sys_arrr_valid_row[mux_valid_idx] = acc_valid[mux_valid_idx][fifo_idx];
    end

    genvar mux_data_idx;
    always @(*) begin
      s_valid[fifo_idx] = 1'b0;
      bottom[fifo_idx] = {OUTPUT_DATA_WIDTH{1'b0}};
      case (sys_arrr_valid_row)
        4'b0001: begin
          bottom[fifo_idx] = acc[0][fifo_idx];
          s_valid[fifo_idx] = 1'b1;
        end
        4'b0010: begin
          bottom[fifo_idx] = acc[1][fifo_idx];
          s_valid[fifo_idx] = 1'b1;
        end
        4'b0100: begin
          bottom[fifo_idx] = acc[2][fifo_idx];
          s_valid[fifo_idx] = 1'b1;
        end
        4'b1000: begin
          bottom[fifo_idx] = acc[3][fifo_idx];
          s_valid[fifo_idx] = 1'b1;
        end
      endcase
    end
  end
endgenerate


// =================================================
// |             PEs and wire routing             |
// =================================================
genvar row, col;
generate
  for(row = 0; row < SYS_ARRAY_SIZE; row = row + 1) begin
    for(col = 0; col < SYS_ARRAY_SIZE; col = col + 1) begin
      PE pe(
        .clk       (clk ),
        .rst_n     (rst_n),
        .input_offset(input_offset),
        .in_valid  (left_valid    [row  ][col  ]),
        .up        (top_dataflow  [row  ][col  ]),
        .left      (left_dataflow [row  ][col  ]),
        .out_valid (left_valid    [row  ][col+1]),
        .acc_reset (acc_valid     [row  ][col  ]),
        .down      (top_dataflow  [row+1][col  ]),
        .right     (left_dataflow [row  ][col+1]),
        .acc       (acc           [row  ][col  ])
      );
    end
  end
endgenerate


genvar idx_col , diff_idx, idx_row;
generate
  for (idx_row = 0; idx_row < SYS_ARRAY_SIZE; idx_row = idx_row + 1) begin
    for (idx_col = 0; idx_col < SYS_ARRAY_SIZE; idx_col = idx_col + 1) begin
      assign acc_valid[idx_row][idx_col] = (acc_valid_shift_reg[idx_row+idx_col] & left_valid[idx_row][SYS_ARRAY_SIZE]);
    end
  end
endgenerate


assign out_valid = (out_valid_DE[0]);


endmodule
