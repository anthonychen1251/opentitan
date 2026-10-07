#!/usr/bin/env bash

# Ensure both input and output files are provided
if [ $# -lt 2 ]; then
  echo "Error: Missing file arguments."
  echo "Usage: $0 <input_targets_file> <output_results_file>"
  exit 1
fi

TARGETS_FILE="$1"
RESULTS_FILE="$2"

# Verify the input targets file actually exists
if [ ! -f "$TARGETS_FILE" ]; then
  echo "Error: Input file '$TARGETS_FILE' does not exist."
  exit 1
fi

# Clear the output file before starting
> "$RESULTS_FILE"

# Read the input targets file line by line
while IFS= read -r target || [ -n "$target" ]; do
  target="${target%$'\r'}"
  [[ -z "$target" || "$target" =~ ^# ]] && continue

  echo "Running test: $target"
  ./bazelisk.sh test --nocache_test_results --curses=no --color=no --experimental_ui_max_stdouterr_bytes=0 "$target" >> "$RESULTS_FILE"
done < "$TARGETS_FILE"

echo "All tests finished! Results saved in $RESULTS_FILE"
