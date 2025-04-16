// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>

#include "sw/device/coverage/printer.h"
#include "sw/device/coverage/runtime.h"
#include "sw/device/lib/runtime/log.h"
#include "sw/device/lib/runtime/print.h"

extern char __llvm_prf_cnts_start[];
extern char __llvm_prf_cnts_end[];
extern char __llvm_prf_data_start[];
extern char __llvm_prf_data_end[];
extern char __llvm_prf_names_start[];
extern char __llvm_prf_names_end[];
extern char _bss_start[];
extern char _bss_end[];
extern char _build_id_start[];
extern char _build_id_end[];

void coverage_init(void) {
  LOG_INFO("COVERAGE:UTTF");

  coverage_printer_init();
}

/**
 * Sends the given buffer as a hex string over dif console.
 */
void coverage_report(void) {
  LOG_INFO("cnts: %08x - %08x", __llvm_prf_cnts_start, __llvm_prf_cnts_end);
  LOG_INFO("size: %u",
           (uint32_t)__llvm_prf_cnts_end - (uint32_t)__llvm_prf_cnts_start);
  LOG_INFO("data: %08x - %08x", __llvm_prf_data_start, __llvm_prf_data_end);
  LOG_INFO("size: %u",
           (uint32_t)__llvm_prf_data_end - (uint32_t)__llvm_prf_data_start);
  LOG_INFO("name: %08x - %08x", __llvm_prf_names_start, __llvm_prf_names_end);
  LOG_INFO("size: %u",
           (uint32_t)__llvm_prf_names_end - (uint32_t)__llvm_prf_names_start);
  LOG_INFO("bss : %08x - %08x", _bss_start, _bss_end);
  LOG_INFO("size: %u", (uint32_t)_bss_end - (uint32_t)_bss_start);
  LOG_INFO("buid: %08x - %08x", _build_id_start, _build_id_end);
  LOG_INFO("size: %u", (uint32_t)_build_id_end - (uint32_t)_build_id_start);

  base_printf("== COVERAGE PROFILE START ==\r\n");
  coverage_printer_run();
  base_printf("== COVERAGE PROFILE END ==\r\n");
}

void coverage_printer_sink(const void *data, size_t size) {
  for (size_t i = 0; i < size; ++i) {
    base_printf("%02x", ((uint8_t *)data)[i]);
  }
}
