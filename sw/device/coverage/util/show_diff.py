import subprocess
import re

base_commit = '2808debba8'

with open('./bazel-out/_coverage/view/all_views.dat') as f:
  files = re.findall(r'SF:(.*)\n', f.read())

if 'sw/device/coverage/asm_counters.c' in files:
  files.remove('sw/device/coverage/asm_counters.c')

subprocess.run([
  'git', 'diff', base_commit, '--', *files
])
