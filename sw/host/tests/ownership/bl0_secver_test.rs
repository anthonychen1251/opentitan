// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#![allow(clippy::bool_assert_comparison)]
use anyhow::{Result, ensure};
use clap::{Parser, ValueEnum};
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

use opentitanlib::app::{TransportWrapper, UartRx};
use opentitanlib::chip::boot_svc::{BootSlot, UnlockMode};
use opentitanlib::chip::rom_error::RomError;
use opentitanlib::io::uart::Uart;
use opentitanlib::ownership::{OwnershipKeyAlg, MinSecurityVersion, OwnershipUpdateMode};
use opentitanlib::rescue::serial::RescueSerial;
use opentitanlib::rescue::{EntryMode, Rescue};
use opentitanlib::test_utils::init::InitializeTest;
use opentitanlib::uart::console::UartConsole;
use transfer_lib::HybridPair;

#[derive(ValueEnum, Clone, Copy, Debug, PartialEq, Eq)]
enum TestMode {
    Persistence,
    Monotonic,
    TransferReset,
}

#[derive(Debug, Parser)]
struct Opts {
    #[command(flatten)]
    init: InitializeTest,

    /// Console receive timeout.
    #[arg(long, value_parser = humantime::parse_duration, default_value = "10s")]
    timeout: Duration,

    #[arg(long, value_enum, help = "Test mode to execute")]
    test_mode: TestMode,

    // Keys for fake/first owner (used in all tests)
    #[arg(long)]
    fake_owner_key: PathBuf,
    #[arg(long)]
    fake_unlock_key: PathBuf,
    #[arg(long)]
    fake_activate_key: PathBuf,
    #[arg(long)]
    fake_app_key: Option<PathBuf>,

    // Keys for dummy/second owner (only used in TransferReset)
    #[arg(long)]
    dummy_owner_key: Option<PathBuf>,
    #[arg(long)]
    dummy_unlock_key: Option<PathBuf>,
    #[arg(long)]
    dummy_activate_key: Option<PathBuf>,
    #[arg(long)]
    dummy_app_key: Option<PathBuf>,

    #[arg(long, value_parser = humantime::parse_duration, help = "Max timeout to enter rescue mode")]
    rescue_enter_delay: Option<Duration>,

    #[arg(
        long,
        value_enum,
        default_value = "basic",
        help = "Style of Owner Config for this test"
    )]
    config_kind: transfer_lib::OwnerConfigKind,
}

fn wait_for_boot(uart: &dyn Uart, timeout: Duration, expected_ver: u32, expected_min: u32) -> Result<()> {
    let capture = UartConsole::wait_for(
        uart,
        r"(?msR)Running.*PASS!$|BFV:([0-9A-Fa-f]{8})$",
        timeout,
    )?;
    if capture[0].starts_with("BFV") {
        let err = u32::from_str_radix(&capture[1], 16)?;
        if err == 0 {
            log::info!("Detected expected write-and-reboot (BFV:00000000). Waiting for next boot...");
            // Wait again for the actual boot to PASS!
            let capture2 = UartConsole::wait_for(
                uart,
                r"(?msR)Running.*PASS!$|BFV:([0-9A-Fa-f]{8})$",
                timeout,
            )?;
            if capture2[0].starts_with("BFV") {
                return RomError(u32::from_str_radix(&capture2[1], 16)?).into();
            }
            ensure!(capture2[0].contains(&format!("config_version = {expected_ver}")), "Expected config_version = {expected_ver}");
            ensure!(capture2[0].contains(&format!("bl0_min_sec_ver = {expected_min}")), "Expected bl0_min_sec_ver = {expected_min}");
        } else {
            return RomError(err).into();
        }
    } else {
        ensure!(capture[0].contains(&format!("config_version = {expected_ver}")), "Expected config_version = {expected_ver}");
        ensure!(capture[0].contains(&format!("bl0_min_sec_ver = {expected_min}")), "Expected bl0_min_sec_ver = {expected_min}");
    }
    Ok(())
}

