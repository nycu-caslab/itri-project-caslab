## CFU

The `Cfu` module is a control unit designed to process commands and perform specific computations based on the given function IDs. It handles input commands through the `cmd_valid` signal, decodes the `cmd_payload_function_id` to select the appropriate operation, and retrieves or stores data in three global memory buffers (A, B, and C). The module integrates with a Tensor Processing Unit (TPU) for more complex computations, generating results based on input data and parameters. It uses handshaking signals (`cmd_ready`, `rsp_valid`, and `rsp_ready`) to manage the flow of commands and responses, ensuring that the module only operates when both the command and the response are valid. Additionally, the module supports configuration via internal registers, allowing it to manage different computational tasks efficiently.

## TPU

The `TPU` module is a Tensor Processing Unit designed to perform matrix computations using a systolic array. It takes inputs such as matrix dimensions (`K`, `M`, `N`), an offset (`input_offset`), and a signal (`in_valid`) to trigger computation. The module manages counters (`k_cnt`, `m_cnt`, `n_cnt`) to track the positions in the matrices and interfaces with memory buffers (`A`, `B`, and `C`) to store and retrieve data. The systolic array performs parallel matrix operations, and the module controls when to write data to buffers using control signals (`A_wr_en`, `B_wr_en`, `C_wr_en`). The busy signal indicates when the TPU is processing, and the `sys_arr_valid` signal triggers the completion of the computation, updating the output buffer C with the result.

## Systolic Array

The `Systolic_Array` module is a key component in a parallel computing system, designed to perform matrix computations using a systolic array architecture. It takes as input matrix data `A` and `B`, as well as configuration parameters like `k`, which represents the size of the computation. The system uses FIFO buffers to manage data flow across rows and columns of the array. The module operates by shifting data through the systolic array, where each Processing Element (PE) performs partial computations and passes results down the array. The output is stored in matrix `C`. The array supports `in_valid` signals to trigger computation, and `out_valid` signals indicate when the output is ready. The system dynamically manages data flow with control logic, coordinating when data is loaded into the PEs and when the results are written back to memory.

## Global Buffer Bram

The `global_buffer_bram` module is a simple memory block that provides read and write functionality with configurable address and data bit widths. It uses block RAM (BRAM) and supports an address space of `2^ADDR_BITS` entries, each storing `DATA_BITS` bits of data. The module operates on the negative edge of the clock and performs read or write operations based on the `ram_en` and `wr_en` signals. When `wr_en` is high, data from `data_in` is written to the specified memory location (`index`), and when `wr_en` is low, data is read from that location and assigned to `data_out`. This design is useful for efficient, fast memory access in digital systems.