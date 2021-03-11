#!/bin/env python
# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from nmigen import Mux, Signal, signed
from nmigen.sim import Settle

from nmigen_cfu import InstructionBase, SimpleElaboratable
from util import Sequencer, TestBase

from .registerfile import Xetter

INT32_MIN = 0x8000_0000
INT32_MAX = 0x7fff_ffff


class SRDHM(SimpleElaboratable):
    """Implements gemmlowp::SaturatingRoundingDoublingHighMul

    It multiplies two 32 bit numbers, then returns bits 62 to 31 of the
    64 bit result. This is 2x the high word (allowing for saturating and
    rounding).

    Implemented as a pipeline so that results are always available 3
    cycles after setting inputs.

    Note that there is a bug to investigated here. This implementation
    matches the behavior of the compiled source, however, "nudge" may be
    one of two values.

    Public Interface
    ----------------
      a: Signal(signed(32)) input
        First operand
      b: Signal(signed(32)) input
        Second operand
      result: Signal(signed(32)) output
        The result of a*b
    """

    def __init__(self):
        self.a = Signal(signed(32))
        self.b = Signal(signed(32))
        self.result = Signal(signed(32))

    def elab(self, m):
        areg = Signal.like(self.a)
        breg = Signal.like(self.b)
        ab = Signal(signed(64))
        overflow = Signal()

        # for some reason negative nudge is not used
        nudge = 1 << 30

        # cycle 0, register a and b
        m.d.sync += [
            areg.eq(self.a),
            breg.eq(self.b),
        ]
        # cycle 1, decide if this is an overflow and multiply
        m.d.sync += [
            overflow.eq((areg == INT32_MIN) & (breg == INT32_MIN)),
            ab.eq(areg * breg),
        ]
        # cycle 2, apply nudge determine result
        m.d.sync += [
            self.result.eq(Mux(overflow, INT32_MAX, (ab + nudge)[31:])),
        ]


class SRDHMInstruction(InstructionBase):
    def elab(self, m):
        m.submodules['srdhm'] = srdhm = SRDHM()
        countdown = Signal(signed(3))
        m.d.comb += self.done.eq(countdown == 0)

        m.d.comb += [
            srdhm.a.eq(self.in0),
            srdhm.b.eq(self.in1),
            self.output.eq(srdhm.result),
        ]
        with m.If(self.start):
            m.d.sync += countdown.eq(2)
        with m.Else():
            m.d.sync += countdown.eq(Mux(countdown != -1, countdown - 1, -1))


def rounding_divide_by_pot(x, exponent):
    """Implements gemmlowp::RoundingDivideByPOT

    This divides by a power of two, rounding to the nearest whole number.
    """
    mask = (1 << exponent) - 1
    remainder = x & mask
    threshold = (mask >> 1) + x[31]
    rounding = Mux(remainder > threshold, 1, 0)
    return (x >> exponent) + rounding


class RoundingDividebyPOTInstruction(InstructionBase):
    def elab(self, m):
        m.d.comb += [
            self.output.eq(rounding_divide_by_pot(self.in0s, self.in1[:5])),
            self.done.eq(1),
        ]


def clamped(value, min_bound, max_bound):
    return Mux(value < min_bound, min_bound, Mux(
        value > max_bound, max_bound, value))


