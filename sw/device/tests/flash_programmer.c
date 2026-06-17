// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <string.h>

#include "sw/device/lib/arch/device.h"
#include "sw/device/lib/base/status.h"
#include "sw/device/lib/dif/dif_pinmux.h"
#include "sw/device/lib/dif/dif_spi_device.h"
#include "sw/device/lib/dif/dif_spi_host.h"
#include "sw/device/lib/runtime/log.h"
#include "sw/device/lib/runtime/hart.h"
#include "sw/device/lib/testing/spi_device_testutils.h"
#include "sw/device/lib/testing/spi_flash_testutils.h"
#include "sw/device/lib/testing/test_framework/check.h"
#include "sw/device/lib/testing/test_framework/ottf_main.h"

#include "hw/top_earlgrey/sw/autogen/top_earlgrey.h"

OTTF_DEFINE_TEST_CONFIG();

static dif_spi_host_t spih;
static dif_spi_device_handle_t spid;

static status_t reset_flash_chip(dif_spi_host_t *spih) {
  // Send RESET_ENABLE (0x66)
  dif_spi_host_segment_t reset_enable[] = {
      {.type = kDifSpiHostSegmentTypeOpcode,
       .opcode = {.opcode = 0x66, .width = kDifSpiHostWidthStandard}},
  };
  TRY(dif_spi_host_transaction(spih, /*csid=*/0, reset_enable,
                               ARRAYSIZE(reset_enable)));

  // Send RESET (0x99)
  dif_spi_host_segment_t reset[] = {
      {.type = kDifSpiHostSegmentTypeOpcode,
       .opcode = {.opcode = 0x99, .width = kDifSpiHostWidthStandard}},
  };
  TRY(dif_spi_host_transaction(spih, /*csid=*/0, reset,
                               ARRAYSIZE(reset)));

  // Wait for reset to complete (typically at least 100 microseconds)
  busy_spin_micros(150);
  return OK_STATUS();
}

// Custom wait_for_upload with robust payload occupancy polling to prevent CDC race conditions.
static status_t custom_wait_for_upload(dif_spi_device_handle_t *spid,
                                       upload_info_t *info) {
  // Wait for a SPI transaction to cause an upload.
  bool upload_pending;
  do {
    TRY(dif_spi_device_irq_is_pending(
        &spid->dev, kDifSpiDeviceIrqUploadCmdfifoNotEmpty, &upload_pending));
  } while (!upload_pending);

  uint8_t occupancy;

  // Get the SPI opcode.
  TRY(dif_spi_device_get_flash_command_fifo_occupancy(spid, &occupancy));
  if (occupancy != 1) {
    return INTERNAL();
  }
  TRY(dif_spi_device_pop_flash_command_fifo(spid, &info->opcode));
  TRY(dif_spi_device_get_flash_status_registers(spid, &info->flash_status));

  // Get the SPI address (if available).
  TRY(dif_spi_device_get_flash_address_fifo_occupancy(spid, &occupancy));
  if (occupancy) {
    dif_toggle_t addr_4b;
    TRY(dif_spi_device_get_4b_address_mode(spid, &addr_4b));
    info->addr_4b = (addr_4b == kDifToggleEnabled);
    TRY(dif_spi_device_pop_flash_address_fifo(spid, &info->address));
    info->has_address = true;
  }

  // Get the SPI data payload (if available).
  uint32_t start;
  uint16_t expected_len = 0;
  if (info->opcode == kSpiDeviceFlashOpPageProgram ||
      info->opcode == kSpiDeviceFlashOpPageProgram4b) {
    expected_len = 256;
  }

  if (expected_len > 0) {
    // Poll until the payload FIFO occupancy matches the expected size to avoid CDC delays.
    uint32_t timeout_cycles = 100000;
    do {
      TRY(dif_spi_device_get_flash_payload_fifo_occupancy(spid, &info->data_len,
                                                          &start));
      if (info->data_len >= expected_len) {
        break;
      }
      timeout_cycles--;
    } while (timeout_cycles > 0);

    if (timeout_cycles == 0) {
      LOG_ERROR("Timeout waiting for SPI payload. Expected %u, got %u", expected_len, info->data_len);
      return INTERNAL();
    }
  } else {
    TRY(dif_spi_device_get_flash_payload_fifo_occupancy(spid, &info->data_len,
                                                        &start));
  }

  if (info->data_len) {
    if (info->data_len > sizeof(info->data)) {
      return INVALID_ARGUMENT();
    }
    TRY(dif_spi_device_read_flash_payload_buffer(spid, start, info->data_len,
                                                 info->data));
  }

  // Acknowledge the IRQ.
  TRY(dif_spi_device_irq_acknowledge(&spid->dev,
                                     kDifSpiDeviceIrqUploadCmdfifoNotEmpty));
  return OK_STATUS();
}

