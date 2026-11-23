#!/usr/bin/env python3
"""Light-weight dyld shared cache symbolizer (stdlib only, seeks, little RAM).

  dsc-peek.py CACHE_DIR SLIDE ADDR[:N] [ADDR[:N] ...] [--macho FILE:ADDR[:N] ...]
              [--list DYLIB:SUBSTR ...] [--dump DYLIB:SYMBOL:N ...]

For each slid ADDR: subcache file, image (dylib path), nearest symbol
(.symbols local symbols plus the image's own LC_SYMTAB) and, with :N, the N
instruction words before and after it as hex (disassemble elsewhere, e.g.
llvm-mc). --macho does the same for a standalone Mach-O (unslid ADDR),
resolving __stubs targets to their imported symbol names.
--list prints the symbols of DYLIB (base name) whose name contains SUBSTR;
--dump prints N words from the start of SYMBOL (exact name, SLIDE ignored)
with every bl target named.
For machines where `ipsw dyld` runs out of memory (WSL).
"""
import bisect
import os
import struct
import sys


def u32(b, o):
    return struct.unpack_from('<I', b, o)[0]


def u64(b, o):
    return struct.unpack_from('<Q', b, o)[0]


class Cache:
    def __init__(self, d):
        self.d = d
        self.maps = []		# (addr, size, fileoff, path)
        main = None
        for fn in sorted(os.listdir(d)):
            if not fn.startswith('dyld_shared_cache_') or fn.endswith(('.symbols', '.atlas', '.map')):
                continue
            p = os.path.join(d, fn)
            with open(p, 'rb') as f:
                h = f.read(0x200)
            if not h.startswith(b'dyld_v1'):
                continue
            mo, mc = u32(h, 16), u32(h, 20)
            with open(p, 'rb') as f:
                f.seek(mo)
                mb = f.read(32 * mc)
            for i in range(mc):
                a, s, fo = struct.unpack_from('<QQQ', mb, 32 * i)
                self.maps.append((a, s, fo, p))
            if '.' not in fn[len('dyld_shared_cache_'):]:
                main = p
        self.maps.sort()
        self.starts = [m[0] for m in self.maps]
        with open(main, 'rb') as f:
            h = f.read(0x200)
            self.base = u64(h, 224)
            io_, ic = u32(h, 448), u32(h, 452)
            f.seek(io_)
            ib = f.read(32 * ic)
            self.images = []
            for i in range(ic):
                a, _, _, po = struct.unpack_from('<QQQI', ib, 32 * i)
                f.seek(po)
                self.images.append((a, f.read(256).split(b'\0')[0].decode()))
        self.images.sort()
        self.img_starts = [a for a, _ in self.images]
        self.syms = {}
        self.symfile = os.path.join(d, os.path.basename(main) + '.symbols')

    def read(self, addr, n):
        i = bisect.bisect_right(self.starts, addr) - 1
        if i < 0:
            return None
        a, s, fo, p = self.maps[i]
        if addr + n > a + s:
            return None
        with open(p, 'rb') as f:
            f.seek(fo + addr - a)
            return f.read(n)

    def image_of(self, addr):
        i = bisect.bisect_right(self.img_starts, addr) - 1
        return self.images[i] if i >= 0 else (None, '?')

    def segments(self, mh):
        hdr = self.read(mh, 32)
        ncmds, size = u32(hdr, 16), u32(hdr, 20)
        lc = self.read(mh + 32, size)
        segs, symtab, o = [], None, 0
        for _ in range(ncmds):
            cmd, cs = u32(lc, o), u32(lc, o + 4)
            if cmd == 0x19:
                name = lc[o + 8:o + 24].split(b'\0')[0].decode()
                segs.append((name, u64(lc, o + 24), u64(lc, o + 32), u64(lc, o + 40)))
            elif cmd == 0x2:
                symtab = struct.unpack_from('<4I', lc, o + 8)
            o += cs
        return segs, symtab

    def symbols(self, mh):
        if mh in self.syms:
            return self.syms[mh]
        out = []
        segs, symtab = self.segments(mh)
        le = next((s for s in segs if s[0] == '__LINKEDIT'), None)
        if symtab and le:
            symoff, nsyms, stroff, strsize = symtab
            nl = self.read(le[1] + symoff - le[3], 16 * nsyms) or b''
            st = self.read(le[1] + stroff - le[3], strsize) or b''
            for i in range(len(nl) // 16):
                strx, typ, sect, _, val = struct.unpack_from('<IBBHQ', nl, 16 * i)
                if sect and val and not typ & 0xe0:
                    out.append((val, st[strx:st.find(b'\0', strx)].decode(errors='replace')))
        if os.path.exists(self.symfile):
            with open(self.symfile, 'rb') as f:
                h = f.read(0x200)
                lso = u64(h, 72)
                f.seek(lso)
                info = f.read(24)
                nlo, nlc, so, ss, eo, ec = struct.unpack('<6I', info)
                f.seek(lso + eo)
                ents = f.read(16 * ec)
                want = mh - self.base
                for i in range(ec):
                    doff, start, cnt = struct.unpack_from('<QII', ents, 16 * i)
                    if doff == want:
                        f.seek(lso + nlo + 16 * start)
                        nl = f.read(16 * cnt)
                        for j in range(cnt):
                            strx, typ, sect, _, val = struct.unpack_from('<IBBHQ', nl, 16 * j)
                            if sect and val and not typ & 0xe0:
                                f.seek(lso + so + strx)
                                out.append((val, f.read(200).split(b'\0')[0].decode(errors='replace')))
                        break
        out.sort()
        self.syms[mh] = out
        return out

    def sym(self, addr):
        mh, path = self.image_of(addr)
        if mh is None:
            return '?'
        syms = self.symbols(mh)
        i = bisect.bisect_right([v for v, _ in syms], addr) - 1
        name = f'{syms[i][1]}+0x{addr - syms[i][0]:x}' if i >= 0 else f'mh+0x{addr - mh:x}'
        return f'{os.path.basename(path)}`{name}'


def words(b, base):
    return ' '.join(f'{base + 4 * i:x}:{u32(b, 4 * i):08x}' for i in range(len(b) // 4))


def macho_peek(spec):
    path, rest = spec.split(':', 1)
    addr, n = (rest.split(':') + ['8'])[:2]
    addr, n = int(addr, 16), int(n)
    b = open(path, 'rb').read()
    if u32(b, 0) in (0xbebafeca, 0xcafebabe):	# fat: first arm64 slice
        nf = struct.unpack_from('>I', b, 4)[0]
        for i in range(nf):
            ct, _, off, size, _ = struct.unpack_from('>5I', b, 8 + 20 * i)
            if ct == 0x0100000c:
                b = b[off:off + size]
                break
    ncmds = u32(b, 16)
    o, segs, sects, symtab, dysym = 32, [], [], None, None
    for _ in range(ncmds):
        cmd, cs = u32(b, o), u32(b, o + 4)
        if cmd == 0x19:
            segs.append((u64(b, o + 24), u64(b, o + 32), u64(b, o + 40)))
            for k in range(u32(b, o + 64)):
                so = o + 72 + 80 * k
                sects.append((b[so:so + 16].split(b'\0')[0].decode(), u64(b, so + 32), u64(b, so + 40),
                              u32(b, so + 48), u32(b, so + 68), u32(b, so + 72)))
        elif cmd == 0x2:
            symtab = struct.unpack_from('<4I', b, o + 8)
        elif cmd == 0xb:
            dysym = struct.unpack_from('<18I', b, o + 8)
        o += cs

    def foff(a):
        for va, vs, fo in segs:
            if va <= a < va + vs:
                return fo + a - va
    stubs = {}
    if symtab and dysym:
        symoff, nsyms, stroff, _ = symtab
        indoff = dysym[12]
        for name, sa, ss, _, r1, r2 in sects:
            if name in ('__stubs', '__auth_stubs') and r2:
                for k in range(ss // r2):
                    idx = u32(b, indoff + 4 * (r1 + k))
                    if idx < nsyms:
                        strx = u32(b, symoff + 16 * idx)
                        stubs[sa + k * r2] = b[stroff + strx:b.find(b'\0', stroff + strx)].decode()
    fo = foff(addr - 4 * n)
    blob = b[fo:fo + 8 * n]
    print(f'== {os.path.basename(path)} around 0x{addr:x}')
    print(words(blob[:8 * n], addr - 4 * n))
    for i in range(0, len(blob[:8 * n]), 4):
        w, pc = u32(blob, i), addr - 4 * n + i
        if w >> 26 == 0x25:	# bl
            imm = w & 0x3ffffff
            t = pc + ((imm - (1 << 26) if imm & (1 << 25) else imm) << 2)
            print(f'  bl at 0x{pc:x} -> 0x{t:x} {stubs.get(t, "")}')


def image_mh(c, name):
    for a, p in c.images:
        if os.path.basename(p) == name:
            return a
    sys.exit(f'{name}: not in the cache')


def list_syms(c, spec):
    lib, sub = spec.split(':', 1)
    mh = image_mh(c, lib)
    hits = [(v, n) for v, n in c.symbols(mh) if sub in n]
    print(f'== {lib} symbols containing {sub!r}: {len(hits)}')
    for v, n in hits[:60]:
        print(f'  0x{v:x} {n}')


def dump_sym(c, spec):
    lib, name, n = spec.rsplit(':', 2)
    mh = image_mh(c, lib)
    syms = c.symbols(mh)
    hit = [v for v, s in syms if s in (name, '_' + name)]
    if not hit:
        print(f'== {name}: not found in {lib}')
        return
    a, n = hit[0], int(n)
    b = c.read(a, 4 * n) or b''
    print(f'== {lib}`{name} at 0x{a:x}')
    for i in range(0, len(b), 32):
        print('  ' + words(b[i:i + 32], a + i))
    for i in range(0, len(b), 4):
        w = u32(b, i)
        if w >> 26 in (0x25, 0x5):	# bl / b
            imm = w & 0x3ffffff
            t = a + i + ((imm - (1 << 26) if imm & (1 << 25) else imm) << 2)
            print(f'  {"bl" if w >> 31 else "b "} at 0x{a + i:x} -> 0x{t:x} {c.sym(t)}')


def main():
    args = sys.argv[1:]
    opts = {'--macho': [], '--list': [], '--dump': []}
    for k in opts:
        while k in args:
            i = args.index(k)
            opts[k].append(args[i + 1])
            del args[i:i + 2]
    machos = opts['--macho']
    if len(args) < 2:
        sys.exit(__doc__)
    c = Cache(args[0])
    slide = int(args[1], 16)
    for spec in args[2:]:
        a, n = (spec.split(':') + ['0'])[:2]
        a, n = int(a, 16), int(n)
        un = a - slide
        print(f'0x{a:x} (0x{un:x})  {c.sym(un)}')
        if n:
            b = c.read(un - 4 * n, 8 * n)
            if b:
                print('  ' + words(b, un - 4 * n))
    for m in machos:
        macho_peek(m)
    for m in opts['--list']:
        list_syms(c, m)
    for m in opts['--dump']:
        dump_sym(c, m)


if __name__ == '__main__':
    main()
