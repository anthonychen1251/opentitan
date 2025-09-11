#!/usr/bin/env python3

import argparse
import re

from coverage_helper import parse_lcov, normalize_genfiles

path = './bazel-out/_coverage/view/all_views.dat'

IGNORE = [
  "sw/device/lib/coverage/",
  "sw/otbn/crypto/run_p256.s",
  "sw/otbn/crypto/tests/",
]

def main():
  parser = argparse.ArgumentParser(description='List coverage ratio of each file in csv format.')
  parser.add_argument('--path', type=str, default=path, help='Path to the coverage file.')
  args = parser.parse_args()

  with open(args.path) as f:
    coverage = parse_lcov(f.read().splitlines())
    coverage = normalize_genfiles(coverage)

  for sf, cov in sorted(coverage.items()):
    if any(sf.startswith('SF:' + e) for e in IGNORE):
      continue

    fn_hit = sum(1 for count in cov.fnda.values() if count > 0)
    fn_rate = (fn_hit / len(cov.fnda)) if len(cov.fnda) else 1.0

    line_hit = sum(1 for count in cov.da.values() if count > 0)
    line_miss = len(cov.da) - line_hit if len(cov.da) else 0
    line_rate = (line_hit / len(cov.da)) if len(cov.da) else 1.0

    sf = sf.removeprefix('SF:')

    if sf.startswith('bazel-out'):
      name = re.sub(r'bazel-out/[^/]*/bin/', '', sf)
      name = 'generated://' + name + '.gcov.html'
    else:
      name = '//' + sf + '.gcov.html'
    print(f'{name},{line_miss},{line_rate*100:.2f},{fn_rate*100:.2f}')

if __name__ == '__main__':
  main()