// Robust status register polling requiring 3 consecutive idle reads to filter out bus glitches.
static status_t robust_wait_until_not_busy(dif_spi_host_t *spih) {
  TRY_CHECK(spih != NULL);
  uint32_t consecutive_idle_count = 0;
  
  while (consecutive_idle_count < 3) {
    busy_spin_micros(50); // Quiet the bus and reduce polling noise.
    int32_t status = TRY(spi_flash_testutils_read_status(spih, kSpiDeviceFlashOpReadStatus1, 1));
    if (!(status & kSpiFlashStatusBitWip)) {
      consecutive_idle_count++;
    } else {
      consecutive_idle_count = 0;
    }
  }
  return OK_STATUS();
}

static status_t robust_erase_op(dif_spi_host_t *spih, uint8_t opcode,
                                 uint32_t address, bool addr_is_4b) {
  TRY_CHECK(spih != NULL);
  TRY(spi_flash_testutils_issue_write_enable(spih));

  dif_spi_host_addr_mode_t addr_mode =
      addr_is_4b ? kDifSpiHostAddrMode4b : kDifSpiHostAddrMode3b;
  dif_spi_host_segment_t transaction[] = {
      {.type = kDifSpiHostSegmentTypeOpcode,
       .opcode = {.opcode = opcode, .width = kDifSpiHostWidthStandard}},
      {
          .type = kDifSpiHostSegmentTypeAddress,
          .address =
              {
                  .width = kDifSpiHostWidthStandard,
                  .mode = addr_mode,
                  .address = address,
              },
      },
  };
  TRY(dif_spi_host_transaction(spih, /*csid=*/0, transaction,
                               ARRAYSIZE(transaction)));
  return robust_wait_until_not_busy(spih);
}

static status_t robust_program_op(
    dif_spi_host_t *spih, uint8_t opcode, const void *payload, size_t length,
    uint32_t address, bool addr_is_4b) {
  TRY_CHECK(spih != NULL);
  TRY_CHECK(payload != NULL);
  TRY_CHECK(length <= 256);

  TRY(spi_flash_testutils_issue_write_enable(spih));

  dif_spi_host_addr_mode_t addr_mode =
      addr_is_4b ? kDifSpiHostAddrMode4b : kDifSpiHostAddrMode3b;
  dif_spi_host_segment_t transaction[] = {
      {.type = kDifSpiHostSegmentTypeOpcode,
       .opcode = {.opcode = opcode, .width = kDifSpiHostWidthStandard}},
      {
          .type = kDifSpiHostSegmentTypeAddress,
          .address =
              {
                  .width = kDifSpiHostWidthStandard,
                  .mode = addr_mode,
                  .address = address,
              },
      },
      {
          .type = kDifSpiHostSegmentTypeTx,
          .tx =
              {
                  .width = kDifSpiHostWidthStandard,
                  .buf = payload,
                  .length = length,
              },
      },
  };
  TRY(dif_spi_host_transaction(spih, /*csid=*/0, transaction,
                               ARRAYSIZE(transaction)));
  return robust_wait_until_not_busy(spih);
}

// Gold-standard page programming with read-after-write verification and automatic retries.
static status_t robust_program_op_with_retry(
    dif_spi_host_t *spih, uint8_t opcode, const void *payload, size_t length,
    uint32_t address, bool addr_is_4b) {
  
  uint8_t read_buf[256];
  uint32_t attempts = 5;
  uint8_t read_opcode = addr_is_4b ? kSpiDeviceFlashOpRead4b : kSpiDeviceFlashOpReadNormal;

  // First attempt (fast):
  status_t program_status = robust_program_op(spih, opcode, payload, length, address, addr_is_4b);
  if (status_ok(program_status)) {
    status_t read_status = spi_flash_testutils_read_op(spih, read_opcode, read_buf, length, address, addr_is_4b, /*width=*/1, /*dummy=*/0);
    if (status_ok(read_status) && memcmp(payload, read_buf, length) == 0) {
      return OK_STATUS();
    }
  }

  // If the fast attempt failed, enter robust retry loop with guaranteed physical safety delays!
  LOG_WARNING("Fast verification failed at address 0x%08x. Entering robust retry loop...", address);

  for (uint32_t attempt = 1; attempt <= attempts; attempt++) {
    // Wait 5 milliseconds to let any previous operation fully complete/settle
    busy_spin_micros(5000);

    // Re-program the page
    program_status = robust_program_op(spih, opcode, payload, length, address, addr_is_4b);
    if (!status_ok(program_status)) {
      LOG_WARNING("Page program failed during retry attempt %u at address 0x%08x", attempt, address);
      continue;
    }

    // Wait another 5 milliseconds to guarantee the physical write has fully committed to the cells!
    busy_spin_micros(5000);

    // Read back
    status_t read_status = spi_flash_testutils_read_op(spih, read_opcode, read_buf, length, address, addr_is_4b, /*width=*/1, /*dummy=*/0);
    if (!status_ok(read_status)) {
      LOG_WARNING("Page readback failed during retry attempt %u at address 0x%08x", attempt, address);
      continue;
    }

    // Verify
    if (memcmp(payload, read_buf, length) == 0) {
      LOG_INFO("Page at address 0x%08x recovered successfully on retry attempt %u.", address, attempt);
      return OK_STATUS();
    }

    LOG_WARNING("Verification mismatch at address 0x%08x on retry attempt %u!", address, attempt);
  }

  LOG_ERROR("Failed to program and verify page at address 0x%08x after retries!", address);
  return INTERNAL();
}

