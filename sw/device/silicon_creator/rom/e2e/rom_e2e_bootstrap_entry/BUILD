# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

load(
    "//rules/opentitan:defs.bzl",
    "cw310_params",
    "fpga_params",
    "opentitan_test",
)
load(
    "//rules:const.bzl",
    "get_lc_items",
)
load(
    "//rules:otp.bzl",
    "STD_OTP_OVERLAYS",
    "otp_image",
)
load(
    "//rules:rom_e2e.bzl",
    "maybe_skip_in_ci",
)

package(default_visibility = ["//visibility:public"])

[
    otp_image(
        name = "otp_img_e2e_bootstrap_entry_{}".format(lc_state),
        src = "//hw/top_earlgrey/data/otp:otp_json_{}".format(lc_state),
        overlays = STD_OTP_OVERLAYS,
    )
    for lc_state, _ in get_lc_items()
]

[
    opentitan_test(
        name = "e2e_bootstrap_entry_{}".format(lc_state),
        exec_env = {
            "//hw/top_earlgrey:fpga_cw310_rom_with_fake_keys": None,
        },
        fpga = fpga_params(
            timeout = "moderate",
            binaries = {"//sw/device/silicon_creator/rom/e2e:new_empty_test_slot_a": "firmware"},
            otp = ":otp_img_e2e_bootstrap_entry_{}".format(lc_state),
            tags = maybe_skip_in_ci(lc_state_val),
            test_cmd = """
                --bootstrap="{firmware}"
            """,
            test_harness = "//sw/host/tests/rom/e2e_bootstrap_entry",
        ),
        # We don't want the `empty_test` to run, but we _also_ don't want some
        # leftover flash image from a previous test to run.  So, bootstrap an
        # unsigned image to force a boot failure.
        manifest = None,
    )
    for lc_state, lc_state_val in get_lc_items()
]

test_suite(
    name = "rom_e2e_bootstrap_entry",
    tags = ["manual"],
    tests = [
        ":e2e_bootstrap_entry_{}".format(lc_state)
        for lc_state, _ in get_lc_items()
    ],
)
