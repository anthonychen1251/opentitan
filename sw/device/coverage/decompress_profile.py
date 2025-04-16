import struct
import sys

prof = sys.argv[1]

BUILD_ID_SIZE = 20

def read_exact(f, size):
    res = f.read(size)
    if len(res) != size:
        raise EOFError()
    return res

cnts = []
with open(prof, 'rb') as f:
    build_id = read_exact(f, BUILD_ID_SIZE)
    assert len(build_id) != 0
    assert len(build_id) == BUILD_ID_SIZE

    while True:
        char = read_exact(f, 1)
        if char == b'':
            break
        elif char == b'\0':
            pad = int.from_bytes(read_exact(f, 1), 'little')
            if pad == 0xfe:
                pad = int.from_bytes(read_exact(f, 2), 'little')
            elif pad == 0xff:
                pad = int.from_bytes(read_exact(f, 4), 'little')
            cnts.append(b'\0' * pad)
        else:
            cnts.append(char)
cnts = b''.join(cnts)
