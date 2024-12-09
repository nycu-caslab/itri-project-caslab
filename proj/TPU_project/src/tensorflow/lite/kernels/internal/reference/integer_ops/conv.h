/* Copyright 2019 The TensorFlow Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
==============================================================================*/
#ifndef TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_
#define TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_

#include <algorithm>

#include "tensorflow/lite/kernels/internal/common.h"
#include "tensorflow/lite/kernels/internal/portable_tensor_utils.h"

#include "perf.h"
#include "cfu.h"

namespace tflite {
namespace reference_integer_ops {

// Fixed-point per-channel-quantization convolution reference kernel.
inline void ConvPerChannel(
    const ConvParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int8_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_data, const RuntimeShape& bias_shape,
    const int32_t* bias_data, const RuntimeShape& output_shape,
    int8_t* output_data) {
    perf_enable_counter(6);
  // Get parameters.
  const int32_t input_offset = params.input_offset;  // r = s(q - Z)
  const int stride_width = params.stride_width;
  const int stride_height = params.stride_height;
  const int dilation_width_factor = params.dilation_width_factor;
  const int dilation_height_factor = params.dilation_height_factor;
  const int pad_width = params.padding_values.width;
  const int pad_height = params.padding_values.height;
  const int32_t output_offset = params.output_offset;

  // Set min and max value of the output.
  const int32_t output_activation_min = params.quantized_activation_min;
  const int32_t output_activation_max = params.quantized_activation_max;

  // Consistency check.
  TFLITE_DCHECK_LE(output_activation_min, output_activation_max);
  TFLITE_DCHECK_EQ(input_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(filter_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(output_shape.DimensionsCount(), 4);
  // const int batches = MatchingDim(input_shape, 0, output_shape, 0);
  const int input_depth = input_shape.Dims(3);
  const int output_depth = MatchingDim(filter_shape, 0, output_shape, 3);
  if (bias_data) {
    TFLITE_DCHECK_EQ(bias_shape.FlatSize(), output_depth);
  }

  // Check dimensions of the tensors.
  const int input_height = input_shape.Dims(1);
  const int input_width = input_shape.Dims(2);
  const int filter_height = filter_shape.Dims(1);
  const int filter_width = filter_shape.Dims(2);
  const int filter_input_depth = filter_shape.Dims(3);
  // const int groups = input_depth / filter_input_depth;
  TFLITE_DCHECK_EQ(input_depth % filter_input_depth, 0);
  // const int filters_per_group = output_depth / groups;
  const int output_height = output_shape.Dims(1);
  const int output_width = output_shape.Dims(2);

  int8_t im2col[1000][400];
  int8_t kernel[400][400];

    for (int out_y = 0; out_y < output_height; ++out_y) {
      const int in_y_origin = (out_y * stride_height) - pad_height;
      for (int out_x = 0; out_x < output_width; ++out_x) {
        const int in_x_origin = (out_x * stride_width) - pad_width;
        const int idx_y = out_y * output_width + out_x;
        for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
          const int in_y = in_y_origin + dilation_height_factor * filter_y;
          for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
            const int in_x = in_x_origin + dilation_width_factor * filter_x;

            // Zero padding by omitting the areas outside the image.
            const bool is_point_inside_image =
                (in_x >= 0) && (in_x < input_width) && (in_y >= 0) &&
                (in_y < input_height);

            for (int in_channel = 0; in_channel < filter_input_depth;
                ++in_channel) {
                int idx = in_channel * filter_height * filter_width + filter_y * filter_width + filter_x;
                if (!is_point_inside_image) {
                  im2col [idx_y][idx] = -input_offset;
                }
                else{
                  im2col [idx_y][idx] =
                      input_data[Offset(input_shape, 0, in_y, in_x,
                                        in_channel)];
                }
              }
          }
        }
      }
    }

  // printf("im2col: \n");
  // for (int i = 0; i < output_height * output_width; i++){
  //   for (int j = 0 ; j < filter_input_depth * filter_height * filter_width; j++){
  //     printf ("%x ", im2col[i][j]);
  //   }
  //   printf("\n");
  // }



  for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
      for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
          for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
            for (int in_channel = 0; in_channel < filter_input_depth;
                    ++in_channel) {
              int idx = in_channel * filter_height * filter_width + filter_y * filter_width + filter_x;
              kernel[idx][out_channel] = filter_data[Offset(
                      filter_shape, out_channel, filter_y, filter_x, in_channel)];
              }
          }
      }
  }

  // printf("kernel: \n");
  // for (int i = 0; i < filter_input_depth * filter_height * filter_width; i++){
  //   for (int j = 0 ; j < output_depth; j++){
  //     printf ("%x ", kernel[i][j]);
  //   }
  //   printf("\n");
  // }

  int32_t result_cfu[1000][1000];

  int width = filter_height * filter_width * input_depth;
  // perf_enable_counter(6);

  constexpr int T = 64; // tile size

  for  (int y = 0; y < output_height * output_width; y++){
      for (int x = 0; x < output_depth; x++){
        result_cfu[y][x] = 0;
      }
  }

  // // printf("height= %d, output_depth = %d, offset=%ld\n", output_height * output_width, output_depth, input_offset);

  for (int m = 0; m < output_height * output_width; m += T) {
    for (int n = 0; n < output_depth; n += T) {
      for (int k = 0; k < width; k += T) {
        // send to im2col buffer
        int idx = 0;
        int8_t recon[4];
        int mm = m + T < output_height * output_width ? T : output_height * output_width - m;
        int nn = n + T < output_depth ? T : output_depth - n;
        int kk = k + T < width ? T : width - k;
        // printf("tiling:\n");
        for (int yy = m; yy < m + mm; yy+=4) {
          for (int xx = k; xx < k + kk; xx++) {
            recon[3] = ( yy < output_height * output_width && xx < width ) ? im2col[yy][xx] : -(int8_t)input_offset;
            recon[2] = ( yy+1 < output_height * output_width && xx < width ) ? im2col[yy+1][xx] : -(int8_t)input_offset;
            recon[1] = ( yy+2 < output_height * output_width && xx < width ) ? im2col[yy+2][xx] : -(int8_t)input_offset;
            recon[0] = ( yy+3 < output_height * output_width && xx < width ) ? im2col[yy+3][xx] : -(int8_t)input_offset;
            cfu_op0(1, idx, *(int32_t*)recon);
            idx++;
            // printf("%lx ",  *(int32_t*)recon);
          }
          // printf("\n");
        }

        // send to kernel buffer
        // printf("tiling:\n");
        idx = 0;
        for (int xx = n; xx < nn + n; xx+=4){
          for (int yy = k; yy < kk + k; yy++){
            recon[3] = ( yy < width && xx < output_depth ) ? kernel[yy][xx] : 0;
            recon[2] = ( yy < width && xx+1 < output_depth ) ? kernel[yy][xx+1] : 0;
            recon[1] = ( yy < width && xx+2 < output_depth ) ? kernel[yy][xx+2] : 0;
            recon[0] = ( yy < width && xx+3 < output_depth ) ? kernel[yy][xx+3] : 0;
            cfu_op0(2, idx, *(int32_t*)recon);
            idx++;
            // printf("%lx ",  *(int32_t*)recon);
          }
          // printf("\n");
        }

        cfu_op0(5, kk, (nn << 8) + mm );
        cfu_op0(4, 0, input_offset);
        while(cfu_op0(6, 0, 0)) {}

        // receive from output buffer
        for (int yy = m; yy < mm + m; yy++){
          for (int xx = n; xx < nn + n; xx+=4)
            {
              int temp = yy - m + ((xx - n) / 4) * mm;
              result_cfu[yy][xx] += cfu_op0(9, temp, 0);
              result_cfu[yy][xx+1] += cfu_op0(8, temp, 0);
              result_cfu[yy][xx+2] += cfu_op0(7, temp, 0);
              result_cfu[yy][xx+3] += cfu_op0(3, temp, 0);
            }
        }

      }
    }
  }

    // perf_enable_counter(6);
    // int32_t result[1000][1000];
    // // int width = filter_height * filter_width * input_depth;
    // for  (int y = 0; y < output_height * output_width; y++){
    //   for (int x = 0; x < output_depth; x++){
    //       int32_t acc = 0;
    //       for (int i = 0; i < width; i++){
    //         acc += ((int32_t)im2col[y][i] + input_offset) * (int32_t)kernel[i][x];
    //       }
    //       result[y][x] = acc;
    //   }
    // }
    // perf_disable_counter(6);

    // printf("result: \n");
    // for  (int y = 0; y < output_height * output_width; y++){
    //   for (int x = 0; x < output_depth; x++){
    //       printf("%lx ", result[y][x]);
    //   }
    //   printf("\n");
    // }

    // printf("result_cfu: \n");
    // for  (int y = 0; y < output_height * output_width; y++){
    //   for (int x = 0; x < output_depth; x++){
    //       printf("%lx ", result_cfu[y][x]);
    //   }
    //   printf("\n");
    // }

    for (int out_y = 0; out_y < output_height; ++out_y) {
      for (int out_x = 0; out_x < output_width; ++out_x) {
        for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
        int32_t acc = result_cfu[out_y * output_width + out_x][out_channel];
        if (bias_data) {
            acc += bias_data[out_channel];
        }
        acc = MultiplyByQuantizedMultiplier(
            acc, output_multiplier[out_channel], output_shift[out_channel]);
        acc += output_offset;
        acc = std::max(acc, output_activation_min);
        acc = std::min(acc, output_activation_max);
        output_data[Offset(output_shape, 0, out_y, out_x, out_channel)] =
            static_cast<int8_t>(acc);
        }
      }
    }

  perf_disable_counter(6);
}

