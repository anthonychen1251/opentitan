// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stdbool.h>

#include "sw/device/lib/base/mmio.h"
#include "sw/device/lib/dif/dif_keymgr.h"
#include "sw/device/lib/dif/dif_otp_ctrl.h"
#include "sw/device/lib/dif/dif_rstmgr.h"
#include "sw/device/lib/runtime/ibex.h"
#include "sw/device/lib/runtime/log.h"
#include "sw/device/lib/testing/keymgr_testutils.h"
#include "sw/device/lib/testing/rstmgr_testutils.h"
#include "sw/device/lib/testing/test_framework/check.h"
#include "sw/device/lib/testing/test_framework/ottf_main.h"
#include "sw/device/silicon_creator/lib/base/boot_measurements.h"
#include "sw/device/silicon_creator/lib/base/sec_mmio.h"
#include "sw/device/silicon_creator/lib/drivers/hmac.h"
#include "sw/device/silicon_creator/lib/drivers/otp.h"
#include "sw/device/silicon_creator/lib/manifest.h"
#include "sw/device/silicon_creator/lib/manifest_def.h"
#include "sw/device/silicon_creator/manuf/lib/individualize_sw_cfg.h"

#include "hw/top_earlgrey/sw/autogen/top_earlgrey.h"
#include "otp_ctrl_regs.h"  // Generated

OTTF_DEFINE_TEST_CONFIG();

static uint32_t otp_state[kHmacDigestNumWords + 4] = {0};
static dif_otp_ctrl_t otp_ctrl;
static dif_rstmgr_t rstmgr;

static void sw_reset(void) {
  rstmgr_testutils_reason_clear();
  CHECK_DIF_OK(dif_rstmgr_software_device_reset(&rstmgr));
  wait_for_interrupt();
}

