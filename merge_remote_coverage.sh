#!/bin/bash
set -euo pipefail

REMOTE_DIR="${1:-}"
COVERAGE_OUTPUT_DIR="/tmp/${USER}/all_coverage"
COLLECT_DIR="${COVERAGE_OUTPUT_DIR}/ci-cov-collect"

if [[ -n "${REMOTE_DIR}" && -d "${REMOTE_DIR}" ]]; then
  echo "[1/4] Extracting remote test_coverages.tar.gz and test_logs.tar.gz..."
  mkdir -p "${COLLECT_DIR}"
  tar -xzf "${REMOTE_DIR}/test_coverages.tar.gz" -C "${COLLECT_DIR}"
  tar -xzf "${REMOTE_DIR}/test_logs.tar.gz" -C "${COLLECT_DIR}"

  # Copy all test.xml files from test_logs into test_coverages so test.xml sits next to coverage.dat
  if [[ -d "${COLLECT_DIR}/test_logs/bazel-out" ]]; then
    cp -rf "${COLLECT_DIR}/test_logs/bazel-out/"* "${COLLECT_DIR}/test_coverages/bazel-out/"
  fi
fi

# Sync any newly run test coverage.dat, baseline_coverage.dat, and test.xml from local bazel-out into COLLECT_DIR
for f in $(find bazel-out/*/testlogs ! -path "*/test.outputs/*" \( -name "coverage.dat" -o -name "baseline_coverage.dat" -o -name "test.xml" \) 2>/dev/null); do
  mkdir -p "${COLLECT_DIR}/test_coverages/$(dirname "${f}")"
  cp -f "${f}" "${COLLECT_DIR}/test_coverages/${f}"
done

echo "[2/4] Generating unified lcov_files.tmp and coverage.dat..."
find "${COLLECT_DIR}/test_coverages/bazel-out" -type f \( -name "coverage.dat" -o -name "baseline_coverage.dat" \) | sort -u > "${COLLECT_DIR}/all_lcov_files.tmp"

# Exclude _coverage_view targets from test lcov list and overall coverage.dat
grep -v "_coverage_view" "${COLLECT_DIR}/all_lcov_files.tmp" > "${COLLECT_DIR}/lcov_files.tmp"
xargs cat < "${COLLECT_DIR}/lcov_files.tmp" > "${COLLECT_DIR}/coverage.dat"
sed -i "s|^${COLLECT_DIR}/test_coverages/||" "${COLLECT_DIR}/lcov_files.tmp"

if [[ -n "${REMOTE_DIR}" && -d "${REMOTE_DIR}" ]]; then
  echo "[3/4] Re-running merge-coverage-report.sh..."
  ci/scripts/merge-coverage-report.sh "${COLLECT_DIR}" "${COVERAGE_OUTPUT_DIR}/ci-cov-merge"
  rm -rf "${COVERAGE_OUTPUT_DIR}/viewer"
  cp -R "${COVERAGE_OUTPUT_DIR}/ci-cov-merge/viewer" "${COVERAGE_OUTPUT_DIR}/viewer"
fi

echo "[3/4] Filtering views from targets_coverage_views.sh..."
source ./targets_coverage_views.sh
TEST_LOGS_DIR="${COLLECT_DIR}/test_coverages/bazel-out/k8-fastbuild/testlogs/"

COVERAGE_VIEWS=()
for group_name in "${COVERAGE_VIEW_GROUPS[@]}"; do
    group_expr="${group_name}[@]"
    group=( "${!group_expr}" )
    COVERAGE_VIEWS+=( "${group[@]}" )
done

function generate_report() {
    view_name="$1"
    shift
    view_dats=("$@")

    output_dir="${COVERAGE_OUTPUT_DIR}/${view_name}"
    temp_dat="${output_dir}.dat"
    output_dat="${output_dir}/coverage.dat"
    echo "Filter with view '${view_name}'"
    rm -rf "${output_dir}"
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

# Remove stale view folders not in current COVERAGE_VIEWS
rm -rf "${COVERAGE_OUTPUT_DIR}"/*_coverage_view "${COVERAGE_OUTPUT_DIR}"/coverage_view_* "${COVERAGE_OUTPUT_DIR}/all_views"

active_view_files=()
for view_target in "${COVERAGE_VIEWS[@]}"; do
    rel_path="${view_target#//}"
    rel_path="${rel_path//://}"
    view_dat="${TEST_LOGS_DIR}${rel_path}/coverage.dat"
    view_name="${rel_path##*/}"
    active_view_files+=( "${view_dat}" )
    generate_report "${view_name}" "${view_dat}"
done

for group_name in "${COVERAGE_VIEW_GROUPS[@]}"; do
    group_expr="${group_name}[@]"
    group=( "${!group_expr}" )
    group=( "${group[@]//:/\/}" )
    group=( "${group[@]/#\/\//$TEST_LOGS_DIR}" )
    group=( "${group[@]/%/\/coverage.dat}" )
    group_name_lower="${group_name,,}"
    generate_report "${group_name_lower}" "${group[@]}"
done

generate_report "all_views" "${active_view_files[@]}"

echo "[4/4] Computing updated minimum cover set (targets_min_set.sh)..."
echo y | python3 util/coverage/min_cover_set.py \
    --view="${COVERAGE_OUTPUT_DIR}/all_views/coverage.dat" \
    --lcov_files="${COLLECT_DIR}/lcov_files.tmp"

echo "Done! All views and targets_min_set.sh updated."
