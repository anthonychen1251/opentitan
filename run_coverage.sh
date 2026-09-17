#!/bin/bash
set -euo pipefail

REPO_DIR="$(dirname "$(realpath "$0")")"
COVERAGE_OUTPUT_DIR="/tmp/${USER}/coverage_upstream"

# Default to a single test if no arguments are provided
if [[ $# -eq 0 ]]; then
    TESTS=(
        "//sw/device/tests:uart_smoketest_fpga_cw340_test_rom"
    )
else
    TESTS=("$@")
fi

OUTPUT_BASE="$("${REPO_DIR}/bazelisk.sh" info output_base)"
LLVM_BIN="${OUTPUT_BASE}/external/toolchains_llvm++llvm+llvm_toolchain_llvm/bin"
if [[ ! -d "${LLVM_BIN}" ]]; then
    "${REPO_DIR}/bazelisk.sh" fetch @llvm_toolchain_llvm//:all
fi
export PATH="${LLVM_BIN}:${PATH}"

if ! command -v updatemem &>/dev/null; then
    for vivado_dir in "${HOME}/.Xilinx/Vivado_Lab/"*/bin "${HOME}/.Xilinx/Vivado/"*/bin /tools/Xilinx/Vivado/*/bin /opt/Xilinx/Vivado/*/bin; do
        if [[ -x "${vivado_dir}/updatemem" ]]; then
            export PATH="${vivado_dir}:${PATH}"
            break
        fi
    done
fi

COVERAGE_DAT="${REPO_DIR}/bazel-out/_coverage/_coverage_report.dat"
rm -f "${COVERAGE_DAT}"

"${REPO_DIR}/bazelisk.sh" coverage --config=ot_coverage --test_output=all "${TESTS[@]}"

genhtml -o "${COVERAGE_OUTPUT_DIR}" \
    --prefix "${REPO_DIR}" \
    --ignore-errors inconsistent,unsupported,category,range \
    "${COVERAGE_DAT}"
