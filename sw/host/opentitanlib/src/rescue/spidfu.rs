// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

use anyhow::{anyhow, bail, Result};
use std::cell::RefCell;
use std::rc::Rc;
use std::time::{Duration, Instant};
use zerocopy::AsBytes;

use crate::app::TransportWrapper;
use crate::chip::rom_error::RomError;
use crate::io::spi::Target;
use crate::rescue::dfu::*;
use crate::rescue::{EntryMode, Rescue, RescueError, RescueMode, RescueParams};
use crate::spiflash::sfdp::Sdfu;
use crate::spiflash::SpiFlash;

#[repr(C)]
#[derive(Default, Debug, AsBytes)]
struct SetupData {
    request_type: u8,
    request: u8,
    value: u16,
    index: u16,
    length: u16,
}

pub struct SpiDfu {
    spi: Rc<dyn Target>,
    flash: RefCell<SpiFlash>,
    sdfu: RefCell<Sdfu>,
    params: RescueParams,
    reset_delay: Duration,
    enter_delay: Duration,
}

impl SpiDfu {
    const SET_INTERFACE: u8 = 0x0b;
    const INVALID_INTERFACE: u8 = 0xff;

    pub fn new(spi: Rc<dyn Target>, params: RescueParams) -> Self {
        SpiDfu {
            spi,
            flash: RefCell::default(),
            sdfu: RefCell::default(),
            params,
            reset_delay: Duration::from_millis(50),
            enter_delay: Duration::from_secs(5),
        }
    }

    fn wait_for_device(spi: &dyn Target, timeout: Duration) -> Result<SpiFlash> {
        let deadline = Instant::now() + timeout;
        loop {
            match SpiFlash::from_spi(spi) {
                Ok(flash) => return Ok(flash),
                Err(e) => {
                    if Instant::now() < deadline {
                        std::thread::sleep(Duration::from_millis(100));
                    } else {
                        return Err(e);
                    }
                }
            }
        }
    }

    fn expect_usb_bad_mode_write_control(
        &self,
        request_type: u8,
        request: u8,
        value: u16,
        index: u16,
    ) -> Result<()> {
        let result = self.write_control(request_type, request, value, index, &[]);
        match result {
            Ok(_) => Err(anyhow!("Invalid write control should fail")),
            Err(e) => {
                if e.to_string().contains("UsbBadSetup") {
                    Ok(())
                } else {
                    Err(anyhow!("Unexpected error: {}", e.to_string()))
                }
            }
        }
    }
    fn expect_usb_bad_mode_read_control(
        &self,
        request_type: u8,
        request: u8,
        value: u16,
        index: u16,
        data: &mut [u8],
    ) -> Result<()> {
        let result = self.read_control(request_type, request, value, index, data);
        match result {
            Ok(_) => Err(anyhow!("Invalid read control should fail")),
            Err(e) => {
                if e.to_string().contains("UsbBadSetup") {
                    Ok(())
                } else {
                    Err(anyhow!("Unexpected error: {}", e.to_string()))
                }
            }
        }
    }
}

impl Rescue for SpiDfu {
    fn enter(&self, transport: &TransportWrapper, mode: EntryMode) -> Result<()> {
        log::info!(
            "Setting {:?}({}) to trigger rescue mode.",
            self.params.trigger,
            self.params.value
        );
        self.params.set_trigger(transport, true)?;
        match mode {
            EntryMode::Reset => {
                transport.reset_target(self.reset_delay, /*clear_uart=*/ false)?
            }
            EntryMode::Reboot => {
                self.reboot()?;
                // Give the chip a chance to reset before attempting to re-read
                // the SFDP from the SPI device.
                std::thread::sleep(Duration::from_millis(100));
            }
            EntryMode::None => {}
        }

        let flash = Self::wait_for_device(&*self.spi, self.enter_delay);
        log::info!("Rescue triggered; clearing trigger condition.");
        self.params.set_trigger(transport, false)?;
        let mut flash = flash?;
        log::info!("Flash = {:?}", flash.sfdp);
        if let Some(sdfu) = flash.sfdp.as_ref().and_then(|sfdp| sfdp.sdfu.as_ref()) {
            self.sdfu.replace(sdfu.clone());
        } else {
            return Err(RescueError::NotFound(
                "Could not find SDFU parameters in the SDFP table".into(),
            )
            .into());
        }
        flash.set_address_mode_auto(&*self.spi)?;
        self.flash.replace(flash);
        Ok(())
    }