inline void ConvPerChannelWithPackedInt4Weights(
    const ConvParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int8_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_input, int8_t* unpacked_filter_data,
    const RuntimeShape& bias_shape, const int32_t* bias_data,
    const RuntimeShape& output_shape, int8_t* output_data) {
  TFLITE_DCHECK(unpacked_filter_data != nullptr);
  tflite::tensor_utils::UnpackDenseInt4IntoInt8(
      filter_input, filter_shape.FlatSize(), unpacked_filter_data);
  ConvPerChannel(params, output_multiplier, output_shift, input_shape,
                 input_data, filter_shape, unpacked_filter_data, bias_shape,
                 bias_data, output_shape, output_data);
}

// Fixed-point per-channel-quantization convolution reference kernel.
// 16-bit data and 8-bit filter
template <typename AccumScalar>
inline void ConvPerChannel(
    const ConvParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int16_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_data, const RuntimeShape& bias_shape,
    const AccumScalar* bias_data, const RuntimeShape& output_shape,
    int16_t* output_data) {
  // Get parameters.
  const int stride_width = params.stride_width;
  const int stride_height = params.stride_height;
  const int dilation_width_factor = params.dilation_width_factor;
  const int dilation_height_factor = params.dilation_height_factor;
  const int pad_width = params.padding_values.width;
  const int pad_height = params.padding_values.height;

  // Set min and max value of the output.
  const int32_t output_activation_min = params.quantized_activation_min;
  const int32_t output_activation_max = params.quantized_activation_max;

  // Consistency check.
  TFLITE_DCHECK_LE(output_activation_min, output_activation_max);
  TFLITE_DCHECK_EQ(input_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(filter_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(output_shape.DimensionsCount(), 4);
  const int batches = MatchingDim(input_shape, 0, output_shape, 0);
  const int input_depth = input_shape.Dims(3);
  const int output_depth = MatchingDim(filter_shape, 0, output_shape, 3);
  if (bias_data) {
    TFLITE_DCHECK_EQ(bias_shape.FlatSize(), output_depth);
  }

  // Check dimensions of the tensors.
  const int input_height = input_shape.Dims(1);
  const int input_width = input_shape.Dims(2);
  const int filter_height = filter_shape.Dims(1);
  const int filter_width = filter_shape.Dims(2);
  const int filter_input_depth = filter_shape.Dims(3);
  const int groups = input_depth / filter_input_depth;
  TFLITE_DCHECK_EQ(input_depth % filter_input_depth, 0);
  const int filters_per_group = output_depth / groups;
  const int output_height = output_shape.Dims(1);
  const int output_width = output_shape.Dims(2);
  for (int batch = 0; batch < batches; ++batch) {
    for (int out_y = 0; out_y < output_height; ++out_y) {
      const int in_y_origin = (out_y * stride_height) - pad_height;
      for (int out_x = 0; out_x < output_width; ++out_x) {
        const int in_x_origin = (out_x * stride_width) - pad_width;
        for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
          auto group = out_channel / filters_per_group;
          AccumScalar acc = 0;
          for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
            const int in_y = in_y_origin + dilation_height_factor * filter_y;
            for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
              const int in_x = in_x_origin + dilation_width_factor * filter_x;

              // Zero padding by omitting the areas outside the image.
              const bool is_point_inside_image =
                  (in_x >= 0) && (in_x < input_width) && (in_y >= 0) &&
                  (in_y < input_height);

              if (!is_point_inside_image) {
                continue;
              }

              for (int in_channel = 0; in_channel < filter_input_depth;
                   ++in_channel) {
                int32_t input_val =
                    input_data[Offset(input_shape, batch, in_y, in_x,
                                      in_channel + group * filter_input_depth)];
                int32_t filter_val = filter_data[Offset(
                    filter_shape, out_channel, filter_y, filter_x, in_channel)];
                // Accumulate with 64 bits accumulator.
                // int64_t += int8_t * int16_t so the highest value we can
                // get from each accumulation is [-127, 127] * ([-32768,
                // 32767] -
                // [-32768, 32767]), which is [-8322945, 8322945].
                // log2(8322945) = 22.99.
                acc += filter_val * input_val;
              }
            }
          }
          if (bias_data) {
            acc += bias_data[out_channel];
          }
          int32_t scaled_acc = MultiplyByQuantizedMultiplier(
              acc, output_multiplier[out_channel], output_shift[out_channel]);
          scaled_acc = std::max(scaled_acc, output_activation_min);
          scaled_acc = std::min(scaled_acc, output_activation_max);
          output_data[Offset(output_shape, batch, out_y, out_x, out_channel)] =
              static_cast<int16_t>(scaled_acc);
        }
      }
    }
  }
}

}  // namespace reference_integer_ops
}  // namespace tflite

#endif  // TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_
