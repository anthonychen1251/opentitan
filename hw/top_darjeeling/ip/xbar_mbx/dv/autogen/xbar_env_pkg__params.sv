// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// xbar_env_pkg__params generated by `tlgen.py` tool


// List of Xbar device memory map
tl_device_t xbar_devices[$] = '{
    '{"mbx0__soc", '{
        '{32'h01465000, 32'h0146501f}
    }},
    '{"mbx1__soc", '{
        '{32'h01465100, 32'h0146511f}
    }},
    '{"mbx2__soc", '{
        '{32'h01465200, 32'h0146521f}
    }},
    '{"mbx3__soc", '{
        '{32'h01465300, 32'h0146531f}
    }},
    '{"mbx4__soc", '{
        '{32'h01465400, 32'h0146541f}
    }},
    '{"mbx5__soc", '{
        '{32'h01465500, 32'h0146551f}
    }},
    '{"mbx6__soc", '{
        '{32'h01496000, 32'h0149601f}
    }},
    '{"mbx_pcie0__soc", '{
        '{32'h01460100, 32'h0146011f}
    }},
    '{"mbx_pcie1__soc", '{
        '{32'h01460200, 32'h0146021f}
    }},
    '{"racl_ctrl", '{
        '{32'h01461f00, 32'h01461fff}
    }},
    '{"ac_range_check", '{
        '{32'h01464000, 32'h014643ff}
}}};

  // List of Xbar hosts
tl_host_t xbar_hosts[$] = '{
    '{"mbx", 0, '{
        "mbx0__soc",
        "mbx1__soc",
        "mbx2__soc",
        "mbx3__soc",
        "mbx4__soc",
        "mbx5__soc",
        "mbx6__soc",
        "mbx_pcie0__soc",
        "mbx_pcie1__soc",
        "racl_ctrl",
        "ac_range_check"}}
};