    fn set_mode(&self, mode: RescueMode) -> Result<()> {
        // Use RescueMode::EraseOwner to trigger special test cases.
        if mode == RescueMode::EraseOwner {
            let setting = u32::from(mode);
            // dfu invalid rescue mode
            self.expect_usb_bad_mode_write_control(
                DfuRequestType::Vendor.into(),
                Self::SET_INTERFACE,
                (setting >> 16) as u16,
                setting as u16,
            )?;
            // dfu vendor request invalid mode
            self.expect_usb_bad_mode_write_control(
                DfuRequestType::Vendor.into(),
                Self::INVALID_INTERFACE,
                (setting >> 16) as u16,
                setting as u16,
            )?;
            // dfu kUsbSetupReqSetInterface invalid mode
            self.expect_usb_bad_mode_write_control(
                DfuRequestType::Interface.into(),
                // kUsbSetupReqSetInterface
                11 as u8,
                (setting >> 16) as u16,
                setting as u16,
            )?;

            // dfu interface request invalid mode
            self.expect_usb_bad_mode_write_control(
                DfuRequestType::Interface.into(),
                0 as u8,
                (setting >> 16) as u16,
                setting as u16,
            )?;
            // dfu control invalid request
            self.expect_usb_bad_mode_write_control(
                DfuRequestType::Out.into(),
                7 as u8,
                (setting >> 16) as u16,
                setting as u16,
            )?;

            // dfu kUsbSetupReqGetInterface
            let _ = self.write_control(
                DfuRequestType::Interface.into(),
                // kUsbSetupReqGetInterface
                10 as u8,
                (setting >> 16) as u16,
                setting as u16,
                &[],
            )?;

            // spi dfu unsupported setupdata request
            self.expect_usb_bad_mode_write_control(
                0 as u8,
                // kUsbSetupReqGetInterface
                10 as u8,
                (setting >> 16) as u16,
                setting as u16,
            )?;

            // spi dfu invalid flash opcode command
            SpiFlash::send_invalid_flash_command(&*self.spi)?;

            // dfu packet truncated
            let payload = [0u8; 256];
            let flash = self.flash.borrow();
            flash.invalid_program(&*self.spi, 2040, &payload)?;

            // spi dfu payload overflow.
            // This test is intentionally disabled for now.
            let payload_overflow = [0u8; 300];
            let _ = flash.invalid_program(&*self.spi, 0, &payload_overflow);

            return Ok(());
        }
        // Use RescueMode::GetOwnerPage1 to trigger another set of special test cases.
        if mode == RescueMode::GetOwnerPage1 {
            let setting = u32::from(mode);
            // dfu control - kDfuActionNone
            // state transition: kDfuStateIdle -> kDfuStateIdle
            self.write_control(
                DfuRequestType::Out.into(),
                // kDfuReqAbort
                6 as u8,
                (setting >> 16) as u16,
                setting as u16,
                &[],
            )?;

            // dfu control - kDfuActionStateResponse
            // state transition: kDfuStateIdle -> kDfuStateUpLoadIdle
            self.write_control(
                DfuRequestType::Out.into(),
                // kDfuReqGetState
                5 as u8,
                (setting >> 16) as u16,
                setting as u16,
                &[],
            )?;

            // dfu control - kDfuActionClearError
            // state transition: kDfuStateUpLoadIdle -> kDfuStateError
            self.expect_usb_bad_mode_write_control(
                DfuRequestType::Out.into(),
                // kDfuReqClrStatus
                4 as u8,
                (setting >> 16) as u16,
                setting as u16,
            )?;
            // state transition: kDfuStateError -> kDfuStateIdle
            self.write_control(
                DfuRequestType::Out.into(),
                // kDfuReqClrStatus
                4 as u8,
                (setting >> 16) as u16,
                setting as u16,
                &[],
            )?;

            // dfu control - kDfuActionDataXfer bad length
            // state transition: kDfuStateIdle -> kDfuStateError
            let mut payload = [0u8; 2050];
            self.expect_usb_bad_mode_read_control(
                DfuRequestType::Out.into(),
                // kDfuReqDnLoad
                1 as u8,
                (setting >> 16) as u16,
                setting as u16,
                // setup->length > sizeof(ctx->state.data)
                &mut payload,
            )?;

            // state transition: kDfuStateError -> kDfuStateIdle
            self.write_control(
                DfuRequestType::Out.into(),
                // kDfuReqClrStatus
                4 as u8,
                (setting >> 16) as u16,
                setting as u16,
                &[],
            )?;

            // dfu control - kDfuActionDataXfer invalid download
            // state transition: kDfuStateIdle -> kDfuStateError
            let mut payload2 = [0u8; 1];
            self.expect_usb_bad_mode_read_control(
                DfuRequestType::Out.into(),
                // kDfuReqDnLoad
                1 as u8,
                (setting >> 16) as u16,
                setting as u16,
                // ctx->state.offset > ctx->state.flash_limit
                &mut payload2,
            )?;

            return Ok(());
        }
        let setting = match mode {
            // FIXME: Remap "send" modes to their corresponding "recv" mode.
            // The firmware will stage the recv data, then enter the send mode.
            RescueMode::Rescue => RescueMode::Rescue,
            RescueMode::RescueB => RescueMode::RescueB,
            RescueMode::DeviceId => RescueMode::DeviceId,
            RescueMode::BootLog => RescueMode::BootLog,
            RescueMode::BootSvcReq => RescueMode::BootSvcRsp,
            RescueMode::BootSvcRsp => RescueMode::BootSvcRsp,
            RescueMode::OwnerBlock => RescueMode::GetOwnerPage0,
            RescueMode::GetOwnerPage0 => RescueMode::GetOwnerPage0,
            _ => bail!(RescueError::BadMode(format!(
                "mode {mode:?} not supported by DFU"
            ))),
        };

        log::info!("Mode {mode} is AltSetting {setting}");
        let setting = u32::from(setting);
        // This is a proprietary version of the standard USB SetInterface command.
        self.write_control(
            DfuRequestType::Vendor.into(),
            Self::SET_INTERFACE,
            (setting >> 16) as u16,
            setting as u16,
            &[],
        )?;
        Ok(())
    }

