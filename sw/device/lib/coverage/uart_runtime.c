// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "sw/device/lib/arch/device.h"
#include "sw/device/lib/coverage/printer.h"
#include "sw/device/silicon_creator/lib/dbg_print.h"
#include "sw/device/silicon_creator/lib/drivers/pinmux.h"
#include "sw/device/silicon_creator/lib/drivers/uart.h"

void coverage_transport_init(void) {
  pinmux_init_uart0_tx();
  uart_init(kUartNCOValue);

  dbg_puts("COVERAGE:UART\r\n");
  while (!uart_tx_idle()) {
  }
}

static void coverage_report_desc(const coverage_profile_desc_t *desc) {
  if (coverage_is_valid_desc(desc)) {
    dbg_puts("== COVERAGE PROFILE START ==\r\n");
    coverage_printer_run_desc(desc);
    dbg_puts("== COVERAGE PROFILE END ==\r\n");
  } else {
    dbg_puts("== COVERAGE PROFILE INVALID ==\r\n");
  }

  // Wait until the report is sent.
  while (!uart_tx_idle()) {
  }
}

void coverage_report(void) {
  coverage_report_desc(&coverage_profile_desc);
  if (imm_shared_coverage_profile_desc.status != NULL &&
      coverage_is_valid_desc(&imm_shared_coverage_profile_desc) &&
      coverage_has_hits_desc(&imm_shared_coverage_profile_desc)) {
    coverage_report_desc(&imm_shared_coverage_profile_desc);
  }
}

void coverage_printer_sink(const void *data, size_t size) {
  for (size_t i = 0; i < size; ++i) {
    uart_write_hex(((uint8_t *)data)[i], 1, 0);
  }
}
