#!/usr/bin/env python3
"""Check an HFS+ root's allocation bitmap against its catalog (read-only).

  hfs-alloc-check.py IMAGE [--bitmap PHONE_BITMAP.bin]

Every block of every file's data fork must be marked used in the volume
bitmap and belong to only one file. Blocks that are marked free get handed
out again by the allocator, and the new file's data then overwrites them.
--bitmap checks a copy of the allocation file read from the phone (the dd
command for that is printed) instead of the one in IMAGE.
"""
import importlib.util
import os
import struct
import sys

spec = importlib.util.spec_from_file_location(
    'hx', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'hfs-extract.py'))
hx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hx)


def overflow_map(hfs):
    out = {}
    node_num, ns = hfs.ext_first_leaf, hfs.ext_node_size
    while node_num:
        node = hfs._read_fork_bytes(hfs.extents_fork, node_num * ns, ns)
        flink, _, kind, _, num_recs = struct.unpack_from('>IIbbH', node, 0)
        for r in range(num_recs):
            rec_off, = struct.unpack_from('>H', node, ns - 2 * (r + 1))
            key_len, ftype, _, file_id, _ = struct.unpack_from('>HBBII', node, rec_off)
            if ftype:
                continue
            val_off = rec_off + 2 + key_len
            for i in range(8):
                sb, bc = struct.unpack_from('>II', node, val_off + i * 8)
                if bc:
                    out.setdefault(file_id, []).append((sb, bc))
        node_num = flink
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    image = sys.argv[1]
    phone = sys.argv[sys.argv.index('--bitmap') + 1] if '--bitmap' in sys.argv else None
    idx = hx.Index(image)
    hfs = idx.hfs
    hfs.f.seek(1024)
    vh = hfs.f.read(512)
    total, free = struct.unpack_from('>II', vh, 44)
    alloc = hfs._parse_fork(vh, 112)
    print(f'volume: {total} blocks of {hfs.block_size}, header says {free} free')
    print(f'allocation file: {alloc[0]} bytes, extents {alloc[2]}')
    for sb, bc in alloc[2]:
        print(f"  phone copy: ./adb shell 'd=$(readlink -f /dev/block/by-name/userdata); "
              f"dd if=$d of=/tmp/bitmap.bin bs={hfs.block_size} skip={sb} count={bc}'")
    bitmap = open(phone, 'rb').read() if phone else hfs._read_fork_bytes(alloc, 0, alloc[0])
    print(f'checking the {"phone" if phone else "image"} bitmap ({len(bitmap)} bytes)')
    for blk in (85239, 85240, 85241, 85242):
        print(f'  block {blk}: {"used" if bitmap[blk >> 3] & (0x80 >> (blk & 7)) else "FREE"}')
    ovf = overflow_map(hfs)
    owner = {}
    names = {}
    for pid, kids in idx.children.items():
        for name, (t, info) in kids.items():
            if t == 2:
                names[info[0]] = (pid, name)
    seen = bytearray(total)
    bad_free, bad_dup, used = {}, {}, 0
    for cnid, (pid, name) in names.items():
        info = idx.children[pid][name][1]
        _, _, _, (size, nblk, ext) = info
        if sum(b for _, b in ext) < nblk:
            ext = list(ext) + ovf.get(cnid, [])
        for sb, bc in ext:
            for blk in range(sb, min(sb + bc, total)):
                used += 1
                if not bitmap[blk >> 3] & (0x80 >> (blk & 7)):
                    bad_free[cnid] = bad_free.get(cnid, 0) + 1
                if seen[blk]:
                    bad_dup[cnid] = bad_dup.get(cnid, 0) + 1
                seen[blk] = 1
    marked = sum(bin(b).count('1') for b in bitmap[:(total + 7) // 8])
    print(f'file blocks {used}, bitmap marks {marked} used ({total - marked} free)')
    print(f'files with blocks marked FREE: {len(bad_free)} ({sum(bad_free.values())} blocks)')
    for cnid, n in sorted(bad_free.items(), key=lambda x: -x[1])[:25]:
        print(f'  {n:7d}  cnid {cnid} {names[cnid][1]!r} (parent {names[cnid][0]})')
    print(f'files sharing blocks with another file: {len(bad_dup)} ({sum(bad_dup.values())} blocks)')
    for cnid, n in sorted(bad_dup.items(), key=lambda x: -x[1])[:25]:
        print(f'  {n:7d}  cnid {cnid} {names[cnid][1]!r} (parent {names[cnid][0]})')


if __name__ == '__main__':
    main()
