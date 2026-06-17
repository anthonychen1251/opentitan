// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

use anyhow::{Result, ensure, Context};
use clap::Parser;
use std::fs;
use std::path::PathBuf;
use std::time::Duration;
use sha2::{Digest, Sha256};

use opentitanlib::io::eeprom::AddressMode;
use opentitanlib::io::spi::{Target, Transfer};
use opentitanlib::spiflash::SpiFlash;
use opentitanlib::test_utils::init::InitializeTest;
use opentitanlib::uart::console::UartConsole;

#[derive(Debug, Parser)]
struct Opts {
    #[command(flatten)]
    init: InitializeTest,

    /// Console receive timeout.
    #[arg(long, value_parser = humantime::parse_duration, default_value = "600s")]
    timeout: Duration,

    /// Name of the debugger's SPI interface.
    #[arg(long, default_value = "BOOTSTRAP")]
    spi: String,

    /// Path to the firmware image to flash on the external SPI flash.
    #[arg(long, value_name = "IMAGE")]
    image: PathBuf,

    /// Target address (offset) in the external flash to write the image.
    #[arg(long, default_value = "0")]
    address: u32,

    /// SPI bus speed in Hz.
    #[arg(long, default_value = "6000000")]
    bus_speed: u32,
}

fn flash_image(
    spi: &dyn Target,
    spi_flash: &mut SpiFlash,
    opts: &Opts,
) -> Result<()> {
    // Read the image file.
    let image_data = fs::read(&opts.image)
        .with_context(|| format!("Failed to read image file: {:?}", opts.image))?;
    let image_len = image_data.len();
    log::info!("Flashing image: {:?} ({} bytes)", opts.image, image_len);

    let addr4b = spi_flash.address_mode == AddressMode::Mode4b;
    log::info!("Flash address mode: {}", if addr4b { "4-byte" } else { "3-byte" });

    // Enable 4-byte address mode if target address is >= 16 MiB.
    if opts.address >= 16 * 1024 * 1024 && !addr4b {
        log::info!("Target address is >= 16 MiB. Switching external flash to 4-byte address mode...");
        spi.run_transaction(&mut [opentitanlib::io::spi::Transfer::Write(&[SpiFlash::ENTER_4B])])?;
        spi_flash.address_mode = AddressMode::Mode4b;
    }

    // 1. Erase Phase
    log::info!("Erasing target sectors on the external flash...");
    let sector_size = 4096u32;
    let aligned_erase_len = (image_len as u32).div_ceil(sector_size) * sector_size;
    spi_flash.erase(spi, opts.address, aligned_erase_len)?;
    log::info!("Erase completed successfully.");

    // 2. Program Phase
    log::info!("Programming image onto the external flash (high-speed SPI)...");
    let page_size = 256usize;
    let total_pages = image_len.div_ceil(page_size);
    
    for p in 0..total_pages {
        let page_offset = p * page_size;
        let page_address = opts.address + page_offset as u32;
        let bytes_to_copy = std::cmp::min(page_size, image_len - page_offset);
        let mut page_data = vec![0xffu8; 256];
        page_data[..bytes_to_copy].copy_from_slice(&image_data[page_offset..page_offset + bytes_to_copy]);

        let attempts = 5;
        let mut success = false;

        for attempt in 1..=attempts {
            // Send WRITE_ENABLE
            spi.run_transaction(&mut [Transfer::Write(&[SpiFlash::WRITE_ENABLE])])?;

            // Send PAGE_PROGRAM
            let mut cmd_addr = vec![SpiFlash::PAGE_PROGRAM];
            if spi_flash.address_mode == AddressMode::Mode4b {
                cmd_addr.extend_from_slice(&page_address.to_be_bytes());
            } else {
                let addr_bytes = page_address.to_be_bytes();
                cmd_addr.extend_from_slice(&addr_bytes[1..4]); // 3 bytes address
            }
            
            let mut write_tx = cmd_addr;
            write_tx.extend_from_slice(&page_data);
            spi.run_transaction(&mut [Transfer::Write(&write_tx)])?;

            // CRITICAL: Sleep for 50 microseconds to let the hardware CDC settle and the firmware set WIP!
            std::thread::sleep(Duration::from_micros(50));

            // Poll status register over SPI until WIP is 0
            loop {
                let mut status_rx = [0u8; 2];
                spi.run_transaction(&mut [
                    Transfer::Write(&[SpiFlash::READ_STATUS]),
                    Transfer::Read(&mut status_rx[..1]),
                ])?;
                if (status_rx[0] & 0x01) == 0 { // WIP bit is bit 0
                    break;
                }
            }

            // Read back the page for verification
            let mut read_cmd = vec![SpiFlash::READ];
            if spi_flash.address_mode == AddressMode::Mode4b {
                read_cmd.extend_from_slice(&page_address.to_be_bytes());
            } else {
                let addr_bytes = page_address.to_be_bytes();
                read_cmd.extend_from_slice(&addr_bytes[1..4]);
            }
            
            let mut read_rx = vec![0u8; 256];
            spi.run_transaction(&mut [
                Transfer::Write(&read_cmd),
                Transfer::Read(&mut read_rx),
            ])?;

            // Verify
            if read_rx == page_data {
                success = true;
                if attempt > 1 {
                    log::info!("Page at address 0x{:08x} recovered successfully after {} attempts.", page_address, attempt);
                }
                break;
            }

            log::warn!(
                "Verification mismatch at address 0x{:08x} on attempt {}! Retrying page program...",
                page_address,
                attempt
            );
            // Wait a tiny bit before retrying to let the bus/chip settle
            std::thread::sleep(Duration::from_millis(2));
        }

        ensure!(
            success,
            "Failed to program and verify page at address 0x{:08x} after {} attempts!",
            page_address,
            attempts
        );
    }
    log::info!("Programming completed successfully.");

    // 3. Verification Phase
    log::info!("Reading back external flash bytes for verification...");
    let mut read_data = vec![0u8; image_len];
    
    // Read the data back over SPI using the passthrough interface.
    spi_flash.read(spi, opts.address, &mut read_data)?;

    log::info!("Computing SHA256 hashes...");
    let mut hasher_flashed = Sha256::new();
    hasher_flashed.update(&read_data);
    let hash_flashed = hasher_flashed.finalize();

    let mut hasher_original = Sha256::new();
    hasher_original.update(&image_data);
    let hash_original = hasher_original.finalize();

    log::info!("Original SHA256: {:x}", hash_original);
    log::info!("Flashed  SHA256: {:x}", hash_flashed);

    if hash_original != hash_flashed {
        log::error!("First 32 bytes of original: {:02x?}", &image_data[..std::cmp::min(32, image_len)]);
        log::error!("First 32 bytes of flashed:  {:02x?}", &read_data[..std::cmp::min(32, image_len)]);
        for i in 0..image_len {
            if image_data[i] != read_data[i] {
                log::error!("First byte mismatch at offset {} (0x{:x}): original = 0x{:02x}, flashed = 0x{:02x}", i, i, image_data[i], read_data[i]);
                
                let start_ctx = if i >= 32 { i - 32 } else { 0 };
                let end_ctx = std::cmp::min(image_len, i + 32);
                log::error!("Context around mismatch (offset 0x{:x} to 0x{:x}):", start_ctx, end_ctx);
                log::error!("Original: {:02x?}", &image_data[start_ctx..end_ctx]);
                log::error!("Flashed:  {:02x?}", &read_data[start_ctx..end_ctx]);
                break;
            }
        }
    }

    ensure!(
        hash_original == hash_flashed,
        "Verification failed: SHA256 hash mismatch between original and flashed data!"
    );

    log::info!("Verification SUCCESS! Flashed data matches original image perfectly.");
    Ok(())
}

