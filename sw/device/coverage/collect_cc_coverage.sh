#!/bin/bash
 # Copyright 2016 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script collects code coverage data for C++ sources, after the tests
# were executed.
#
# Bazel C++ code coverage collection support is poor and limited. There is
# an ongoing effort to improve this (tracking issue #1118).
#
# Bazel uses the lcov tool for gathering coverage data. There is also
# an experimental support for clang llvm coverage, which uses the .profraw
# data files to compute the coverage report.
#
# This script assumes the following environment variables are set:
# - COVERAGE_DIR            Directory containing metadata files needed for
#                           coverage collection (e.g. gcda files, profraw).
# - COVERAGE_MANIFEST       Location of the instrumented file manifest.
# - LLVM_PROFDATA           Location of llvm-profdata. This is set by the TestRunner.
# - ROOT                    Location from where the code coverage collection
#                           was invoked.
# - VERBOSE_COVERAGE        Print debug info from the coverage scripts
#
# The script looks in $COVERAGE_DIR for the C++ metadata coverage files (either
# gcda or profraw) and uses either lcov or gcov to get the coverage data.
# The coverage data is placed in $COVERAGE_OUTPUT_FILE.

# set -x
env

find "${RUNFILES_DIR}" -iname '*.elf'

if [[ -n "$VERBOSE_COVERAGE" ]]; then
  set -x
fi

# Computes code coverage data using the clang generated metadata found under
# $COVERAGE_DIR.
# Writes the collected coverage into the given output file.
function llvm_coverage_lcov() {
  local output_file="${1}"; shift
  export LLVM_PROFILE_FILE="${COVERAGE_DIR}/%h-%p-%m.profraw"
  "${LLVM_PROFDATA}" merge -output "${output_file}.data" \
      "${COVERAGE_DIR}"/*.profraw

  # cat "${COVERAGE_MANIFEST}"
  local object_param=""
  while read -r line; do
    if [[ ${line: -24} == "runtime_objects_list.txt" ]]; then
      while read -r line_runtime_object; do
        if [[ -e "${RUNFILES_DIR}/${TEST_WORKSPACE}/${line_runtime_object}" ]]; then
          object_param+=" -object ${RUNFILES_DIR}/${TEST_WORKSPACE}/${line_runtime_object}"
        fi
      done < "${line}"
    fi
    if [[ ${line: -5} == ".gcno" ]]; then
      gcno_path=${line}
      local obj="$(dirname ${gcno_path})/$(basename ${gcno_path} .gcno).o"
      if [[ -f "${obj}" ]]; then
        object_param+=" -object ${obj}"
      fi
    fi
  done < "${COVERAGE_MANIFEST}"

  "${LLVM_COV}" export -instr-profile "${output_file}.data" -format=lcov \
      -ignore-filename-regex='^/tmp/.+' \
      ${object_param} | sed 's#/proc/self/cwd/##' > "${output_file}"
}

function llvm_coverage_profdata() {
  local output_file="${1}"; shift
  export LLVM_PROFILE_FILE="${COVERAGE_DIR}/%h-%p-%m.profraw"
  "${LLVM_PROFDATA}" merge -output "${output_file}" \
      "${COVERAGE_DIR}"/*.profraw
}

function main() {
  # If llvm code coverage is used, we output the raw code coverage report in
  # the $COVERAGE_OUTPUT_FILE. This report will not be converted to any other
  # format by LcovMerger.
  # TODO(#5881): Convert profdata reports to lcov.
  if [[ "${GENERATE_LLVM_LCOV}" == "1" ]]; then
      BAZEL_CC_COVERAGE_TOOL="LLVM_LCOV"
  else
      BAZEL_CC_COVERAGE_TOOL="PROFDATA"
  fi

  # When using either gcov or lcov, have an output file specific to the test
  # and format used. For lcov we generate a ".dat" output file and for gcov
  # a ".gcov" output file. It is important that these files are generated under
  # COVERAGE_DIR.
  # When this script is invoked by tools/test/collect_coverage.sh either of
  # these two coverage reports will be picked up by LcovMerger and their
  # content will be converted and/or merged with other reports to an lcov
  # format, generating the final code coverage report.
  case "$BAZEL_CC_COVERAGE_TOOL" in
        ("PROFDATA") llvm_coverage_profdata "$COVERAGE_DIR/_cc_coverage.profdata" ;;
        ("LLVM_LCOV") llvm_coverage_lcov "$COVERAGE_DIR/_cc_coverage.dat" ;;
        (*) echo "Coverage tool $BAZEL_CC_COVERAGE_TOOL not supported" \
            && exit 1
  esac
}

main
