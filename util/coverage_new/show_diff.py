import subprocess
import re

base_commit = 'aae256c9'

with open('./bazel-out/_coverage/view/all_views.dat') as f:
  files = re.findall(r'SF:(.*)\n', f.read())

subprocess.run([
  'git', 'diff', base_commit, '--', *files
])
