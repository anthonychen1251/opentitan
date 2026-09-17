#!/bin/bash
set -euo pipefail

REMOTE_DIR="${1:-}"
if [[ -z "${REMOTE_DIR}" || ! -d "${REMOTE_DIR}" ]]; then
  echo "Usage: ./merge_remote_coverage.sh /path/to/copied_ci_cov_merge_dir"
  exit 1
fi

COVERAGE_OUTPUT_DIR="/tmp/${USER}/all_coverage"
COLLECT_DIR="${COVERAGE_OUTPUT_DIR}/ci-cov-collect"

echo "[1/4] Extracting remote test_coverages.tar.gz and test_logs.tar.gz..."
mkdir -p "${COLLECT_DIR}"
tar -xzf "${REMOTE_DIR}/test_coverages.tar.gz" -C "${COLLECT_DIR}"
tar -xzf "${REMOTE_DIR}/test_logs.tar.gz" -C "${COLLECT_DIR}"

# Also copy extracted bazel-out testlogs into local bazel-out so iter_lcov_files finds them
if [[ -d "${COLLECT_DIR}/test_coverages/bazel-out" ]]; then
  rsync -a --copy-dirlinks "${COLLECT_DIR}/test_coverages/bazel-out/" bazel-out/
fi
if [[ -d "${COLLECT_DIR}/test_logs/bazel-out" ]]; then
  rsync -a --copy-dirlinks "${COLLECT_DIR}/test_logs/bazel-out/" bazel-out/
fi

echo "[2/4] Merging lcov_files.tmp and coverage.dat..."
cat "${REMOTE_DIR}/lcov_files.tmp" "${COLLECT_DIR}/lcov_files.tmp" | sort -u > "${COLLECT_DIR}/lcov_files.tmp.merged"
mv "${COLLECT_DIR}/lcov_files.tmp.merged" "${COLLECT_DIR}/lcov_files.tmp"
cp "${COLLECT_DIR}/lcov_files.tmp" bazel-out/_coverage/lcov_files.tmp

find "${COLLECT_DIR}/test_coverages" -type f -name "*.dat" -exec cat {} + > "${COLLECT_DIR}/coverage.dat"

echo "[3/4] Re-running merge-coverage-report.sh and view filtering..."
ci/scripts/merge-coverage-report.sh "${COLLECT_DIR}" "${COVERAGE_OUTPUT_DIR}/ci-cov-merge"
rm -rf "${COVERAGE_OUTPUT_DIR}/viewer"
cp -R "${COVERAGE_OUTPUT_DIR}/ci-cov-merge/viewer" "${COVERAGE_OUTPUT_DIR}/viewer"

source ./targets_coverage_views.sh
TEST_LOGS_DIR="bazel-out/k8-fastbuild/testlogs/"
view_files="$(cat "${COLLECT_DIR}/lcov_files.tmp" | grep "_coverage_view/coverage.dat$")"

python3 util/coverage/coverage_filter.py \
    --view $view_files \
    --coverage="${COLLECT_DIR}/coverage.dat" \
    --output="${COVERAGE_OUTPUT_DIR}/all_views/coverage.dat"

bash ./run_genhtml.sh \
    "${COVERAGE_OUTPUT_DIR}/all_views/coverage.dat" \
    "${COVERAGE_OUTPUT_DIR}/all_views"

echo "[4/4] Computing updated minimum cover set (targets_min_set.sh)..."
yes y | python3 util/coverage/min_cover_set.py \
    --view="${COVERAGE_OUTPUT_DIR}/all_views/coverage.dat" \
    --lcov_files="${COLLECT_DIR}/lcov_files.tmp"

echo "Done! All remote coverage merged and targets_min_set.sh updated."
