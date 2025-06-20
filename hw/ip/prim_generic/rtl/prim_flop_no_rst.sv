// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

module prim_flop_no_rst #(
  parameter int Width = 1
) (
  input                    clk_i,
  input        [Width-1:0] d_i,
  output logic [Width-1:0] q_o
);

  always_ff @(posedge clk_i) begin
    q_o <= d_i;
  end

endmodule
