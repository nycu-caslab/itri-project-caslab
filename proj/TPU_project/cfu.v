// Copyright 2021 The CFU-Playground Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "TPU.v"
`include "global_buffer_bram.v"


module Cfu (
  input               cmd_valid,
  output              cmd_ready,
  input      [9:0]    cmd_payload_function_id,
  input      [31:0]   cmd_payload_inputs_0,
  input      [31:0]   cmd_payload_inputs_1,
  output              rsp_valid,
  input               rsp_ready,
  output     [31:0]   rsp_payload_outputs_0,
  input               reset,
  input               clk
);

  // Trivial handshaking for a combinational CFU
  assign rsp_valid = cmd_valid;
  assign cmd_ready = rsp_ready;


  //
  // select output -- note that we're not fully decoding the 3 function_id bits
  //
  assign rsp_payload_outputs_0 = (cmd_valid && (cmd_payload_function_id == {7'd1, 3'd0})) ? A_data_out :
                                 (cmd_valid && (cmd_payload_function_id == {7'd2, 3'd0})) ? B_data_out :
                                 (cmd_valid && (cmd_payload_function_id == {7'd3, 3'd0})) ? C_data_out[31:0] :
                                 (cmd_valid && (cmd_payload_function_id == {7'd7, 3'd0})) ? C_data_out[63:32] :
                                 (cmd_valid && (cmd_payload_function_id == {7'd8, 3'd0})) ? C_data_out[95:64] :
                                 (cmd_valid && (cmd_payload_function_id == {7'd9, 3'd0})) ? C_data_out[127:96] :
                                 (cmd_valid && (cmd_payload_function_id == {7'd6, 3'd0})) ? busy :
                                                                                        2'd3 ;



  wire [11:0]    A_index        = (cmd_valid && (cmd_payload_function_id == {7'd1, 3'd0} )) ? cmd_payload_inputs_0[11:0]
                                                                                                           : A_index_TPU;        
  wire [31:0]    A_data_in      = (cmd_valid && (cmd_payload_function_id == {7'd1, 3'd0})) ? cmd_payload_inputs_1 : 32'd0;    
  wire           A_wr_en        = (cmd_valid && (cmd_payload_function_id == {7'd1, 3'd0})) ? 1 : 0;     
  wire [31:0]    A_data_out; 

  wire [11:0]     B_index       = (cmd_valid && (cmd_payload_function_id == {7'd2, 3'd0})) ? cmd_payload_inputs_0[11:0]
                                                                                                           : B_index_TPU;
  wire [31:0]     B_data_in     = (cmd_valid && (cmd_payload_function_id == {7'd2, 3'd0})) ? cmd_payload_inputs_1 : 32'd0;  
  wire            B_wr_en       = (cmd_valid && (cmd_payload_function_id == {7'd2, 3'd0})) ? 1 : 0;      
  wire [31:0]    B_data_out;  

  wire [11:0]     C_index       = (cmd_valid &&  ( (cmd_payload_function_id == {7'd3, 3'd0}) 
                                                || (cmd_payload_function_id == {7'd7, 3'd0})
                                                || (cmd_payload_function_id == {7'd8, 3'd0})
                                                || (cmd_payload_function_id == {7'd9, 3'd0}))) ? cmd_payload_inputs_0[11:0]
                                                                                     : C_index_TPU;      
  wire [127:0]   C_data_in      = C_data_in_TPU;  
  wire           C_wr_en        = C_wr_en_TPU;   
  wire [127:0]   C_data_out; 


  reg [7:0]      K;
  reg [7:0]      M;
  reg [7:0]      N;

  reg            in_valid;
  reg            calculating;
  reg [31:0]     offset;

  always @(posedge clk) begin
    if (cmd_valid && (cmd_payload_function_id == {7'd5, 3'd0})) begin
        K           <= cmd_payload_inputs_0[7:0];
        M           <= cmd_payload_inputs_1[7:0];
        N           <= cmd_payload_inputs_1[15:8];
    end
  end


  always @(posedge clk) begin
    if (cmd_valid && (cmd_payload_function_id == {7'd4, 3'd0})) begin
        in_valid       <= 1'b1;
        offset         <= cmd_payload_inputs_1;
    end
    else begin
        in_valid       <= 1'b0;
    end
  end


  wire               busy;

  wire [31:0]        A_data_out_TPU = A_data_out;
  wire [31:0]        B_data_out_TPU = B_data_out;
  wire [127:0]       C_data_out_TPU = C_data_out;

  wire [11:0]    A_index_TPU; 
  wire [11:0]    B_index_TPU; 
  wire [11:0]    C_index_TPU; 

  wire [127:0]    C_data_in_TPU; 

  TPU My_TPU(
    .clk            (clk),     
    .rst_n          (~reset),   
    .input_offset   (offset),     
    .in_valid       (in_valid),         
    .K              (K), 
    .M              (M), 
    .N              (N), 
    .busy           (busy),     
    .A_wr_en        (),         
    .A_index        (A_index_TPU),         
    .A_data_in      (),         
    .A_data_out     (A_data_out_TPU),         
    .B_wr_en        (),         
    .B_index        (B_index_TPU),         
    .B_data_in      (),         
    .B_data_out     (B_data_out_TPU),         
    .C_wr_en        (C_wr_en_TPU),         
    .C_index        (C_index_TPU),         
    .C_data_in      (C_data_in_TPU),         
    .C_data_out     (C_data_out_TPU)     
);


  global_buffer_bram #(
      .ADDR_BITS(12),
      .DATA_BITS(32)
  )
  gbuff_A(
      .clk(clk),
      .rst_n(reset),
      .ram_en(1'b1),
      .wr_en(A_wr_en),
      .index(A_index),
      .data_in(A_data_in),
      .data_out(A_data_out)
  );

  global_buffer_bram #(
      .ADDR_BITS(12),
      .DATA_BITS(32)
  ) gbuff_B(
      .clk(clk),
      .rst_n(reset),
      .ram_en(1'b1),
      .wr_en(B_wr_en),
      .index(B_index),
      .data_in(B_data_in),
      .data_out(B_data_out)
  );


  global_buffer_bram #(
      .ADDR_BITS(12),
      .DATA_BITS(128)
  ) gbuff_C(
      .clk(clk),
      .rst_n(reset),
      .ram_en(1'b1),
      .wr_en(C_wr_en),
      .index(C_index),
      .data_in(C_data_in),
      .data_out(C_data_out)
  );


endmodule