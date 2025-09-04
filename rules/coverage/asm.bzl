# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

load("//rules/opentitan:cc.bzl", "create_cc_instrumented_files_info")

def _asm_source_with_coverage(ctx):
    """A rule that processes assembly source files for coverage.

    If coverage is enabled, this rule inject LLVM-compatible coverage mapping
    and profiling data into the assembly files. Otherwise, it simply passes
    through the original source files.

    The assembly sources need to be pre-instrumented, either manually or using
    the `sw/device/coverage/util/instrument_asm.py` tool.
    """
    inputs = ctx.files.srcs

    if ctx.coverage_instrumented():
        asm_srcs, other_srcs = [], []
        for f in inputs:
            if f.extension in ["s", "S"]:
                asm_srcs.append(f)
            else:
                other_srcs.append(f)

        outputs = [ctx.actions.declare_file(f.basename) for f in asm_srcs]

        arguments = []
        arguments.append("--input")
        arguments.extend([f.path for f in asm_srcs])
        arguments.append("--output")
        arguments.extend([f.path for f in outputs])

        ctx.actions.run(
            outputs = outputs,
            inputs = asm_srcs,
            arguments = arguments,
            executable = ctx.executable._asm_prf_data_tool,
            mnemonic = "AddAsmPrfData",
        )

        outputs.extend(other_srcs)
    else:
        outputs = inputs

    return [
        DefaultInfo(files = depset(outputs)),
        create_cc_instrumented_files_info(ctx, metadata_files = []),
    ]

asm_source_with_coverage = rule(
    implementation = _asm_source_with_coverage,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "The list of C and C++ files that are processed to create the target.",
        ),
        "_asm_prf_data_tool": attr.label(
            doc = "Tool to add asm profiling and mapping data.",
            default = "//sw/device/coverage/util:add_asm_prf_data",
            executable = True,
            cfg = "exec",
        ),
    },
    fragments = ["cpp"],
)

def asm_library_with_coverage(name, srcs, *args, data = [], **kwargs):
    """A wrapper around `cc_library` to enable coverage report for
    assembly source files.

    If coverage is enabled, the assembly source files are injected with
    LLVM-compatible coverage mapping data.

    The processed files other arguments are then passed to `cc_library`.

    If coverage is disabled, the original assembly files are passed directly
    to `cc_library`.

    Args:
      name: The name of the cc_library target.
      srcs: The list of source files. Assembly files with .s or .S extensions
        will be processed for coverage.
      ...: Additional arguments to be passed to `cc_library`.
    """
    coverage_name = name + "_asm_prf_data"
    coverage_label = ":{}".format(coverage_name)

    asm_source_with_coverage(
        name = coverage_name,
        srcs = srcs,
    )

    # Add the annotated asm to the data attribute to propagate the
    # InstrumentedFilesInfo.
    native.cc_library(
        name = name,
        srcs = [coverage_label],
        data = data + [coverage_label],
        *args,
        **kwargs
    )
