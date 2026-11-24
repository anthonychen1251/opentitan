// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>

#include "sw/device/lib/base/abs_mmio.h"
#include "sw/device/lib/base/csr.h"
#include "sw/device/lib/base/hardened.h"
#include "sw/device/lib/base/macros.h"
#include "sw/device/lib/base/multibits.h"
#include "sw/device/lib/runtime/log.h"
#include "sw/device/lib/testing/test_framework/check.h"
#include "sw/device/lib/testing/test_framework/ottf_alerts.h"
#include "sw/device/lib/testing/test_framework/ottf_main.h"
#include "sw/device/silicon_creator/lib/drivers/flash_ctrl.h"

#include "flash_ctrl_regs.h"
#include "hw/top_earlgrey/sw/autogen/top_earlgrey.h"
#include "rv_core_ibex_regs.h"

OTTF_DEFINE_TEST_CONFIG();

extern void flash_exc_test_vector_table(void);

uint32_t flash_ecc_exc_handler_en = kHardenedBoolFalse;
volatile uint32_t flash_exc_test_fallback_count = 0;
volatile uint32_t flash_exc_test_fallback_mcause = 0;
volatile uint32_t flash_exc_test_fallback_mtval = 0;

enum {
  // Unused flash page in Bank 0 (256 KiB offset).
  kCorruptPageIdx = 128,
  kCorruptOffset = kCorruptPageIdx * FLASH_CTRL_PARAM_BYTES_PER_PAGE,
  kRomExtVirtualBase = 0x90000000u,
  kOwnerVirtualBase = 0xa0000000u,
  kVirtualWindowSize = 0x00080000u,
  kUnmappedNonFlashAddr = 0x00000000u,
  kFlashPhyErrorsMask = (1u << FLASH_CTRL_FAULT_STATUS_PHY_STORAGE_ERR_BIT) |
      (1u << FLASH_CTRL_FAULT_STATUS_PHY_RELBL_ERR_BIT),
  kIbexCfgBase = TOP_EARLGREY_RV_CORE_IBEX_CFG_BASE_ADDR,
  kFlashCtrlBase = TOP_EARLGREY_FLASH_CTRL_CORE_BASE_ADDR,
};

static uint32_t napot_match(uint32_t base, uint32_t size) {
  uint32_t mask = size - 1;
  return (base & ~mask) | (mask >> 1);
}

static void dbus_remap_set(uint32_t slot, uint32_t match_base,
                           uint32_t remap_base, uint32_t size) {
  uint32_t match = napot_match(match_base, size);
  uint32_t remap = remap_base & ~(size - 1);
  if (slot == 0) {
    abs_mmio_write32(
        kIbexCfgBase + RV_CORE_IBEX_DBUS_ADDR_MATCHING_0_REG_OFFSET, match);
    abs_mmio_write32(kIbexCfgBase + RV_CORE_IBEX_DBUS_REMAP_ADDR_0_REG_OFFSET,
                     remap);
    abs_mmio_write32(kIbexCfgBase + RV_CORE_IBEX_DBUS_ADDR_EN_0_REG_OFFSET, 1);
  } else {
    abs_mmio_write32(
        kIbexCfgBase + RV_CORE_IBEX_DBUS_ADDR_MATCHING_1_REG_OFFSET, match);
    abs_mmio_write32(kIbexCfgBase + RV_CORE_IBEX_DBUS_REMAP_ADDR_1_REG_OFFSET,
                     remap);
    abs_mmio_write32(kIbexCfgBase + RV_CORE_IBEX_DBUS_ADDR_EN_1_REG_OFFSET, 1);
  }
}

static void dbus_remap_disable(uint32_t slot) {
  if (slot == 0) {
    abs_mmio_write32(kIbexCfgBase + RV_CORE_IBEX_DBUS_ADDR_EN_0_REG_OFFSET, 0);
  } else {
    abs_mmio_write32(kIbexCfgBase + RV_CORE_IBEX_DBUS_ADDR_EN_1_REG_OFFSET, 0);
  }
}

