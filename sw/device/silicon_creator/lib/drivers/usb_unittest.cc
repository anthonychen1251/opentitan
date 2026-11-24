// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "sw/device/silicon_creator/lib/drivers/usb.h"

#include <cstdint>

#include "gtest/gtest.h"
#include "sw/device/lib/base/bitfield.h"
#include "sw/device/lib/base/mock_abs_mmio.h"
#include "sw/device/silicon_creator/lib/error.h"
#include "sw/device/silicon_creator/testing/rom_test.h"

#include "hw/top_earlgrey/sw/autogen/top_earlgrey.h"
#include "usbdev_regs.h"

namespace usb_unittest {
namespace {

struct CallbackState {
  uint32_t calls = 0;
  uint8_t ep = 0;
  usb_transfer_flags_t flags = static_cast<usb_transfer_flags_t>(0);
};

void EpHandler(void *ctx, uint8_t ep, usb_transfer_flags_t flags, void *data) {
  (void)data;
  auto *state = static_cast<CallbackState *>(ctx);
  state->calls++;
  state->ep = ep;
  state->flags = flags;
}

class UsbTest : public rom_test::RomTest {
 protected:
  static constexpr uint32_t kBase = TOP_EARLGREY_USBDEV_BASE_ADDR;
  rom_test::MockAbsMmio abs_;
};

TEST_F(UsbTest, HandleInCancelledPendingTransaction) {
  // 1. usb_init(): configure PHY and short-circuit fill_fifos() once
  //    av_setup_depth >= 2 and AV_OUT_FULL is set.
  const uint32_t kPhyCfg =
      bitfield_bit32_write(0, USBDEV_PHY_CONFIG_USE_DIFF_RCVR_BIT, true);
  EXPECT_ABS_WRITE32(kBase + USBDEV_PHY_CONFIG_REG_OFFSET, kPhyCfg);
  const uint32_t kFifosFull =
      bitfield_field32_write(0, USBDEV_USBSTAT_AV_SETUP_DEPTH_FIELD, 2) |
      (1u << USBDEV_USBSTAT_AV_OUT_FULL_BIT);
  EXPECT_ABS_READ32(kBase + USBDEV_USBSTAT_REG_OFFSET, kFifosFull);
  usb_init();

  // 2. usb_ep_init() on EP0 IN+OUT control endpoint.
  CallbackState cb_state;
  EXPECT_ABS_READ32(kBase + USBDEV_EP_OUT_ENABLE_REG_OFFSET, 0);
  EXPECT_ABS_WRITE32(kBase + USBDEV_EP_OUT_ENABLE_REG_OFFSET, 1u);
  EXPECT_ABS_READ32(kBase + USBDEV_SET_NAK_OUT_REG_OFFSET, 0);
  EXPECT_ABS_WRITE32(kBase + USBDEV_SET_NAK_OUT_REG_OFFSET, 0);
  EXPECT_ABS_READ32(kBase + USBDEV_RXENABLE_OUT_REG_OFFSET, 0);
  EXPECT_ABS_WRITE32(kBase + USBDEV_RXENABLE_OUT_REG_OFFSET, 0);
  EXPECT_ABS_READ32(kBase + USBDEV_RXENABLE_SETUP_REG_OFFSET, 0);
  EXPECT_ABS_WRITE32(kBase + USBDEV_RXENABLE_SETUP_REG_OFFSET, 1u);
  EXPECT_ABS_READ32(kBase + USBDEV_EP_IN_ENABLE_REG_OFFSET, 0);
  EXPECT_ABS_WRITE32(kBase + USBDEV_EP_IN_ENABLE_REG_OFFSET, 1u);
  EXPECT_ABS_READ32(kBase + USBDEV_IN_STALL_REG_OFFSET, 0);
  EXPECT_ABS_WRITE32(kBase + USBDEV_IN_STALL_REG_OFFSET, 0);
  EXPECT_ABS_READ32(kBase + USBDEV_OUT_STALL_REG_OFFSET, 0);
  EXPECT_ABS_WRITE32(kBase + USBDEV_OUT_STALL_REG_OFFSET, 0);
  EXPECT_EQ(usb_ep_init(0, kUsbEpTypeControl, 64, EpHandler, &cb_state),
            kErrorOk);

  // 3. Queue a zero-length IN transfer on EP0 to allocate buffer id 0 from
  //    the pool (so buffer_pool_put(0) in handle_in() passes its check).
  const uint32_t kConfigInReady =
      bitfield_bit32_write(0, USBDEV_CONFIGIN_0_RDY_0_BIT, true);
  EXPECT_ABS_WRITE32(kBase + USBDEV_CONFIGIN_0_REG_OFFSET, kConfigInReady);
  EXPECT_EQ(usb_ep_transfer(kUsbDirIn | 0, nullptr, 0,
                            static_cast<usb_transfer_flags_t>(0)),
            kErrorOk);

  // 4. usb_poll(): assert PKT_SENT with IN_SENT[0]=1 and CONFIGIN_0.PEND=1 to
  //    exercise the cancelled IN error path inside handle_in().
  const uint32_t kPktSent = 1u << USBDEV_INTR_COMMON_PKT_SENT_BIT;
  EXPECT_ABS_READ32(kBase + USBDEV_INTR_STATE_REG_OFFSET, kPktSent);
  EXPECT_ABS_READ32(kBase + USBDEV_IN_SENT_REG_OFFSET, 1u);
  const uint32_t kConfigInPend = 1u << USBDEV_CONFIGIN_0_PEND_0_BIT;
  EXPECT_ABS_READ32(kBase + USBDEV_CONFIGIN_0_REG_OFFSET, kConfigInPend);
  EXPECT_ABS_WRITE32(kBase + USBDEV_CONFIGIN_0_REG_OFFSET, kConfigInPend);
  EXPECT_ABS_WRITE32(kBase + USBDEV_IN_SENT_REG_OFFSET, 1u);
  EXPECT_ABS_READ32(kBase + USBDEV_USBSTAT_REG_OFFSET, kFifosFull);
  EXPECT_ABS_WRITE32(kBase + USBDEV_INTR_STATE_REG_OFFSET, kPktSent);

  usb_poll();

  EXPECT_EQ(cb_state.calls, 1u);
  EXPECT_EQ(cb_state.ep, 0u);
  EXPECT_EQ(
      static_cast<uint32_t>(cb_state.flags),
      static_cast<uint32_t>(kUsbTransferFlagsDone | kUsbTransferFlagsError));
}

}  // namespace
}  // namespace usb_unittest
