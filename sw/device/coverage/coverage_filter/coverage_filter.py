import re
import argparse
from collections import namedtuple


FileProfile = namedtuple('FileProfile', ['sf', 'fn', 'fnda', 'da'])

def parse_single_file(lines):
  path = lines.pop().strip()
  assert path.startswith('SF:'), path

  profile = FileProfile(
    sf=path,
    fn=set(),
    fnda={},
    da={},
  )

  while True:
    line = lines.pop().strip()
    tag, params, *_ = line.split(':', 1) + ['']
    if tag == 'FN':
      lineno, name = params.split(',')
      profile.fn.add((int(lineno), name))
    elif tag == 'FNDA':
      count, name = params.split(',')
      profile.fnda[name] = int(count)
    elif tag == 'BRDA':
      pass
      # raise NotImplementedError('BRDA is not supported yet')
    elif tag == 'DA':
      lineno, count, *_ = params.split(',')
      profile.da[lineno] = int(count)
    elif tag in {'LH', 'LF', 'BRH', 'BRF', 'FNH', 'FNF'}:
      # These are summary lines, we don't care.
      pass
    elif tag == 'end_of_record':
      break
    else:
      raise ValueError(f'Unexpected line: {line}')

  return profile

def parse_lcov(lines):
  lines = lines[::-1]
  files = {}
  while len(lines):
    profile = parse_single_file(lines)
    files[profile.sf] = profile
  return files

def strip_discarded(baseline):
  stripped = {}
  for sf, base in baseline.items():
    # Keep functions that can be hit
    fnda = {n: c for n, c in base.fnda.items() if c > 0}
    fn = {(l, n) for l, n in base.fn if n in fnda}

    # Keep lines that can be hit
    da = {l: c for l, c in base.da.items() if c > 0}

    if len(fnda) or len(da):
      stripped[sf] = FileProfile(
        sf=sf,
        fn=fn,
        fnda=fnda,
        da=da,
        )

  return stripped

def filter_coverage(baseline, coverage):
  keys = set(baseline.keys()) & set(coverage.keys())
  output = []
  for sf in keys:
    base, cov = baseline[sf], coverage[sf]
    output.append(sf + '\n')
    for lineno, name in base.fn:
      output.append(f'FN:{lineno},{name}\n')

    fnh = 0
    for name in base.fnda.keys():
      if name in cov.fnda:
        count = cov.fnda[name]
        if count > 0:
          fnh += 1
        output.append(f'FNDA:{count},{name}\n')
    output.append(f'FNH:{fnh}\n')
    output.append(f'FNF:{len(base.fnda)}\n')

    lh = 0
    for lineno in base.da.keys():
      if lineno in cov.da:
        count = cov.da[lineno]
        if count > 0:
          lh += 1
        output.append(f'DA:{lineno},{count}\n')
    output.append(f'LH:{lh}\n')
    output.append(f'LF:{len(base.da)}\n')

    output.append('end_of_record\n')
  return output

def main():
  parser = argparse.ArgumentParser(description='Filter related coverage based on a baseline.')
  parser.add_argument('--baseline', type=str, required=True, help='Path to the baseline coverage file.')
  parser.add_argument('--coverage', type=str, help='Path to the coverage file to filter.')
  parser.add_argument('--output', type=str, help='Path to the output file.')
  args = parser.parse_args()

  # Read the baseline coverage file
  with open(args.baseline, 'r') as f:
    baseline = parse_lcov(f.readlines())

  # Ignore parts that are discarded in the final firmware
  baseline = strip_discarded(baseline)

  # Read the coverage file to filter
  with open(args.coverage, 'r') as f:
    coverage = parse_lcov(f.readlines())

  # Filter the coverage
  filtered_coverage = filter_coverage(baseline, coverage)

  # # Write the filtered coverage to the output file
  with open(args.output, 'w') as f:
    f.writelines(filtered_coverage)


if __name__ == '__main__':
  main()

