// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

use anyhow::Result;
use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::time::Duration;

use crate::io::console::ConsoleDevice;
use crate::io::eeprom::AddressMode;
use crate::io::spi::Target;
use crate::spiflash::flash::SpiFlash;

pub struct SpiConsoleDevice<'a> {
    spi: &'a dyn Target,
    flash: SpiFlash,
    console_next_frame_number: Cell<u32>,
    rx_buf: RefCell<VecDeque<u8>>,
}

impl<'a> SpiConsoleDevice<'a> {
    const SPI_FRAME_HEADER_SIZE: usize = 8;
    const SPI_MAX_DATA_LENGTH: usize = 1016;
    const SPI_MAIL_BOX_BASE_ADDRESS: u32 = 0x1000;

    pub fn new(spi: &'a dyn Target) -> Result<Self> {
        let mut flash = SpiFlash {
            ..Default::default()
        };
        let address = SpiConsoleDevice::SPI_MAIL_BOX_BASE_ADDRESS;
        // Make sure we're in a mode appropriate for the address.
        let mode = if address < 0x1000000 {
            AddressMode::Mode3b
        } else {
            AddressMode::Mode4b
        };
        flash.set_address_mode(&*spi, mode)?;
        Ok(Self {
            spi,
            flash,
            rx_buf: RefCell::new(VecDeque::new()),
            console_next_frame_number: Cell::new(0),
        })
    }

    fn read_from_spi(&self) -> Result<usize> {
        // Read the SPI console frame header.
        let mut header = vec![0u8; SpiConsoleDevice::SPI_FRAME_HEADER_SIZE];
        self.flash.read(&*self.spi, SpiConsoleDevice::SPI_MAIL_BOX_BASE_ADDRESS, &mut header)?;
        let frame_number: u32 = u32::from_le_bytes(header[0..4].try_into().unwrap());
        let data_len_bytes: usize = u32::from_le_bytes(header[4..8].try_into().unwrap()) as usize;
        if frame_number != self.console_next_frame_number.get()
            || data_len_bytes > SpiConsoleDevice::SPI_MAX_DATA_LENGTH
        {
            // This frame is junk, so we do not read the data.
            return Ok(0);
        }
        self.console_next_frame_number.set(frame_number + 1);
        // Read the SPI console frame data.
        let data_len_bytes_w_pad = (data_len_bytes + 3) & !3;
        let mut data = vec![0u8; data_len_bytes_w_pad];
        let data_address: u32 = SpiConsoleDevice::SPI_MAIL_BOX_BASE_ADDRESS
            + u32::try_from(SpiConsoleDevice::SPI_FRAME_HEADER_SIZE).unwrap();
        self.flash.read(&*self.spi, data_address, &mut data)?;
        // Copy data to the internal data queue.
        self.rx_buf.borrow_mut().extend(&data[..data_len_bytes]);
        // Ack DUT that the data chunk in the mailbox has been read by sending an upload command.
        let dump_payload = vec![0u8; 4];
        self.flash.program(&*self.spi, 0x400, &dump_payload)?;
        Ok(data_len_bytes)
    }
}

impl<'a> ConsoleDevice for SpiConsoleDevice<'a> {
    fn console_read(&self, buf: &mut [u8], _timeout: Duration) -> Result<usize> {
        // Attempt to refill the internal data queue if it is empty.
        if self.rx_buf.borrow().is_empty() && self.read_from_spi()? == 0 {
            return Ok(0);
        }

        // Copy from the internal data queue to the output buffer.
        let mut i: usize = 0;
        while !self.rx_buf.borrow().is_empty() && i < buf.len() {
            buf[i] = self.rx_buf.borrow_mut().pop_front().unwrap();
            i += 1;
        }

        Ok(i)
    }
}
