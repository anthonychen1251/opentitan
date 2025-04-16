#!/usr/bin/env python3
# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import sys

with open(sys.argv[1], 'rb') as f:
    data = f.read()

assert data.strip(b'\0') == b''
