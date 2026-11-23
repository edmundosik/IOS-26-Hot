#!/usr/bin/env python3
"""Copy files or whole directories out of an HFS+/HFSX root image (raw or Android sparse), read-only.

  hfs-extract.py IMAGE OUTDIR PATH [PATH ...]

Each PATH (a file or a directory, e.g. /System/Library/Caches/com.apple.dyld)
is written under OUTDIR by its base name; directories are copied one level
deep (regular files only). Unlike hfs-cat.py it follows HFS+ hard links
(the shared cache files are hard links on roots built by mkiosroot.sh),
streams large files instead of holding them in memory, and builds the
catalog index once, so a multi-GB dyld cache comes out in one pass.
Never writes to IMAGE.
"""
import importlib.util
import os
import struct
import sys

spec = importlib.util.spec_from_file_location(
    'overlay', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'make-ios26-overlay.py'))
overlay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(overlay)

PRIVATE_DIR = '\0\0\0\0HFS+ Private Data'
CHUNK = 8 << 20


class Index:
    def __init__(self, image):
        self.hfs = overlay.HFSReadOnly(image)
        hfs = self.hfs
        # The catalog file itself may spill into the extents overflow file (CNID 4).
        self.cat = (hfs.catalog_fork[0], hfs.catalog_fork[1],
                    list(hfs.catalog_fork[2]) + (hfs._overflow_extents(4, 0, sum(b for _, b in hfs.catalog_fork[2]))
                                                 if sum(b for _, b in hfs.catalog_fork[2]) < hfs.catalog_fork[1] else []))
        self.children = {}	# parent cnid -> {name: (type, info)}
        ns = hfs.cat_node_size
        node_num = hfs.cat_first_leaf
        n = 0
        while node_num:
            node = hfs._read_fork_bytes(self.cat, node_num * ns, ns)
            flink, _, kind, _, num_recs = struct.unpack_from('>IIbbH', node, 0)
            assert kind == -1, 'not a leaf node'
            for r in range(num_recs):
                rec_off, = struct.unpack_from('>H', node, ns - 2 * (r + 1))
                key_len, pid, nchars = struct.unpack_from('>HIH', node, rec_off)
                name = node[rec_off + 8:rec_off + 8 + nchars * 2].decode('utf-16-be', errors='replace')
                val_off = rec_off + 2 + key_len
                val_off += val_off & 1
                rtype, = struct.unpack_from('>h', node, val_off)
                if rtype == 1:
                    info = struct.unpack_from('>I', node, val_off + 8)[0]
                elif rtype == 2:
                    cnid, = struct.unpack_from('>I', node, val_off + 8)
                    special, fdtype = struct.unpack_from('>I4s', node, val_off + 44)
                    fork = hfs._parse_fork(node, val_off + 88)
                    info = (cnid, special, fdtype, fork)
                else:
                    continue
                self.children.setdefault(pid, {})[name] = (rtype, info)
            node_num = flink
            n += 1
            if n % 20000 == 0:
                print(f'  catalog: {n} leaf nodes', file=sys.stderr)
        self.private = self.children.get(2, {}).get(PRIVATE_DIR, (None, None))[1]

    def lookup(self, path):
        cnid, rec = 2, (1, 2)
        for part in [p for p in path.strip('/').split('/') if p]:
            if rec[0] != 1:
                raise NotADirectoryError(path)
            rec = self.children.get(rec[1], {}).get(part)
            if rec is None:
                raise FileNotFoundError(f'{path}: {part!r} not found')
        return rec

    def resolve_file(self, info):
        cnid, special, fdtype, fork = info
        if fdtype == b'hlnk' and self.private is not None:
            rec = self.children.get(self.private, {}).get(f'iNode{special}')
            if rec is None:
                raise FileNotFoundError(f'hard link target iNode{special} missing')
            return rec[1][0], rec[1][3]
        return cnid, fork

    def copy_file(self, info, out_path):
        cnid, fork = self.resolve_file(info)
        size, total_blocks, extents = fork
        if sum(b for _, b in extents) < total_blocks:
            extents = list(extents) + self.hfs._overflow_extents(cnid, 0, sum(b for _, b in extents))
        bs = self.hfs.block_size
        left = size
        with open(out_path, 'wb') as out:
            for sb, bc in extents:
                pos, ext_left = sb * bs, bc * bs
                while left > 0 and ext_left > 0:
                    take = min(CHUNK, left, ext_left)
                    self.hfs.f.seek(pos)
                    data = self.hfs.f.read(take)
                    if len(data) != take:
                        raise IOError(f'short read in {out_path}')
                    out.write(data)
                    pos += take
                    ext_left -= take
                    left -= take
        if left:
            raise IOError(f'{out_path}: {left} bytes missing')
        print(f'{out_path}: {size} bytes')


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    image, outdir, paths = sys.argv[1], sys.argv[2], sys.argv[3:]
    os.makedirs(outdir, exist_ok=True)
    idx = Index(image)
    for path in paths:
        rtype, info = idx.lookup(path)
        if rtype == 2:
            idx.copy_file(info, os.path.join(outdir, os.path.basename(path.rstrip('/'))))
            continue
        sub = os.path.join(outdir, os.path.basename(path.rstrip('/')))
        os.makedirs(sub, exist_ok=True)
        for name, (t, i) in sorted(idx.children.get(info, {}).items()):
            if t == 2:
                idx.copy_file(i, os.path.join(sub, name))


if __name__ == '__main__':
    main()
