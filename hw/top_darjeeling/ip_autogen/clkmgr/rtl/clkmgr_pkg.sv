// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

package clkmgr_pkg;

  typedef enum int {
    HintMainAes = 0,
    HintMainHmac = 1,
    HintMainKmac = 2,
    HintMainOtbn = 3
  } hint_names_e;

  // clocks generated and broadcast
  typedef struct packed {
    logic clk_io_div4_powerup;
    logic clk_aon_powerup;
    logic clk_main_powerup;
    logic clk_io_powerup;
    logic clk_io_div2_powerup;
    logic clk_aon_infra;
    logic clk_aon_peri;
    logic clk_aon_timers;
    logic clk_main_aes;
    logic clk_main_hmac;
    logic clk_main_kmac;
    logic clk_main_otbn;
    logic clk_io_div4_infra;
    logic clk_main_infra;
    logic clk_io_div4_secure;
    logic clk_main_secure;
    logic clk_io_div4_timers;
    logic clk_io_div4_peri;
    logic clk_io_div2_peri;
  } clkmgr_out_t;

  // clock gating indication for alert handler
  typedef struct packed {
    prim_mubi_pkg::mubi4_t io_div4_powerup;
    prim_mubi_pkg::mubi4_t aon_powerup;
    prim_mubi_pkg::mubi4_t main_powerup;
    prim_mubi_pkg::mubi4_t io_powerup;
    prim_mubi_pkg::mubi4_t io_div2_powerup;
    prim_mubi_pkg::mubi4_t aon_infra;
    prim_mubi_pkg::mubi4_t aon_peri;
    prim_mubi_pkg::mubi4_t aon_timers;
    prim_mubi_pkg::mubi4_t main_aes;
    prim_mubi_pkg::mubi4_t main_hmac;
    prim_mubi_pkg::mubi4_t main_kmac;
    prim_mubi_pkg::mubi4_t main_otbn;
    prim_mubi_pkg::mubi4_t io_div4_infra;
    prim_mubi_pkg::mubi4_t main_infra;
    prim_mubi_pkg::mubi4_t io_div4_secure;
    prim_mubi_pkg::mubi4_t main_secure;
    prim_mubi_pkg::mubi4_t io_div4_timers;
    prim_mubi_pkg::mubi4_t io_div4_peri;
    prim_mubi_pkg::mubi4_t io_div2_peri;
  } clkmgr_cg_en_t;

  parameter int NumOutputClk = 19;


  typedef struct packed {
    logic [4-1:0] idle;
  } clk_hint_status_t;

  parameter clk_hint_status_t CLK_HINT_STATUS_DEFAULT = '{
    idle: {4{1'b1}}
  };

endpackage // clkmgr_pkg
