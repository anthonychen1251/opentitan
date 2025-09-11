#!/bin/bash
set -euo pipefail

COVERAGE_OUTPUT_DIR="/tmp/${USER}/all_coverage/"

source ./targets_coverage_views.sh

TARGETS=(
)

EXTRA_TESTS=(
)

source "$1"
shift

BAZEL_ARGS=(
    --test_output=streamed
    # --test_timeout=600
    # --cache_test_results=no
    --config=ot_coverage
    --local_test_jobs=1
    --notest_runner_fail_fast
    --keep_going
    --spawn_strategy=processwrapper-sandbox,local,linux-sandbox
    # --jobs=1
    # --subcommands
)

source ./run_all_coverage_impl.sh
