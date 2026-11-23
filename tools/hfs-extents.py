#!/usr/bin/env python3
"""Print a file's HFS+ extents and find where a byte pattern really lives (read-only).

  hfs-extents.py IMAGE PATH [HEXQWORD ...]

Lists the data fork extents of PATH (hard links followed). For each HEXQWORD
(a little-endian u64 seen in memory, e.g. 468cf23b5840c062) it reports where
it occurs in the file itself and, if not there, scans the blocks right after
every extent end and the image as a whole, so a kernel read that went past
an extent (or into the wrong block) can be told apart from a runtime write.
"""
import importlib.util
import os
import struct
import sys

spec = importlib.util.spec_from_file_location(
    'hx', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'hfs-extract.py'))
hx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hx)
CHUNK = 32 << 20


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    idx = hx.Index(sys.argv[1])
    hfs, bs = idx.hfs, idx.hfs.block_size
    rtype, info = idx.lookup(sys.argv[2])
    cnid, (size, total, ext) = idx.resolve_file(info)
    if sum(b for _, b in ext) < total:
        ext = list(ext) + hfs._overflow_extents(cnid, 0, sum(b for _, b in ext))
    print(f'cnid {cnid} size 0x{size:x} block size {bs} blocks {total}')
    fo = 0
    for sb, bc in ext:
        print(f'  file 0x{fo:08x}-0x{fo + bc * bs:08x}  disk block {sb} (+{bc})  byte 0x{sb * bs:x}')
        fo += bc * bs
    pats = [struct.pack('<Q', int(p, 16)) for p in sys.argv[3:]]
    if not pats:
        return
    data = bytearray()
    for sb, bc in ext:
        hfs.f.seek(sb * bs)
        data += hfs.f.read(bc * bs)
    for p in pats:
        i = data.find(p)
        print(f'{p[::-1].hex()}: in file at {hex(i) if i >= 0 else "no"}')
        for sb, bc in ext:
            hfs.f.seek((sb + bc) * bs)
            j = hfs.f.read(8 * bs).find(p)
            if j >= 0:
                print(f'  just past extent at disk block {sb + bc} +0x{j:x}')
    print('scanning whole image (a few minutes)...', file=sys.stderr)
    pos, tail = 0, b''
    while True:
        hfs.f.seek(pos)
        buf = hfs.f.read(CHUNK)
        if not buf:
            break
        blob = tail + buf
        for p in pats:
            k = blob.find(p)
            if k >= 0 and k < len(tail) and pos and False:
                k = blob.find(p, k + 1)
            while k >= 0:
                a = pos - len(tail) + k
                print(f'{p[::-1].hex()}: image byte 0x{a:x} (block {a // bs} +0x{a % bs:x})')
                k = blob.find(p, k + 1)
        tail = buf[-7:]
        pos += len(buf)


if __name__ == '__main__':
    main()
