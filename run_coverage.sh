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

COVERAGE_DAT="${REPO_DIR}/bazel-out/_coverage/_coverage_report.dat"
rm -f "${COVERAGE_DAT}"

"${REPO_DIR}/bazelisk.sh" coverage --config=ot_coverage --test_output=all "${TESTS[@]}"

genhtml -o "${COVERAGE_OUTPUT_DIR}" \
    --prefix "${REPO_DIR}" \
    --ignore-errors inconsistent,unsupported,category,range \
    "${COVERAGE_DAT}"
