// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <cstddef>
#include <cstdint>

#include "gtest/gtest.h"
#include "sw/device/silicon_creator/lib/error.h"
#include "sw/device/silicon_creator/testing/rom_test.h"

extern "C" {
// Define aliased linker symbols so `_rom_ext_size - _rom_ext_protected_size`
// equals 0 in host unit tests without referencing device linker scripts.
char _rom_ext_protected_size[1] = {0};
extern char _rom_ext_size[1] __attribute__((alias("_rom_ext_protected_size")));
char _owner_virtual_start_address[1] = {0};

// Forward-declare the slot type and functions under test directly to avoid
// pulling `dice_storage.h`'s 32-bit pointer-to-uint32_t inline helper casts
// into 64-bit host C++ compilation.
typedef struct dice_storage_slot_v1 dice_storage_slot_v1_t;
typedef struct flash_ctrl_info_page flash_ctrl_info_page_t;

// `dice_storage.c` calls the `inline` `dice_storage_slot_v1_offset` whose
// out-of-line definition is only emitted when inlining is enabled (-O1+).
uint32_t dice_storage_slot_v1_offset(const dice_storage_slot_v1_t *slot) {
  (void)slot;
  return 0;
}

// Stub unmocked flash_ctrl info-read helper unused by these early-return tests.
rom_error_t flash_ctrl_info_read_zeros_on_read_error(
    const flash_ctrl_info_page_t *info_page, uint32_t offset,
    uint32_t word_count, void *data) {
  (void)info_page;
  (void)offset;
  (void)word_count;
  (void)data;
  return kErrorOk;
}

rom_error_t dice_storage_digest_slot_v1(const dice_storage_slot_v1_t *slot);
rom_error_t dice_storage_write_cert_tlv_v1(const dice_storage_slot_v1_t *slot,
                                           const uint8_t *cert_data,
                                           size_t cert_size);
}

namespace dice_storage_unittest {
namespace {

class DiceStorageTest : public rom_test::RomTest {};

TEST_F(DiceStorageTest, DigestSlotV1ZeroStorageSize) {
  EXPECT_EQ(dice_storage_digest_slot_v1(nullptr), kErrorOk);
}

TEST_F(DiceStorageTest, WriteCertTlvV1BufferTooSmall) {
  const uint8_t kCertData[16] = {0};
  EXPECT_EQ(
      dice_storage_write_cert_tlv_v1(nullptr, kCertData, sizeof(kCertData)),
      kErrorCertInvalidArgument);
}

}  // namespace
}  // namespace dice_storage_unittest