fn main() -> Result<()> {
    let mut opts = Opts::parse();
    opts.init.init_logging();

    // Default to the compiled flash_programmer agent image if not specified.
    if opts.init.bootstrap.bootstrap.is_none() {
        opts.init.bootstrap.bootstrap = Some(PathBuf::from(
            "sw/device/tests/flash_programmer_fpga_cw340_sival_rom_ext.img",
        ));
    }

    log::info!("Bootstrapping the target OpenTitan device with the flash_programmer agent...");
    let transport = opts.init.init_target()?;

    let uart = transport.uart("console")?;
    uart.set_flow_control(true)?;
    
    log::info!("Waiting for the flash_programmer agent to boot...");
    let _ = UartConsole::wait_for(&*uart, r"Flash Programmer Agent is ready\.", opts.timeout)?;
    log::info!("Agent booted successfully!");

    let spi = transport.spi(&opts.spi)?;
    spi.set_max_speed(opts.bus_speed)?;

    // Read the SFDP table directly over SPI (in hardware passthrough!).
    log::info!("Reading SFDP table directly over SPI...");
    let sfdp = SpiFlash::read_sfdp(&*spi)
        .context("Failed to read SFDP table over SPI. Check flash chip connection.")?;
    let mut spi_flash = SpiFlash::from_sfdp(sfdp);
    log::info!("External SPI flash initialized. Size = {} bytes", spi_flash.size);

    flash_image(&*spi, &mut spi_flash, &opts)?;

    log::info!("All operations completed successfully!");
    Ok(())
}
