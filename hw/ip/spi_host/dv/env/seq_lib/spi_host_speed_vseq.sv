// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// speed test vseq
class spi_host_speed_vseq extends spi_host_smoke_vseq;
  `uvm_object_utils(spi_host_speed_vseq)
  `uvm_object_new

  constraint spi_config_regs_c {
      // configopts regs
      spi_config_regs.cpol dist {
        1'b0 :/ 1,
        1'b1 :/ 1
      };
      spi_config_regs.cpha dist {
        1'b0 :/ 1,
        1'b1 :/ 1
      };
      spi_config_regs.csnlead inside {[cfg.seq_cfg.host_spi_min_csn_latency :
                                       cfg.seq_cfg.host_spi_max_csn_latency]};
      spi_config_regs.csntrail inside {[cfg.seq_cfg.host_spi_min_csn_latency :
                                        cfg.seq_cfg.host_spi_max_csn_latency]};
      spi_config_regs.csnidle inside {[cfg.seq_cfg.host_spi_min_csn_latency :
                                       cfg.seq_cfg.host_spi_max_csn_latency]};
  }

  constraint spi_config_regs_clkdiv_c {
    // CLKDIV randomised not in the whole range since there's a dedicated VSEQ:
    // spi_host_upper_range_clkdiv_vseq.sv which uses the upper range of clock
    // divider values - this way we won't have super long  tests when running this VSEQ
    spi_config_regs.clkdiv inside {[cfg.seq_cfg.host_spi_min_clkdiv :
                                    cfg.seq_cfg.host_spi_lower_middle_clkdiv]};
  }

  virtual task start_spi_host_trans(int num_transactions, bit wait_ready = 1'b1);
    cfg.seq_cfg.std_en  = 1;
    cfg.seq_cfg.dual_en = 1;
    cfg.seq_cfg.quad_en = 1;
    super.start_spi_host_trans(num_transactions);
  endtask

endclass : spi_host_speed_vseq