bool test_main(void) {
  // Ignore flash controller alerts raised by intentional ECC fault injection.
  OT_DISCARD(
      ottf_alerts_ignore_alert(kTopEarlgreyAlertIdFlashCtrlRecovErr).value);
  OT_DISCARD(
      ottf_alerts_ignore_alert(kTopEarlgreyAlertIdFlashCtrlFatalErr).value);

  uint32_t init_fault =
      abs_mmio_read32(kFlashCtrlBase + FLASH_CTRL_FAULT_STATUS_REG_OFFSET);
  bool has_sticky_fault = (init_fault & ~(uint32_t)kFlashPhyErrorsMask) != 0;
  LOG_INFO("Initial flash_ctrl fault_sts = 0x%x (sticky=%u)", init_fault,
           has_sticky_fault);

  // Configure region 0 to allow RW/erase and ECC (scrambling disabled) on the
  // target page, then double-write word 0 to inject an uncorrectable ECC fault.
  flash_ctrl_data_region_protect(
      /*region=*/0, /*page_offset=*/kCorruptPageIdx, /*num_pages=*/1,
      (flash_ctrl_perms_t){
          .read = kMultiBitBool4True,
          .write = kMultiBitBool4True,
          .erase = kMultiBitBool4True,
      },
      (flash_ctrl_cfg_t){
          .scrambling = kMultiBitBool4False,
          .ecc = kMultiBitBool4True,
          .he = kMultiBitBool4False,
      },
      /*lock=*/kHardenedBoolFalse);

  rom_error_t werr =
      flash_ctrl_data_erase(kCorruptOffset, kFlashCtrlEraseTypePage);
  CHECK(werr == kErrorOk, "erase err=0x%x err_code=0x%x err_addr=0x%x", werr,
        abs_mmio_read32(kFlashCtrlBase + FLASH_CTRL_ERR_CODE_REG_OFFSET),
        abs_mmio_read32(kFlashCtrlBase + FLASH_CTRL_ERR_ADDR_REG_OFFSET));
  uint32_t word = 0x00000001u;
  werr = flash_ctrl_data_write(kCorruptOffset, /*word_count=*/1, &word);
  CHECK(werr == kErrorOk, "write1 err=0x%x err_code=0x%x err_addr=0x%x", werr,
        abs_mmio_read32(kFlashCtrlBase + FLASH_CTRL_ERR_CODE_REG_OFFSET),
        abs_mmio_read32(kFlashCtrlBase + FLASH_CTRL_ERR_ADDR_REG_OFFSET));
  word = 0x00000000u;
  werr = flash_ctrl_data_write(kCorruptOffset, /*word_count=*/1, &word);
  if (werr != kErrorOk) {
    LOG_INFO(
        "write2 err=0x%x err_code=0x%x err_addr=0x%x fault=0x%x", werr,
        abs_mmio_read32(kFlashCtrlBase + FLASH_CTRL_ERR_CODE_REG_OFFSET),
        abs_mmio_read32(kFlashCtrlBase + FLASH_CTRL_ERR_ADDR_REG_OFFSET),
        abs_mmio_read32(kFlashCtrlBase + FLASH_CTRL_FAULT_STATUS_REG_OFFSET));
    abs_mmio_write32(
        kFlashCtrlBase + FLASH_CTRL_ERR_CODE_REG_OFFSET,
        abs_mmio_read32(kFlashCtrlBase + FLASH_CTRL_ERR_CODE_REG_OFFSET));
  }

  // Map both virtual flash windows onto bank 0 of physical eflash (DBUS only).
  dbus_remap_set(/*slot=*/0, kRomExtVirtualBase, TOP_EARLGREY_EFLASH_BASE_ADDR,
                 kVirtualWindowSize);
  dbus_remap_set(/*slot=*/1, kOwnerVirtualBase, TOP_EARLGREY_EFLASH_BASE_ADDR,
                 kVirtualWindowSize);

  // Temporarily install `flash_exc_test_vector_table` (256-byte aligned,
  // vectored mode bit 0 = 1: synchronous exceptions enter slot 0 which jumps
  // to `flash_exception_handler`).
  uint32_t saved_mtvec = 0;
  CSR_READ(CSR_REG_MTVEC, &saved_mtvec);
  uint32_t saved_mstatus = 0;
  CSR_READ(CSR_REG_MSTATUS, &saved_mstatus);
  CSR_CLEAR_BITS(CSR_REG_MSTATUS, 1u << 3);  // Disable MIE during test.
  CSR_WRITE(CSR_REG_MTVEC, (uintptr_t)&flash_exc_test_vector_table | 1u);

  const uintptr_t phys_addr = TOP_EARLGREY_EFLASH_BASE_ADDR + kCorruptOffset;
  const uintptr_t rom_ext_virt_addr = kRomExtVirtualBase + kCorruptOffset;
  const uintptr_t owner_virt_addr = kOwnerVirtualBase + kCorruptOffset;

  flash_ecc_exc_handler_en = kHardenedBoolTrue;

  // 1. Physical eflash window: exercise lw / c.lw / lh / lb / lhu / lbu.
  uint32_t val_phys_lw = 0x12345678u;
  asm volatile(
      ".option push\n"
      ".option norvc\n"
      "lw %0, 0(%1)\n"
      ".option pop\n"
      : "+r"(val_phys_lw)
      : "r"(phys_addr));

  uint32_t val_phys_lhu = 0x12345678u;
  asm volatile("lhu %0, 0(%1)" : "+r"(val_phys_lhu) : "r"(phys_addr));

  uint32_t val_phys_lbu = 0x12345678u;
  asm volatile("lbu %0, 0(%1)" : "+r"(val_phys_lbu) : "r"(phys_addr));

  // 2. ROM_EXT virtual window (`0x90000000..0x90080000`).
  uint32_t val_rom_ext_virt_lbu = 0x12345678u;
  asm volatile("lbu %0, 0(%1)"
               : "+r"(val_rom_ext_virt_lbu)
               : "r"(rom_ext_virt_addr));

  // 3. Owner virtual window (`0xa0000000..0xa0080000`).
  uint32_t val_owner_virt_lhu = 0x12345678u;
  asm volatile("lhu %0, 0(%1)"
               : "+r"(val_owner_virt_lhu)
               : "r"(owner_virt_addr));

  uint32_t fallback_before_non_flash = flash_exc_test_fallback_count;

  // 4. Non-flash `mtval` fallback when `FAULT_STATUS` already has PHY_ERRORS:
  //    First trigger a flash ECC fault with the handler disabled so
  //    `PHY_ERRORS` remains latched in `FLASH_CTRL.FAULT_STATUS`.
  flash_ecc_exc_handler_en = kHardenedBoolFalse;
  uint32_t dummy = 0;
  asm volatile(
      ".option push\n"
      ".option norvc\n"
      "lw %0, 0(%1)\n"
      ".option pop\n"
      : "=r"(dummy)
      : "r"(phys_addr));
  uint32_t fault_sts_latched =
      abs_mmio_read32(kFlashCtrlBase + FLASH_CTRL_FAULT_STATUS_REG_OFFSET);
  uint32_t fallback_after_disabled = flash_exc_test_fallback_count;

  //    Now re-enable the handler and issue a faulting load from an unmapped
  //    non-flash address (`0x00000000`). With `PHY_ERRORS` latched and `mtval`
  //    outside all three flash windows, `flash_exception_handler` must reject
  //    it and jump to `.L_not_a_flash_error`.
  flash_ecc_exc_handler_en = kHardenedBoolTrue;
  asm volatile(
      ".option push\n"
      ".option norvc\n"
      "lw %0, 0(%1)\n"
      ".option pop\n"
      : "=r"(dummy)
      : "r"(kUnmappedNonFlashAddr));
  uint32_t fallback_after_non_flash = flash_exc_test_fallback_count;
  uint32_t non_flash_mcause = flash_exc_test_fallback_mcause;
  uint32_t non_flash_mtval = flash_exc_test_fallback_mtval;

  // Clear latched flash fault bits and restore mtvec/mstatus/remaps before
  // logging.
  abs_mmio_write32(kFlashCtrlBase + FLASH_CTRL_FAULT_STATUS_REG_OFFSET, 0);
  flash_ecc_exc_handler_en = kHardenedBoolFalse;
  CSR_WRITE(CSR_REG_MTVEC, saved_mtvec);
  CSR_WRITE(CSR_REG_MSTATUS, saved_mstatus);
  dbus_remap_disable(/*slot=*/0);
  dbus_remap_disable(/*slot=*/1);

  // Re-erase the corrupted page so it doesn't confuse subsequent reads.
  CHECK(flash_ctrl_data_erase(kCorruptOffset, kFlashCtrlEraseTypePage) ==
        kErrorOk);

  LOG_INFO(
      "phys_lw=0x%08x phys_lhu=0x%08x phys_lbu=0x%08x rom_ext_virt_lbu=0x%08x "
      "owner_virt_lhu=0x%08x latched=0x%x fb=(%u,%u,%u) mcause=%u mtval=0x%08x",
      val_phys_lw, val_phys_lhu, val_phys_lbu, val_rom_ext_virt_lbu,
      val_owner_virt_lhu, fault_sts_latched, fallback_before_non_flash,
      fallback_after_disabled, fallback_after_non_flash, non_flash_mcause,
      non_flash_mtval);

  if (has_sticky_fault) {
    // When read-only fault bits (e.g. `SEED_ERR` / `RD_ERR` on an unprovisioned
    // `test_rom` FPGA image) remain non-zero after clearing `PHY_ERRORS`,
    // `flash_exception_handler` must reject all 5 flash ECC faults via the
    // post-clear verification branch and hand off to the fallback handler.
    CHECK(fallback_before_non_flash == 5);
    CHECK(fallback_after_disabled == 6);
    CHECK(fallback_after_non_flash == 7);
  } else {
    CHECK(val_phys_lw == 0xffffffffu);
    CHECK(val_phys_lhu == 0x0000ffffu);
    CHECK(val_phys_lbu == 0x000000ffu);
    CHECK(val_rom_ext_virt_lbu == 0x000000ffu);
    CHECK(val_owner_virt_lhu == 0x0000ffffu);
    CHECK(fallback_before_non_flash == 0);
    CHECK(fallback_after_disabled == 1);
    CHECK(fallback_after_non_flash == 2);
  }
  CHECK((fault_sts_latched & kFlashPhyErrorsMask) != 0);
  CHECK((non_flash_mcause & 31u) == 5u);
  CHECK(non_flash_mtval == kUnmappedNonFlashAddr);

  return true;
}
