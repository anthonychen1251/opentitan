import subprocess
import re

base_commit = '4da7fb18'

with open('./bazel-out/_coverage/baseline/all_baselines.dis.dat') as f:
  files = re.findall(r'SF:(.*)\n', f.read())

if 'sw/device/coverage/asm_counters.c' in files:
  files.remove('sw/device/coverage/asm_counters.c')

subprocess.run([
  'git', 'diff', base_commit, '--', *files
])
