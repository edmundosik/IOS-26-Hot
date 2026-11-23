#!/usr/bin/env python3
"""Rewrite an Android sparse image so skipped blocks are written as zeros.

  simg-zero-fill.py IN.simg OUT.simg [--zeros-only]

Every DONT_CARE chunk becomes a FILL chunk of zeros (same block count).
fastboot leaves DONT_CARE blocks untouched on the device, so an image made
by older raw2simg_inplace.py (zero blocks -> DONT_CARE) let the old
userdata contents show through wherever an iOS file had a zero 4 KiB block.
Streams the input; OUT is only slightly larger than IN.

--zeros-only writes a tiny image instead: only the zero FILL chunks, with
IN's data chunks turned into DONT_CARE. Flash IN and then OUT (to the same
partition) for the same result without a second full-size image on disk.
"""
import os
import struct
import sys

RAW, FILL, DONT_CARE, CRC = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4
COPY = 16 << 20


def main():
    zeros_only = '--zeros-only' in sys.argv
    args = [a for a in sys.argv[1:] if a != '--zeros-only']
    if len(args) != 2:
        sys.exit(__doc__)
    src, dst = args
    if os.path.exists(dst):
        sys.exit(f'refusing to overwrite {dst}')
    fi, fo = open(src, 'rb'), open(dst, 'wb')
    hdr = fi.read(28)
    magic, major, minor, fhs, chs, bs, total, nchunks, csum = struct.unpack('<IHHHHIIII', hdr)
    assert magic == 0xed26ff3a and fhs == 28 and chs == 12, 'not a sparse image'
    fo.write(hdr)
    changed = blocks = 0
    for i in range(nchunks):
        kind, _, n, tsz = struct.unpack('<HHII', fi.read(12))
        if kind == DONT_CARE:
            fo.write(struct.pack('<HHII', FILL, 0, n, 16) + bytes(4))
            changed += n
        elif zeros_only:
            fo.write(struct.pack('<HHII', DONT_CARE, 0, n, 12))
            fi.seek(tsz - 12, 1)
        else:
            fo.write(struct.pack('<HHII', kind, 0, n, tsz))
            left = tsz - 12
            while left:
                b = fi.read(min(COPY, left))
                assert b, 'truncated input'
                fo.write(b)
                left -= len(b)
        blocks += n
        if i % 2000 == 0:
            print(f'{i}/{nchunks} chunks', flush=True)
    assert blocks == total, f'chunks cover {blocks} blocks, header says {total}'
    fo.close()
    print(f'{dst}: {changed} of {total} blocks now written as zeros, {os.path.getsize(dst)} bytes')


if __name__ == '__main__':
    main()