    fn set_speed(&self, _speed: u32) -> Result<u32> {
        log::warn!("set_speed is not implemented for DFU");
        Ok(0)
    }

    fn reboot(&self) -> Result<()> {
        SpiFlash::chip_reset(&*self.spi)?;
        Ok(())
    }

    fn send(&self, data: &[u8]) -> Result<()> {
        let sdfu = self.sdfu.borrow();
        for chunk in data.chunks(sdfu.dfu_size as usize) {
            let _ = self.download(chunk)?;
            let status = loop {
                let status = self.get_status()?;
                match status.state() {
                    DfuState::DnLoadIdle | DfuState::Error => {
                        break status;
                    }
                    _ => {
                        std::thread::sleep(Duration::from_millis(status.poll_timeout() as u64));
                    }
                }
            };
            status.status()?;
        }
        // Send a zero-length chunk to signal the end.
        let _ = self.download(&[])?;
        let status = self.get_status()?;
        log::warn!("State after DFU download: {}", status.state());
        Ok(())
    }

    fn recv(&self) -> Result<Vec<u8>> {
        let sdfu = self.sdfu.borrow();
        let mut data = vec![0u8; sdfu.dfu_size as usize];
        /*
         * FIXME: what am I supposed to do here?
         * The spec seems to indicate that I should keep performing `upload` until I get back a
         * short or zero length packet.
        let mut offset = 0;
        loop {
            log::info!("upload at {offset}");
            let length = self.upload(&mut data[offset..])?;
            if length == 0 || length < data.len() - offset {
                break;
            }
            offset += length;
        }
        */
        self.upload(&mut data)?;
        let status = self.get_status()?;
        log::warn!("State after DFU upload: {}", status.state());
        Ok(data)
    }
}

impl DfuOperations for SpiDfu {
    fn get_interface(&self) -> u8 {
        0
    }

    // Implement a USB-like control write transaction using OpenTitan's SPI interface.
    // - Prepare an 8-byte SetupData structure and write it to the Mailbox.
    //   Note: `flash.program` polls the SPI status BUSY bit for completion.
    // - Read the Setup status back from the mailbox.  The status will be a
    //   single 4-byte word of type `RomError`.
    // - Write the data phase of the control transaction to SPI addresss 0.
    fn write_control(
        &self,
        request_type: u8,
        request: u8,
        value: u16,
        index: u16,
        data: &[u8],
    ) -> Result<usize> {
        let setup = SetupData {
            request_type,
            request,
            value,
            index,
            length: data.len().try_into()?,
        };
        let flash = self.flash.borrow();
        let sdfu = self.sdfu.borrow();
        flash.program(&*self.spi, sdfu.mailbox_address, setup.as_bytes())?;

        let mut result = [0u8; 4];
        flash.read(&*self.spi, sdfu.mailbox_address, &mut result)?;
        Result::<(), RomError>::from(RomError(u32::from_le_bytes(result)))?;

        flash.program(&*self.spi, 0, data)?;
        Ok(data.len())
    }

    // Implement a USB-like control read transaction using OpenTitan's SPI interface.
    // - Prepare an 8-byte SetupData structure and write it to the Mailbox.
    //   Note: `flash.program` polls the SPI status BUSY bit for completion.
    // - Read the Setup status back from the mailbox.  The status will be a
    //   single 4-byte word of type `RomError`.
    // - Read the data phase from SPI address 0.
    fn read_control(
        &self,
        request_type: u8,
        request: u8,
        value: u16,
        index: u16,
        data: &mut [u8],
    ) -> Result<usize> {
        let setup = SetupData {
            request_type,
            request,
            value,
            index,
            length: data.len().try_into()?,
        };
        let flash = self.flash.borrow();
        let sdfu = self.sdfu.borrow();
        flash.program(&*self.spi, sdfu.mailbox_address, setup.as_bytes())?;

        let mut result = [0u8; 4];
        flash.read(&*self.spi, sdfu.mailbox_address, &mut result)?;
        Result::<(), RomError>::from(RomError(u32::from_le_bytes(result)))?;

        flash.read(&*self.spi, 0, data)?;
        Ok(data.len())
    }
}
