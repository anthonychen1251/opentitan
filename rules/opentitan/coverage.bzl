# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

load(
    "@lowrisc_opentitan//rules:rv.bzl",
    "rv_rule",
)
load(
    "//rules/opentitan:providers.bzl",
    "SiliconBinaryInfo",
    "get_one_binary_file",
)

_TEST_SCRIPT = """\
env
elf="$(realpath "{elf_file}")"
ln -s "$elf" "${{COVERAGE_DIR}}/elf"
ls -lah "$elf"
echo "Linking"
echo "  $elf"
echo "To"
echo "  ${{COVERAGE_DIR}}/elf"
"""

def _baseline_coverage_test(ctx):
    # Get the elf to be tested
    elf = ctx.attr.elf
    elf = get_one_binary_file(elf, field = "elf", providers = [SiliconBinaryInfo])
    print(elf)

    # Nop test
    script = ctx.actions.declare_file(ctx.attr.name + ".bash")
    ctx.actions.write(script,
      _TEST_SCRIPT.format(
          elf_file = elf.short_path,
      ),
      is_executable = True)

    # Propagate all runfiles from elf attr
    runfiles = ctx.runfiles(files = ctx.files.elf + [elf])
    runfiles = runfiles.merge(ctx.attr.elf[DefaultInfo].default_runfiles)

    return DefaultInfo(
        executable = script,
        runfiles = runfiles,
    )

baseline_coverage_test = rv_rule(
    implementation = _baseline_coverage_test,
    attrs = {
        "elf": attr.label(
            allow_files = True,
            doc = "ELF file to extract baseline coverage",
        ),
        "_cc_toolchain": attr.label(default = Label("@bazel_tools//tools/cpp:current_cc_toolchain")),
        "_lcov_merger": attr.label(
            default = configuration_field(fragment = "coverage", name = "output_generator"),
            executable = True,
            cfg = "exec",
        ),
        "_collect_cc_coverage": attr.label(
            default = "//sw/device/coverage/collect_cc_coverage:baseline_coverage",
            executable = True,
            cfg = "exec",
        ),
    },
    fragments = ["cpp"],
    toolchains = ["@rules_cc//cc:toolchain_type"],
    test = True,
)