bool test_main(void) {
  // Initialize SPI host 0 (connected to external flash)
  const uint32_t spi_host_clock_freq_hz = (uint32_t)kClockFreqHiSpeedPeripheralHz;
  CHECK_DIF_OK(dif_spi_host_init(
      mmio_region_from_addr(TOP_EARLGREY_SPI_HOST0_BASE_ADDR), &spih));
  
  dif_spi_host_config_t config = {
      .spi_clock = spi_host_clock_freq_hz / 16, // 1.5 MHz (highly robust)
      .peripheral_clock_freq_hz = spi_host_clock_freq_hz,
      .chip_select =
          {
              .idle = 8,  // 333 nanoseconds (highly robust)
              .trail = 8,
              .lead = 8,
          },
  };
  CHECK_DIF_OK(dif_spi_host_configure(&spih, config));
  CHECK_DIF_OK(dif_spi_host_output_set_enabled(&spih, /*enabled=*/true));

  // Reset the external SPI flash chip to clear any leftover 4-byte mode.
  CHECK_STATUS_OK(reset_flash_chip(&spih));

  // Initialize SPI device (connected to host/debugger)
  CHECK_DIF_OK(dif_spi_device_init_handle(
      mmio_region_from_addr(TOP_EARLGREY_SPI_DEVICE_BASE_ADDR), &spid));

  // Configure passthrough:
  // - We DO NOT filter any commands (filters = 0) so the host can read
  //   the JEDEC ID and SFDP table directly from the physical flash in hardware passthrough!
  // - We intercept all write commands (upload_write_commands = true) so we can execute
  //   them and control the busy/WIP status.
  CHECK_STATUS_OK(spi_device_testutils_configure_passthrough(
      &spid,
      /*filters=*/0,
      /*upload_write_commands=*/true));

  // We intercept status register commands so we can emulate the WIP (busy) bit
  // during writes and erases.
  dif_spi_device_passthrough_intercept_config_t passthru_cfg = {
      .status = true,
      .jedec_id = false,
      .sfdp = false,
      .mailbox = false,
  };
  CHECK_DIF_OK(
      dif_spi_device_set_passthrough_intercept_config(&spid, passthru_cfg));

  // Enable passthrough mode initially.
  CHECK_DIF_OK(dif_spi_device_set_passthrough_mode(&spid, kDifToggleEnabled));

  LOG_INFO("Flash Programmer Agent is ready. Entering SPI program loop...");

  while (true) {
    upload_info_t info = {0};
    // Wait for the host to send a write/erase command over the SPI bus.
    CHECK_STATUS_OK(custom_wait_for_upload(&spid, &info));

    // Set the WIP (Write In Progress) bit to 1 in the emulated status register
    // so the host sees we are busy when it polls over SPI.
    CHECK_DIF_OK(dif_spi_device_set_flash_status_registers(&spid, kSpiFlashStatusBitWip));

    // Disable passthrough mode before using the SPI Host controller to avoid pin contention on the SPI Host pins!
    CHECK_DIF_OK(dif_spi_device_set_passthrough_mode(&spid, kDifToggleDisabled));

    if (info.opcode == kSpiDeviceFlashOpSectorErase ||
        info.opcode == kSpiDeviceFlashOpSectorErase4b ||
        info.opcode == kSpiDeviceFlashOpBlockErase32k ||
        info.opcode == kSpiDeviceFlashOpBlockErase32k4b ||
        info.opcode == kSpiDeviceFlashOpBlockErase64k ||
        info.opcode == kSpiDeviceFlashOpBlockErase64k4b) {
      CHECK_STATUS_OK(robust_erase_op(&spih, info.opcode, info.address, info.addr_4b));
    } else if (info.opcode == kSpiDeviceFlashOpPageProgram ||
               info.opcode == kSpiDeviceFlashOpPageProgram4b) {
      CHECK_STATUS_OK(robust_program_op_with_retry(&spih, info.opcode, info.data, info.data_len, info.address, info.addr_4b));
    } else {
      LOG_ERROR("Unrecognized intercepted SPI opcode: 0x%02x", info.opcode);
    }

    // Re-enable passthrough mode so the host can read from the flash or send the next command.
    CHECK_DIF_OK(dif_spi_device_set_passthrough_mode(&spid, kDifToggleEnabled));

    // Force a TileLink write barrier by reading back the status register of the SPI device.
    // This blocks the CPU until the passthrough enable has physically completed in hardware.
    uint32_t dummy_status;
    CHECK_DIF_OK(dif_spi_device_get_flash_status_registers(&spid, &dummy_status));

    // Clear the WIP bit and clear the upload FIFO/interrupt to signal completion to the host.
    CHECK_DIF_OK(dif_spi_device_set_flash_status_registers(&spid, 0));
  }

  return true;
}
