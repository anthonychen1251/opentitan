// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// tb__alert_handler_connect.sv is auto-generated by `topgen.py` tool

assign alert_if[0].alert_tx = `CHIP_HIER.u_uart0.alert_tx_o[0];
assign alert_if[1].alert_tx = `CHIP_HIER.u_uart1.alert_tx_o[0];
assign alert_if[2].alert_tx = `CHIP_HIER.u_gpio.alert_tx_o[0];
assign alert_if[3].alert_tx = `CHIP_HIER.u_spi_device.alert_tx_o[0];
assign alert_if[4].alert_tx = `CHIP_HIER.u_spi_host0.alert_tx_o[0];
assign alert_if[5].alert_tx = `CHIP_HIER.u_rv_timer.alert_tx_o[0];
assign alert_if[6].alert_tx = `CHIP_HIER.u_usbdev.alert_tx_o[0];
assign alert_if[7].alert_tx = `CHIP_HIER.u_pwrmgr_aon.alert_tx_o[0];
assign alert_if[8].alert_tx = `CHIP_HIER.u_rstmgr_aon.alert_tx_o[0];
assign alert_if[9].alert_tx = `CHIP_HIER.u_rstmgr_aon.alert_tx_o[1];
assign alert_if[10].alert_tx = `CHIP_HIER.u_clkmgr_aon.alert_tx_o[0];
assign alert_if[11].alert_tx = `CHIP_HIER.u_clkmgr_aon.alert_tx_o[1];
assign alert_if[12].alert_tx = `CHIP_HIER.u_pinmux_aon.alert_tx_o[0];
assign alert_if[13].alert_tx = `CHIP_HIER.u_aon_timer_aon.alert_tx_o[0];
assign alert_if[14].alert_tx = `CHIP_HIER.u_flash_ctrl.alert_tx_o[0];
assign alert_if[15].alert_tx = `CHIP_HIER.u_flash_ctrl.alert_tx_o[1];
assign alert_if[16].alert_tx = `CHIP_HIER.u_flash_ctrl.alert_tx_o[2];
assign alert_if[17].alert_tx = `CHIP_HIER.u_flash_ctrl.alert_tx_o[3];
assign alert_if[18].alert_tx = `CHIP_HIER.u_flash_ctrl.alert_tx_o[4];
assign alert_if[19].alert_tx = `CHIP_HIER.u_rv_plic.alert_tx_o[0];
assign alert_if[20].alert_tx = `CHIP_HIER.u_aes.alert_tx_o[0];
assign alert_if[21].alert_tx = `CHIP_HIER.u_aes.alert_tx_o[1];
assign alert_if[22].alert_tx = `CHIP_HIER.u_sram_ctrl_main.alert_tx_o[0];
assign alert_if[23].alert_tx = `CHIP_HIER.u_rom_ctrl.alert_tx_o[0];
assign alert_if[24].alert_tx = `CHIP_HIER.u_rv_core_ibex.alert_tx_o[0];
assign alert_if[25].alert_tx = `CHIP_HIER.u_rv_core_ibex.alert_tx_o[1];
assign alert_if[26].alert_tx = `CHIP_HIER.u_rv_core_ibex.alert_tx_o[2];
assign alert_if[27].alert_tx = `CHIP_HIER.u_rv_core_ibex.alert_tx_o[3];