fn run_persistence_test(opts: &Opts, transport: &TransportWrapper) -> Result<()> {
    let uart = transport.uart("console")?;
    let rescue = RescueSerial::new(Rc::clone(&uart), opts.rescue_enter_delay);
    let fake_app_key = opts.fake_app_key.as_ref().ok_or_else(|| anyhow::anyhow!("fake_app_key is required for Persistence mode"))?;

    log::info!("###### Get Device Info (1) ######");
    rescue.enter(transport, EntryMode::Reset)?;
    let (data, _devid) = transfer_lib::get_device_info(transport, &rescue)?;

    log::info!("###### Upload Owner Block V2 (min_sec_ver = 5) ######");
    transfer_lib::create_owner(
        transport,
        &rescue,
        data.rom_ext_nonce,
        OwnershipKeyAlg::EcdsaP256,
        HybridPair::load(Some(&opts.fake_owner_key), None)?,
        HybridPair::load(Some(&opts.fake_activate_key), None)?,
        HybridPair::load(Some(&opts.fake_unlock_key), None)?,
        fake_app_key,
        opts.config_kind,
        |owner| {
            owner.config_version = 2;
            owner.min_security_version_bl0 = MinSecurityVersion(5);
            owner.update_mode = OwnershipUpdateMode::NewVersion;
        },
    )?;

    log::info!("###### Boot After V2 Update (should trigger reboot and persist) ######");
    transport.reset_with_delay(UartRx::Clear, Duration::from_millis(50))?;
    wait_for_boot(&*uart, opts.timeout, 2, 5)?;

    log::info!("###### Reboot again to verify persistence ######");
    transport.reset_with_delay(UartRx::Clear, Duration::from_millis(50))?;

    let capture = UartConsole::wait_for(
        &*uart,
        r"(?msR)Running.*PASS!$|BFV:([0-9A-Fa-f]{8})$",
        opts.timeout,
    )?;
    ensure!(!capture[0].starts_with("BFV"), "Boot failed or triggered unexpected reboot");
    ensure!(capture[0].contains("config_version = 2"), "Expected config_version = 2");
    ensure!(capture[0].contains("bl0_min_sec_ver = 5"), "Expected bl0_min_sec_ver = 5");

    log::info!("###### BL0 SecVer Persistence test passed! ######");
    Ok(())
}

fn run_monotonic_test(opts: &Opts, transport: &TransportWrapper) -> Result<()> {
    let uart = transport.uart("console")?;
    let rescue = RescueSerial::new(Rc::clone(&uart), opts.rescue_enter_delay);
    let fake_app_key = opts.fake_app_key.as_ref().ok_or_else(|| anyhow::anyhow!("fake_app_key is required for Monotonic mode"))?;

    log::info!("###### Get Device Info (1) ######");
    rescue.enter(transport, EntryMode::Reset)?;
    let (data, _devid) = transfer_lib::get_device_info(transport, &rescue)?;

    log::info!("###### Upload Owner Block V2 (min_sec_ver = 5) ######");
    transfer_lib::create_owner(
        transport,
        &rescue,
        data.rom_ext_nonce,
        OwnershipKeyAlg::EcdsaP256,
        HybridPair::load(Some(&opts.fake_owner_key), None)?,
        HybridPair::load(Some(&opts.fake_activate_key), None)?,
        HybridPair::load(Some(&opts.fake_unlock_key), None)?,
        fake_app_key,
        opts.config_kind,
        |owner| {
            owner.config_version = 2;
            owner.min_security_version_bl0 = MinSecurityVersion(5);
            owner.update_mode = OwnershipUpdateMode::NewVersion;
        },
    )?;

    log::info!("###### Boot After V2 Update ######");
    transport.reset_with_delay(UartRx::Clear, Duration::from_millis(50))?;
    wait_for_boot(&*uart, opts.timeout, 2, 5)?;

    log::info!("###### Get Device Info (2) ######");
    rescue.enter(transport, EntryMode::Reset)?;
    let (data, _devid) = transfer_lib::get_device_info(transport, &rescue)?;

    log::info!("###### Upload Owner Block V3 (min_sec_ver = 3) ######");
    transfer_lib::create_owner(
        transport,
        &rescue,
        data.rom_ext_nonce,
        OwnershipKeyAlg::EcdsaP256,
        HybridPair::load(Some(&opts.fake_owner_key), None)?,
        HybridPair::load(Some(&opts.fake_activate_key), None)?,
        HybridPair::load(Some(&opts.fake_unlock_key), None)?,
        fake_app_key,
        opts.config_kind,
        |owner| {
            owner.config_version = 3;
            owner.min_security_version_bl0 = MinSecurityVersion(3); // Attempt downgrade
            owner.update_mode = OwnershipUpdateMode::NewVersion;
        },
    )?;

    log::info!("###### Boot After V3 Update (should not downgrade) ######");
    transport.reset_with_delay(UartRx::Clear, Duration::from_millis(50))?;
    wait_for_boot(&*uart, opts.timeout, 3, 5)?;

    log::info!("###### BL0 SecVer Monotonic test passed! ######");
    Ok(())
}

