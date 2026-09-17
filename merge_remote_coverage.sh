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

# Copy all test.xml files from test_logs into test_coverages so test.xml sits next to coverage.dat
if [[ -d "${COLLECT_DIR}/test_logs/bazel-out" ]]; then
  cp -rf "${COLLECT_DIR}/test_logs/bazel-out/"* "${COLLECT_DIR}/test_coverages/bazel-out/"
fi

echo "[2/4] Generating unified lcov_files.tmp and coverage.dat..."
find "${COLLECT_DIR}/test_coverages/bazel-out" -type f \( -name "coverage.dat" -o -name "baseline_coverage.dat" \) | sort -u > "${COLLECT_DIR}/all_lcov_files.tmp"

# Exclude _coverage_view targets from test lcov list and overall coverage.dat
grep -v "_coverage_view" "${COLLECT_DIR}/all_lcov_files.tmp" > "${COLLECT_DIR}/lcov_files.tmp"
xargs cat < "${COLLECT_DIR}/lcov_files.tmp" > "${COLLECT_DIR}/coverage.dat"

echo "[3/4] Re-running merge-coverage-report.sh and view filtering..."
ci/scripts/merge-coverage-report.sh "${COLLECT_DIR}" "${COVERAGE_OUTPUT_DIR}/ci-cov-merge"
rm -rf "${COVERAGE_OUTPUT_DIR}/viewer"
cp -R "${COVERAGE_OUTPUT_DIR}/ci-cov-merge/viewer" "${COVERAGE_OUTPUT_DIR}/viewer"

function generate_report() {
    view_name="$1"
    shift
    view_dats=("$@")

    output_dir="${COVERAGE_OUTPUT_DIR}/${view_name}"
    temp_dat="${output_dir}.dat"
    output_dat="${output_dir}/coverage.dat"
    echo "Filter with view '${view_name}'"
    mkdir -p "${output_dir}"

    python3 util/coverage/coverage_filter.py \
        --view "${view_dats[@]}" \
        --coverage="${COLLECT_DIR}/coverage.dat" \
        --output="${temp_dat}"

    bash ./run_genhtml.sh \
        "${temp_dat}" \
        "${output_dir}"

    python3 util/coverage/gen_coverage_csv.py \
        --path="${temp_dat}" \
        > "${output_dir}/coverage.csv"

    mv "${temp_dat}" "${output_dat}"
}

view_files="$(grep "_coverage_view/coverage.dat$" "${COLLECT_DIR}/all_lcov_files.tmp")"
for view_dat in $view_files; do
    view_dir="${view_dat%/*}"
    view_name="${view_dir##*/}"
    generate_report "${view_name}" "${view_dat}"
done

generate_report "all_views" $view_files

echo "[4/4] Computing updated minimum cover set (targets_min_set.sh)..."
echo y | python3 util/coverage/min_cover_set.py \
    --view="${COVERAGE_OUTPUT_DIR}/all_views/coverage.dat" \
    --lcov_files="${COLLECT_DIR}/lcov_files.tmp"

echo "Done! All remote coverage merged and targets_min_set.sh updated."
