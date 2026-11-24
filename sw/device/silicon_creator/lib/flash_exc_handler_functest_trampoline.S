// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "sw/device/lib/base/macros.h"

// Virtual window linker symbols referenced by `flash_exc_handler.S`, matching
// the regions defined in `hw/top_earlgrey/sw/autogen/top_earlgrey_memory.ld`.
.global _rom_ext_virtual_start_address
.equ _rom_ext_virtual_start_address, 0x90000000
.global _rom_ext_virtual_size
.equ _rom_ext_virtual_size, 0x00080000

.global _owner_virtual_start_address
.equ _owner_virtual_start_address, 0xa0000000
.global _owner_virtual_size
.equ _owner_virtual_size, 0x00080000

.section .text, "ax"
// Ibex requires `mtvec` base address to be 256-byte aligned.
.balign 256
.global flash_exc_test_vector_table
.type flash_exc_test_vector_table, @function
.extern flash_exception_handler
flash_exc_test_vector_table:
  j flash_exception_handler
.size flash_exc_test_vector_table, .-flash_exc_test_vector_table

.balign 4
.global flash_exc_test_fallback_handler
.type flash_exc_test_fallback_handler, @function
.extern _exception_frame_start
.extern flash_exc_test_fallback_count
.extern flash_exc_test_fallback_mcause
.extern flash_exc_test_fallback_mtval
flash_exc_test_fallback_handler:
  // `flash_exception_handler` transfers control here via two paths:
  // 1. `.L_no_flash_exceptions`: `sp` has already been restored from `mscratch`
  //    (so `sp != _exception_frame_start`), and no GPRs were saved.
  // 2. `.L_not_a_flash_error`: `sp == _exception_frame_start`, all GPRs
  //    (x1..x31) were saved in the frame, and the original `sp` is in
  //    `mscratch`.
  addi sp, sp, -16
  sw   t0, 0(sp)
  sw   t1, 4(sp)
  sw   t2, 8(sp)

  la   t0, flash_exc_test_fallback_count
  lw   t1, 0(t0)
  addi t1, t1, 1
  sw   t1, 0(t0)

  csrr t1, mcause
  la   t0, flash_exc_test_fallback_mcause
  sw   t1, 0(t0)

  csrr t1, mtval
  la   t0, flash_exc_test_fallback_mtval
  sw   t1, 0(t0)

  // Advance `mepc` past the faulting 32-bit uncompressed instruction.
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0

  // Check whether we arrived from `.L_not_a_flash_error` with saved frame.
  addi t0, sp, 16
  la   t1, _exception_frame_start
  beq  t0, t1, .L_restore_exception_frame

  // Came from `.L_no_flash_exceptions`: restore only the saved scratch regs.
  lw   t0, 0(sp)
  lw   t1, 4(sp)
  lw   t2, 8(sp)
  addi sp, sp, 16
  mret

.L_restore_exception_frame:
  addi sp, sp, 16
  lw   x1,  1 * OT_WORD_SIZE(sp)
  lw   x2,  2 * OT_WORD_SIZE(sp)
  lw   x3,  3 * OT_WORD_SIZE(sp)
  lw   x4,  4 * OT_WORD_SIZE(sp)
  lw   x5,  5 * OT_WORD_SIZE(sp)
  lw   x6,  6 * OT_WORD_SIZE(sp)
  lw   x7,  7 * OT_WORD_SIZE(sp)
  lw   x8,  8 * OT_WORD_SIZE(sp)
  lw   x9,  9 * OT_WORD_SIZE(sp)
  lw   x10, 10 * OT_WORD_SIZE(sp)
  lw   x11, 11 * OT_WORD_SIZE(sp)
  lw   x12, 12 * OT_WORD_SIZE(sp)
  lw   x13, 13 * OT_WORD_SIZE(sp)
  lw   x14, 14 * OT_WORD_SIZE(sp)
  lw   x15, 15 * OT_WORD_SIZE(sp)
  lw   x16, 16 * OT_WORD_SIZE(sp)
  lw   x17, 17 * OT_WORD_SIZE(sp)
  lw   x18, 18 * OT_WORD_SIZE(sp)
  lw   x19, 19 * OT_WORD_SIZE(sp)
  lw   x20, 20 * OT_WORD_SIZE(sp)
  lw   x21, 21 * OT_WORD_SIZE(sp)
  lw   x22, 22 * OT_WORD_SIZE(sp)
  lw   x23, 23 * OT_WORD_SIZE(sp)
  lw   x24, 24 * OT_WORD_SIZE(sp)
  lw   x25, 25 * OT_WORD_SIZE(sp)
  lw   x26, 26 * OT_WORD_SIZE(sp)
  lw   x27, 27 * OT_WORD_SIZE(sp)
  lw   x28, 28 * OT_WORD_SIZE(sp)
  lw   x29, 29 * OT_WORD_SIZE(sp)
  lw   x30, 30 * OT_WORD_SIZE(sp)
  lw   x31, 31 * OT_WORD_SIZE(sp)
  csrr sp, mscratch
  mret
.size flash_exc_test_fallback_handler, .-flash_exc_test_fallback_handler