bool test_main(void) {
  CHECK_DIF_OK(dif_otp_ctrl_init(
      mmio_region_from_addr(TOP_EARLGREY_OTP_CTRL_CORE_BASE_ADDR), &otp_ctrl));
  bool is_locked = false;
  CHECK_DIF_OK(dif_otp_ctrl_dai_is_locked(&otp_ctrl, &is_locked));
  LOG_INFO("dai locked status: %d", is_locked);
  CHECK_DIF_OK(dif_rstmgr_init(
      mmio_region_from_addr(TOP_EARLGREY_RSTMGR_AON_BASE_ADDR), &rstmgr));
  if (!status_ok(manuf_individualize_device_creator_sw_cfg_check(&otp_ctrl))) {
    LOG_INFO("Lock CREATOR_SW_CFG");
    CHECK_STATUS_OK(manuf_individualize_device_creator_sw_cfg_lock(&otp_ctrl));
    sw_reset();
  }
  if (!status_ok(manuf_individualize_device_owner_sw_cfg_check(&otp_ctrl))) {
    LOG_INFO("Lock OWNER_SW_CFG");
    CHECK_STATUS_OK(manuf_individualize_device_owner_sw_cfg_lock(&otp_ctrl));
    sw_reset();
  }
  dif_keymgr_t keymgr;
  CHECK_DIF_OK(dif_keymgr_init(
      mmio_region_from_addr(TOP_EARLGREY_KEYMGR_BASE_ADDR), &keymgr));

  CHECK_STATUS_OK(keymgr_testutils_check_state(&keymgr, kDifKeymgrStateReset));

  dif_keymgr_binding_value_t bindings;
  CHECK_DIF_OK(dif_keymgr_read_binding(&keymgr, &bindings));

  const manifest_t *manifest = manifest_def_get();

  if (otp_read32(OTP_CTRL_PARAM_OWNER_SW_CFG_ROM_KEYMGR_OTP_MEAS_EN_OFFSET) ==
      kHardenedBoolTrue) {
    // Check that the attestation is equal to the digest of concatenations of:
    //   - the digest of the CreatorSwCfg partition,
    //   - the digest of the OwnerSwCfg partition,
    //   - the SHA256 integrity hash of the first stage boot keys.
    otp_dai_read(kOtpPartitionCreatorSwCfg,
                 /*relative_address=*/
                 kOtpPartitions[kOtpPartitionCreatorSwCfg].digest_addr -
                     OTP_CTRL_PARAM_CREATOR_SW_CFG_OFFSET,
                 otp_state,
                 /*num_words=*/2);
    otp_dai_read(kOtpPartitionOwnerSwCfg,
                 /*relative_address=*/
                 kOtpPartitions[kOtpPartitionOwnerSwCfg].digest_addr -
                     OTP_CTRL_PARAM_OWNER_SW_CFG_OFFSET,
                 &otp_state[2],
                 /*num_words=*/2);
    otp_dai_read(kOtpPartitionRotCreatorAuthCodesign,
                 /*relative_address=*/
                 OTP_CTRL_PARAM_ROTCREATORAUTHCODESIGNBLOCKSHA2_256HASHOFFSET -
                     OTP_CTRL_PARAM_ROT_CREATOR_AUTH_CODESIGN_OFFSET,
                 &otp_state[4],
                 /*num_words=*/kHmacDigestNumWords);
    hmac_digest_t otp_measurement;
    hmac_sha256(otp_state, (kHmacDigestNumWords + 4) * sizeof(uint32_t),
                &otp_measurement);
    CHECK_ARRAYS_EQ(bindings.attestation, otp_measurement.digest,
                    ARRAYSIZE(bindings.attestation));

    LOG_INFO("CREATOR_SW_CFG (dai):");
    for (int i = 0; i < 2; i++) {
      LOG_INFO("0x%08x", (uint32_t *)otp_state[i]);
    }

    LOG_INFO("OWNER_SW_CFG (dai):");
    for (int i = 2; i < 4; i++) {
      LOG_INFO("0x%08x", (uint32_t *)otp_state[i]);
    }

    LOG_INFO(
        "CREATOR_SW_CFG (base + sw_cfg_window_offset + "
        "OTP_CTRL_CREATOR_SW_CFG_DIGEST_0_REG_OFFSET):");
    for (int i = 0; i < 2; i++) {
      LOG_INFO("0x%08x", ((volatile uint32_t *)((
                             TOP_EARLGREY_OTP_CTRL_CORE_BASE_ADDR +
                             OTP_CTRL_SW_CFG_WINDOW_REG_OFFSET +
                             OTP_CTRL_CREATOR_SW_CFG_DIGEST_0_REG_OFFSET)))[i]);
    }

    LOG_INFO(
        "OWNER_SW_CFG (base + sw_cfg_window_offset + "
        "OTP_CTRL_OWNER_SW_CFG_DIGEST_0_REG_OFFSET):");
    for (int i = 0; i < 2; i++) {
      LOG_INFO("0x%08x", ((volatile uint32_t *)((
                             TOP_EARLGREY_OTP_CTRL_CORE_BASE_ADDR +
                             OTP_CTRL_SW_CFG_WINDOW_REG_OFFSET +
                             OTP_CTRL_OWNER_SW_CFG_DIGEST_0_REG_OFFSET)))[i]);
    }

    uint64_t val = 0;
    CHECK_DIF_OK(dif_otp_ctrl_get_digest(
        &otp_ctrl, kDifOtpCtrlPartitionCreatorSwCfg, &val));
    LOG_INFO("CREATOR_SW_CFG (dif_otp_ctrl_get_digest):");
    for (int i = 0; i < 2; i++) {
      LOG_INFO("0x%08x", ((uint32_t *)(&val))[i]);
    }

    CHECK_DIF_OK(dif_otp_ctrl_get_digest(&otp_ctrl,
                                         kDifOtpCtrlPartitionOwnerSwCfg, &val));
    LOG_INFO("OWNER_SW_CFG (dif_otp_ctrl_get_digest):");
    for (int i = 0; i < 2; i++) {
      LOG_INFO("0x%08x", ((uint32_t *)(&val))[i]);
    }

    LOG_INFO(
        "CREATOR_SW_CFG (base + OTP_CTRL_CREATOR_SW_CFG_DIGEST_0_REG_OFFSET):");
    for (int i = 0; i < 2; i++) {
      LOG_INFO("0x%08x", ((volatile uint32_t *)((
                             TOP_EARLGREY_OTP_CTRL_CORE_BASE_ADDR +
                             OTP_CTRL_CREATOR_SW_CFG_DIGEST_0_REG_OFFSET)))[i]);
    }

    LOG_INFO(
        "OWNER_SW_CFG (base + OTP_CTRL_OWNER_SW_CFG_DIGEST_0_REG_OFFSET):");
    for (int i = 0; i < 2; i++) {
      LOG_INFO("0x%08x", ((volatile uint32_t *)((
                             TOP_EARLGREY_OTP_CTRL_CORE_BASE_ADDR +
                             OTP_CTRL_OWNER_SW_CFG_DIGEST_0_REG_OFFSET)))[i]);
    }

    LOG_INFO(
        "CREATOR_SW_CFG (base + sw_cfg_window_offset + "
        "OTP_CTRL_PARAM_CREATOR_SW_CFG_DIGEST_OFFSET):");
    for (int i = 0; i < 2; i++) {
      LOG_INFO("0x%08x", ((volatile uint32_t *)((
                             TOP_EARLGREY_OTP_CTRL_CORE_BASE_ADDR +
                             OTP_CTRL_SW_CFG_WINDOW_REG_OFFSET +
                             OTP_CTRL_PARAM_CREATOR_SW_CFG_DIGEST_OFFSET)))[i]);
    }

    LOG_INFO(
        "OWNER_SW_CFG (base + sw_cfg_window_offset + "
        "OTP_CTRL_PARAM_OWNER_SW_CFG_DIGEST_OFFSET):");
    for (int i = 0; i < 2; i++) {
      LOG_INFO("0x%08x", ((volatile uint32_t *)((
                             TOP_EARLGREY_OTP_CTRL_CORE_BASE_ADDR +
                             OTP_CTRL_SW_CFG_WINDOW_REG_OFFSET +
                             OTP_CTRL_PARAM_OWNER_SW_CFG_DIGEST_OFFSET)))[i]);
    }

  } else {
    // Check that the attestation is equal to `binding_value` field of the
    // manifest.
    CHECK_ARRAYS_EQ(bindings.attestation, manifest->binding_value.data,
                    ARRAYSIZE(bindings.attestation));
  }

  // Check that the sealing is equal to `binding_value` field of the
  // manifest.
  CHECK_ARRAYS_EQ(bindings.sealing, manifest->binding_value.data,
                  ARRAYSIZE(bindings.sealing));

  // Check that the creator max version is equal to `max_key_version` field of
  // the manifest.
  dif_keymgr_max_key_version_t versions;
  CHECK_DIF_OK(dif_keymgr_read_max_key_version(&keymgr, &versions));
  CHECK(versions.creator_max_key_version == manifest->max_key_version);
  return true;
}
