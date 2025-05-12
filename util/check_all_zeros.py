#!/usr/bin/env python3
# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import sys

with open(sys.argv[1], 'rb') as f:
    data = f.read()

# Remove gap fill
data = data.rstrip(b'\xa5')

# Tests the section are either all 0x00 or all 0xff.
assert data.strip(b'\0') == b'' or data.strip(b'\xff') == b'', data