fn run_transfer_reset_test(opts: &Opts, transport: &TransportWrapper) -> Result<()> {
    let uart = transport.uart("console")?;
    let rescue = RescueSerial::new(Rc::clone(&uart), opts.rescue_enter_delay);

    // We must ensure dummy keys are provided for this test
    let dummy_owner_key = opts.dummy_owner_key.as_ref().ok_or_else(|| anyhow::anyhow!("dummy_owner_key is required for TransferReset mode"))?;
    let dummy_unlock_key = opts.dummy_unlock_key.as_ref().ok_or_else(|| anyhow::anyhow!("dummy_unlock_key is required for TransferReset mode"))?;
    let dummy_activate_key = opts.dummy_activate_key.as_ref().ok_or_else(|| anyhow::anyhow!("dummy_activate_key is required for TransferReset mode"))?;
    let dummy_app_key = opts.dummy_app_key.as_ref().ok_or_else(|| anyhow::anyhow!("dummy_app_key is required for TransferReset mode"))?;

    log::info!("###### Get Device Info (1) ######");
    let (data, devid) = transfer_lib::get_device_info(transport, &rescue)?;

    log::info!("###### Unlock Fake Owner (1) ######");
    transfer_lib::ownership_unlock(
        transport,
        &rescue,
        UnlockMode::Any,
        data.rom_ext_nonce,
        devid.din,
        OwnershipKeyAlg::EcdsaP256,
        Some(opts.fake_unlock_key.clone()),
        None,
        None,
        None,
        false,
    )?;

    log::info!("###### Get Device Info (2) ######");
    let (data, _devid) = transfer_lib::get_device_info(transport, &rescue)?;

    log::info!("###### Upload Fake Owner Block V2 (min = 5) ######");
    transfer_lib::create_owner(
        transport,
        &rescue,
        data.rom_ext_nonce,
        OwnershipKeyAlg::EcdsaP256,
        HybridPair::load(Some(&opts.fake_owner_key), None)?,
        HybridPair::load(Some(&opts.fake_activate_key), None)?,
        HybridPair::load(Some(&opts.fake_unlock_key), None)?,
        dummy_app_key, // Use dummy app key to allow intermediate boot
        opts.config_kind,
        |owner| {
            owner.config_version = 2;
            owner.min_security_version_bl0 = MinSecurityVersion(5);
        },
    )?;

    log::info!("###### Activate Fake Owner V2 ######");
    transfer_lib::ownership_activate(
        transport,
        &rescue,
        data.rom_ext_nonce,
        devid.din,
        OwnershipKeyAlg::EcdsaP256,
        Some(opts.fake_activate_key.clone()),
        None,
        BootSlot::SlotA,
    )?;

    log::info!("###### Boot After Fake V2 Update ######");
    transport.reset_with_delay(UartRx::Clear, Duration::from_millis(50))?;
    let capture = UartConsole::wait_for(
        &*uart,
        r"(?msR)Running.*PASS!$|BFV:([0-9A-Fa-f]{8})$",
        opts.timeout,
    )?;
    if capture[0].starts_with("BFV") {
        return RomError(u32::from_str_radix(&capture[1], 16)?).into();
    }
    ensure!(capture[0].contains("ownership_state = OWND"), "Expected state OWND");
    ensure!(capture[0].contains("config_version = 2"), "Expected config_version = 2");
    ensure!(capture[0].contains("bl0_min_sec_ver = 5"), "Expected bl0_min_sec_ver = 5");

    log::info!("###### Get Device Info (3) ######");
    let (data, devid) = transfer_lib::get_device_info(transport, &rescue)?;

    log::info!("###### Unlock Fake Owner (2) ######");
    transfer_lib::ownership_unlock(
        transport,
        &rescue,
        UnlockMode::Any,
        data.rom_ext_nonce,
        devid.din,
        OwnershipKeyAlg::EcdsaP256,
        Some(opts.fake_unlock_key.clone()),
        None,
        None,
        None,
        false,
    )?;

    log::info!("###### Get Device Info (4) ######");
    let (data, _devid) = transfer_lib::get_device_info(transport, &rescue)?;

    log::info!("###### Upload Dummy Owner Block (min = 3) ######");
    transfer_lib::create_owner(
        transport,
        &rescue,
        data.rom_ext_nonce,
        OwnershipKeyAlg::EcdsaP256,
        HybridPair::load(Some(dummy_owner_key), None)?,
        HybridPair::load(Some(dummy_activate_key), None)?,
        HybridPair::load(Some(dummy_unlock_key), None)?,
        dummy_app_key,
        opts.config_kind,
        |owner| {
            owner.config_version = 1;
            owner.min_security_version_bl0 = MinSecurityVersion(3); // Downgrade allowed during transfer
        },
    )?;

    log::info!("###### Activate Dummy Owner ######");
    transfer_lib::ownership_activate(
        transport,
        &rescue,
        data.rom_ext_nonce,
        devid.din,
        OwnershipKeyAlg::EcdsaP256,
        Some(dummy_activate_key.clone()),
        None,
        BootSlot::SlotA,
    )?;

    log::info!("###### Boot After Transfer to Dummy ######");
    transport.reset_with_delay(UartRx::Clear, Duration::from_millis(50))?;
    let capture = UartConsole::wait_for(
        &*uart,
        r"(?msR)Running.*PASS!$|BFV:([0-9A-Fa-f]{8})$",
        opts.timeout,
    )?;
    if capture[0].starts_with("BFV") {
        return RomError(u32::from_str_radix(&capture[1], 16)?).into();
    }
    ensure!(capture[0].contains("ownership_state = OWND"), "Expected state OWND");
    ensure!(capture[0].contains("config_version = 1"), "Expected config_version = 1");
    ensure!(capture[0].contains("bl0_min_sec_ver = 3"), "Expected bl0_min_sec_ver = 3 (downgrade allowed)");

    log::info!("###### BL0 SecVer Transfer Reset test passed! ######");
    Ok(())
}

fn main() -> Result<()> {
    let opts = Opts::parse();
    opts.init.init_logging();
    let transport = opts.init.init_target()?;

    match opts.test_mode {
        TestMode::Persistence => run_persistence_test(&opts, &transport),
        TestMode::Monotonic => run_monotonic_test(&opts, &transport),
        TestMode::TransferReset => run_transfer_reset_test(&opts, &transport),
    }
}
