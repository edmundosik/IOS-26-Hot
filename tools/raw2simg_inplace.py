#!/usr/bin/env python3
"""Convert a raw disk image to an Android sparse image (what `fastboot flash`
streams in pieces), freeing the raw file's space as it goes.

  raw2simg_inplace.py RAW.img OUT.simg [--keep]

Without --keep, each 64 MiB window of RAW is punched out (fallocate
PUNCH_HOLE) once its data is safely in OUT, so peak extra disk use is one
window instead of a second full copy. RAW keeps its size but ends up all
holes: delete it afterwards. simg2img OUT.simg RAW.img restores it.
Zero 4K blocks and holes become FILL chunks of zeros, never DONT_CARE:
fastboot leaves DONT_CARE blocks as they were on the phone (the old MIUI
userdata, encrypted junk), and zero blocks inside files (bss, sparse
databases) then read back as junk. FILL costs 16 bytes per run.
"""
import ctypes, os, struct, sys

BLK = 4096
WIN = 64 << 20
MAX_RAW = 16 << 20
RAW, FILL, DONT_CARE = 0xCAC1, 0xCAC2, 0xCAC3
ZERO = bytes(BLK)
libc = ctypes.CDLL(None, use_errno=True)
libc.fallocate.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_long, ctypes.c_long]


def punch(fd, off, length):
	if libc.fallocate(fd, 3, off, length) != 0:	# PUNCH_HOLE | KEEP_SIZE
		e = ctypes.get_errno()
		raise OSError(e, os.strerror(e))


def main():
	args = [a for a in sys.argv[1:] if a != '--keep']
	keep = '--keep' in sys.argv
	if len(args) != 2:
		sys.exit(__doc__)
	src, dst = args
	size = os.path.getsize(src)
	assert size % BLK == 0, 'size not a multiple of 4096'
	if os.path.exists(dst):
		sys.exit(f'refusing to overwrite {dst}')
	total_blks = size // BLK
	fd = os.open(src, os.O_RDWR if not keep else os.O_RDONLY)
	out = open(dst, 'wb')
	out.write(bytes(28))
	chunks = 0
	pending = []		# (kind, nblocks, data)

	def emit(kind, n, data=b''):
		nonlocal chunks
		out.write(struct.pack('<HHII', kind, 0, n, 12 + len(data)))
		out.write(data)
		chunks += 1

	# Merge consecutive runs: one chunk per run of data or zeros.
	run_kind, run_n, run_data = None, 0, []

	def flush_run():
		nonlocal run_kind, run_n, run_data
		if run_kind == RAW:
			emit(RAW, run_n, b''.join(run_data))
		elif run_kind == DONT_CARE:
			emit(FILL, run_n, bytes(4))	# zeros on the phone, not 'leave as is'
		run_kind, run_n, run_data = None, 0, []

	def add(kind, data=None):
		nonlocal run_kind, run_n
		if kind != run_kind or (kind == RAW and run_n * BLK >= MAX_RAW):
			flush_run()
			run_kind = kind
		run_n += 1
		if kind == RAW:
			run_data.append(data)

	pos = 0
	done_pct = -1
	while pos < size:
		try:
			data_at = os.lseek(fd, pos, os.SEEK_DATA)
		except OSError:
			data_at = size		# no more data
		data_at = min(data_at - data_at % BLK, size)
		if data_at > pos:
			for _ in range((data_at - pos) // BLK):
				add(DONT_CARE)
			pos = data_at
			continue
		end = min(pos + WIN, size)
		os.lseek(fd, pos, os.SEEK_SET)
		buf = os.read(fd, end - pos)
		assert len(buf) == end - pos
		for i in range(0, len(buf), BLK):
			b = buf[i:i + BLK]
			add(DONT_CARE if b == ZERO else RAW, b)
		if not keep:
			flush_run()
			out.flush()
			os.fsync(out.fileno())
			punch(fd, pos, end - pos)
		pos = end
		pct = pos * 100 // size
		if pct != done_pct:
			done_pct = pct
			print(f'{pct}% ({pos >> 30} GiB)', flush=True)
	flush_run()
	out.seek(0)
	out.write(struct.pack('<IHHHHIIII', 0xed26ff3a, 1, 0, 28, 12, BLK, total_blks, chunks, 0))
	out.close()
	os.close(fd)
	print(f'{dst}: {total_blks} blocks, {chunks} chunks, {os.path.getsize(dst)} bytes')


if __name__ == '__main__':
	main()
