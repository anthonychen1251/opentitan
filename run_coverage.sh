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

if ! command -v updatemem &>/dev/null; then
    for vivado_dir in "${HOME}/.Xilinx/Vivado_Lab/"*/bin "${HOME}/.Xilinx/Vivado/"*/bin /tools/Xilinx/Vivado/*/bin /opt/Xilinx/Vivado/*/bin; do
        if [[ -x "${vivado_dir}/updatemem" ]]; then
            export PATH="${vivado_dir}:${PATH}"
            break
        fi
    done
fi

if ! command -v clang &>/dev/null || ! command -v llvm-cov &>/dev/null || ! command -v llvm-profdata &>/dev/null; then
    if command -v clang &>/dev/null; then
        clang_bin_dir="$(dirname "$(readlink -f "$(command -v clang)")")"
        if [[ -x "${clang_bin_dir}/llvm-cov" && -x "${clang_bin_dir}/llvm-profdata" ]]; then
            export PATH="${clang_bin_dir}:${PATH}"
        fi
    fi
fi

if ! command -v clang &>/dev/null || ! command -v llvm-cov &>/dev/null || ! command -v llvm-profdata &>/dev/null; then
    for llvm_dir in /usr/lib/llvm-*/bin; do
        if [[ -x "${llvm_dir}/clang" && -x "${llvm_dir}/llvm-cov" && -x "${llvm_dir}/llvm-profdata" ]]; then
            export PATH="${llvm_dir}:${PATH}"
            break
        fi
    done
fi

for llvm_tool in clang llvm-cov llvm-profdata; do
    if ! command -v "${llvm_tool}" &>/dev/null; then
        echo "ERROR: Required LLVM coverage tool '${llvm_tool}' not found in PATH."
        exit 1
    fi
done

bazel_output_base="$("${REPO_DIR}/bazelisk.sh" info output_base 2>/dev/null || true)"
cc_toolchain_build="${bazel_output_base}/external/rules_cc++cc_configure_extension+local_config_cc/BUILD"
if [[ -f "${cc_toolchain_build}" ]]; then
    if ! grep -q '"llvm-cov":' "${cc_toolchain_build}" || \
       ! grep -q '"llvm-profdata":' "${cc_toolchain_build}" || \
       ! grep -q '"gcov":' "${cc_toolchain_build}"; then
        echo "Reconfiguring stale Bazel host C++ toolchain for LLVM coverage..."
        rm -rf "${bazel_output_base}/external/"*local_config_cc*
        "${REPO_DIR}/bazelisk.sh" shutdown
    fi
fi

COVERAGE_DAT="${REPO_DIR}/bazel-out/_coverage/_coverage_report.dat"
rm -f "${COVERAGE_DAT}"

"${REPO_DIR}/bazelisk.sh" coverage --config=ot_coverage --test_output=all "${TESTS[@]}"

genhtml -o "${COVERAGE_OUTPUT_DIR}" \
    --prefix "${REPO_DIR}" \
    --ignore-errors inconsistent,unsupported,category,range \
    "${COVERAGE_DAT}"
