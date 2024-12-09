#include "models/ds_cnn_stream_fe/ds_cnn.h"
#include <stdio.h>
#include "menu.h"
#include "models/ds_cnn_stream_fe/ds_cnn_stream_fe.h"
#include "tflite.h"
#include "models/label/label0_board.h"
#include "models/label/label1_board.h"
#include "models/label/label6_board.h"
#include "models/label/label8_board.h"
#include "models/label/label11_board.h"


// Initialize everything once
// deallocate tensors when done
static void ds_cnn_stream_fe_init(void) {
  tflite_load_model(ds_cnn_stream_fe, ds_cnn_stream_fe_len);
}

// TODO: Implement your design here

static int32_t* label_classify() {
  tflite_classify();

  // Process the inference results.
  float* output = tflite_get_output_float();
  return (int32_t*)output;
}

static void do_classify_label0() {
  tflite_set_input_float(label0_data);
  int32_t* result = label_classify();
  for (int i = 0; i < 12; i++)
        printf("%d: 0x%lx\n", i, result[i]);
}

static void do_classify_label1() {
  tflite_set_input_float(label1_data);
  int32_t* result = label_classify();
  for (int i = 0; i < 12; i++)
        printf("%d: 0x%lx\n", i, result[i]);
}

static void do_classify_label6() {
  tflite_set_input_float(label6_data);
  int32_t* result = label_classify();
  for (int i = 0; i < 12; i++)
        printf("%d: 0x%lx\n", i, result[i]);
}

static void do_classify_label8() {
  tflite_set_input_float(label8_data);
  int32_t* result = label_classify();
  for (int i = 0; i < 12; i++)
        printf("%d: 0x%lx\n", i, result[i]);
}

static void do_classify_label11() {
  tflite_set_input_float(label11_data);
  int32_t* result = label_classify();
  for (int i = 0; i < 12; i++)
        printf("%d: 0x%lx\n", i, result[i]);
}

static struct Menu MENU = {
    "Tests for ds_cnn_stream_fe",
    "ds_cnn_stream_fe",
    {
        MENU_ITEM('1', "Run with label 0", do_classify_label0),
        MENU_ITEM('2', "Run with label 1", do_classify_label1),
        MENU_ITEM('3', "Run with label 6", do_classify_label6),
        MENU_ITEM('4', "Run with label 8", do_classify_label8),
        MENU_ITEM('5', "Run with label 11", do_classify_label11),
        MENU_END,
    },
};

// For integration into menu system
void ds_cnn_stream_fe_menu() {
  ds_cnn_stream_fe_init();
  menu_run(&MENU);
}