class PostProcessor(SimpleElaboratable):
    """Does post-processing of an accumulator value.

    This is a pipeline: place values at inputs and outputs appear 3 cycles later.
    It is capable of producing one result per cycle.

    The function being implemented is:

    acc += param_store_read(&output_bias);
    acc = cpp_math_mul_by_quantized_mul_software(
        acc, param_store_read(&output_multiplier),
        param_store_read(&output_shift));
    acc += reg_output_offset;
    if (acc < reg_activation_min) {
        acc = reg_activation_min;
    } else if (acc > reg_activation_max) {
        acc = reg_activation_max;
    }
    return acc;

    Attributes
    ---------
    accumulator: Signal(signed(32)) input
      The accumulator value to be post processed
    bias: Signal(signed(32)) input
      Bias to add to accumulator
    multiplier: Signal(signed(32)) input
      output multiplier to apply
    shift: Signal(signed(32)) input
      shift to apply (negative for right shift)
    offset: Signal(signed(32)) input
      amount to transform output by before clamping
    activation_min: Signal(signed(32)) input
      minimum clamp for output
    activation_max: Signal(signed(32)) input
      maximum clamp for output
    result: Signal(signed(32)) output
      The post processed result
    """

    def __init__(self):
        self.accumulator = Signal(signed(32))
        self.bias = Signal(signed(32))
        self.multiplier = Signal(signed(32))
        self.shift = Signal(signed(32))
        self.offset = Signal(signed(32))
        self.activation_min = Signal(signed(32))
        self.activation_max = Signal(signed(32))
        self.result = Signal(signed(32))

    def elab(self, m):
        with_bias = Signal(signed(32))
        m.d.comb += with_bias.eq(self.accumulator + self.bias)

        # acc = cpp_math_mul_by_quantized_mul_software(
        #       acc, param_store_read(&output_multiplier),
        #       param_store_read(&output_shift));
        left_shift = Signal(5)
        right_sr = [Signal(5, name=f'right_sr_{n}') for n in range(4)]
        with m.If(self.shift > 0):
            m.d.comb += left_shift.eq(self.shift)
        with m.Else():
            m.d.comb += right_sr[0].eq(-self.shift)
        left_shifted = Signal(32)
        m.d.comb += left_shifted.eq(with_bias << left_shift),

        # Pass right shift value down through several cycles to where
        # it is needed
        for a, b in zip(right_sr, right_sr[1:]):
            m.d.sync += b.eq(a)

        # All logic is combinational up to the inputs to the SRDHM
        m.submodules['srdhm'] = srdhm = SRDHM()
        m.d.comb += [
            srdhm.a.eq(left_shifted),
            srdhm.b.eq(self.multiplier),
        ]

        # Output from SRDHM appears several cycles later
        # Logic is then combinational to output
        right_shifted = Signal(signed(32))
        m.d.comb += right_shifted.eq(
            rounding_divide_by_pot(srdhm.result, right_sr[-1]))

        # acc += reg_output_offset
        # if (acc < reg_activation_min) {
        #     acc = reg_activation_min
        # } else if (acc > reg_activation_max) {
        #     acc = reg_activation_max
        # }
        # return acc
        with_offset = Signal(signed(32))
        m.d.comb += [
            with_offset.eq(right_shifted + self.offset),
            self.result.eq(
                clamped(
                    with_offset,
                    self.activation_min,
                    self.activation_max)),
        ]


class PostProcessXetter(Xetter):
    """Does post-processing of an accumulator value.

    The output channel index is implied by processing order.

    Attributes
    ---------
    bias: Signal(signed(32)) input
      output_bias from param store
    bias_next: Signal() output
      signal that output_bias has been read
    multiplier: Signal(signed(32)) input
      output_multiplier from param store
    multiplier_next: Signal() output
      signal that output_multiplier has been read
    shift: Signal(signed(32)) input
      output_shift from param store
    shift_next: Signal() output
      signal that output_shift has been read
    offset: Signal(signed(32)) input
      amount to transform output by before clamping
    activation_min: Signal(signed(32)) input
      minimum clamp for output
    activation_max: Signal(signed(32)) input
      maximum clamp for output
    """

    def __init__(self):
        super().__init__()
        self.bias = Signal(signed(32))
        self.bias_next = Signal()
        self.multiplier = Signal(signed(32))
        self.multiplier_next = Signal()
        self.shift = Signal(signed(32))
        self.shift_next = Signal()
        self.offset = Signal(signed(32))
        self.activation_min = Signal(signed(32))
        self.activation_max = Signal(signed(32))

    def elab(self, m):
        m.submodules['pp'] = pp = PostProcessor()

        # Connections to post processor
        m.d.comb += [
            pp.accumulator.eq(self.in0.as_signed()),
            pp.bias.eq(self.bias),
            pp.multiplier.eq(self.multiplier),
            pp.shift.eq(self.shift),
            pp.offset.eq(self.offset),
            pp.activation_min.eq(self.activation_min),
            pp.activation_max.eq(self.activation_max),
            self.output.eq(pp.result),
        ]

        # Use a sequencer to count down to processing end
        m.submodules['seq'] = seq = Sequencer(4)
        m.d.comb += seq.inp.eq(self.start)

        # Other control signal outputs - set *_next to indicate values used
        # Set done to fire when calculation is complete
        m.d.comb += [
            self.bias_next.eq(self.start),
            self.multiplier_next.eq(self.start),
            self.shift_next.eq(self.start),
            self.done.eq(seq.sequence[3]),
        ]