#!/bin/bash
# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

OUTPUT_DIR="${1:-/tmp/$USER/coverage_report}"
TESTS="${OUTPUT_DIR}/test_coverages"
LOGS="${OUTPUT_DIR}/test_logs"
SOURCES="${OUTPUT_DIR}/source_files"
COVERAGE="${OUTPUT_DIR}/coverage.dat"

LCOV_FILES="bazel-out/_coverage/lcov_files.tmp"

echo "Collect coverage metadata"
mkdir -p "${OUTPUT_DIR}"
mkdir -p bazel-out/_coverage
find bazel-out/*/testlogs ! -path "*/test.outputs/*" \( -name "coverage.dat" -o -name "baseline_coverage.dat" \) > "${OUTPUT_DIR}/lcov_files.tmp.found" 2>/dev/null || true

if [[ -f "${OUTPUT_DIR}/lcov_files.tmp" ]]; then
  cat "${OUTPUT_DIR}/lcov_files.tmp.found" "${OUTPUT_DIR}/lcov_files.tmp" "${LCOV_FILES}" 2>/dev/null \
    | sed 's/\.datbazel-out/\.dat\nbazel-out/g' \
    | sort -u > "${OUTPUT_DIR}/lcov_files.tmp.merged"
else
  cat "${OUTPUT_DIR}/lcov_files.tmp.found" "${LCOV_FILES}" 2>/dev/null \
    | sed 's/\.datbazel-out/\.dat\nbazel-out/g' \
    | sort -u > "${OUTPUT_DIR}/lcov_files.tmp.merged"
fi

cp -r bazel-out/_coverage/* "${OUTPUT_DIR}" 2>/dev/null || true
mv -f "${OUTPUT_DIR}/lcov_files.tmp.merged" "${OUTPUT_DIR}/lcov_files.tmp"
rm -f "${OUTPUT_DIR}/lcov_files.tmp.found" "${LCOV_FILES}"
cp -f "${OUTPUT_DIR}/lcov_files.tmp" "${LCOV_FILES}"
find "${OUTPUT_DIR}" -type f -exec chmod 644 {} +

echo "Collect all test coverage data"
mkdir -p "${TESTS}"
for dat_file in $(find bazel-out/*/testlogs ! -path "*/test.outputs/*" \( -name "coverage.dat" -o -name "baseline_coverage.dat" \) 2>/dev/null); do
  mkdir -p "${TESTS}/$(dirname "${dat_file}")"
  cp -f "${dat_file}" "${TESTS}/${dat_file}"
done

echo "Merge all coverage data"
find "${TESTS}" -type f -name "*.dat" ! -path "*_coverage_view*" ! -path "*/test.outputs/*" -exec cat {} + > "${COVERAGE}"

echo "Collect all test logs"
mkdir -p "${LOGS}"
for xml_file in $(find bazel-out/*/testlogs -name "test.xml" 2>/dev/null); do
  mkdir -p "${LOGS}/$(dirname "${xml_file}")"
  cp -f "${xml_file}" "${LOGS}/${xml_file}"
done

echo "Collect all source files listed in coverage data"
mkdir -p "${SOURCES}"
grep -h '^SF:' "${COVERAGE}" | sed 's/^SF://' | sort -u \
| rsync -a --copy-dirlinks --ignore-missing-args --files-from=- . "${SOURCES}/"

echo "coverageReport=ok" >> "${GITHUB_OUTPUT:-/dev/null}"
