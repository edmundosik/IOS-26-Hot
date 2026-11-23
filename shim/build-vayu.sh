#!/bin/bash
# Build the Poco X3 Pro (vayu) bare-metal shim as a boot image for `fastboot boot`.
#
#   shim/build-vayu.sh [PAYLOAD] [OUT]
#
# Writes no partition: the result is only for `fastboot boot` (RAM). It needs
# stock/vayu-dtb, the dtb section of vayu's own stock boot.img (keep it out of
# git, as every file under stock/).
#
# Without PAYLOAD it is the zero-write probe (SHIM_READONLY): it reads the
# hardware and the userdata GPT, shows its log on the panel for 25 s, then
# resets to fastboot. Built with ALLOW_UFS_WRITE=1, the shim may also write its
# log to the last 1153 4K blocks of userdata (nothing outside userdata).
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
DTB=${VAYU_DTB:-$ROOT/stock/vayu-dtb}
[ -s "$DTB" ] || { echo "error: $DTB missing (dtb section of vayu's stock boot.img)" >&2; exit 1; }

EXTRA_FLAGS="-DBOARD_VAYU ${SHIM_CFLAGS:-}"
if [ -z "${ALLOW_UFS_WRITE:-}" ]; then
	EXTRA_FLAGS="$EXTRA_FLAGS -DSHIM_READONLY"
fi

CC="clang --target=aarch64-none-elf"
CFLAGS="-O2 -ffreestanding -nostdlib -fno-builtin -fno-pic -fno-pie -mgeneral-regs-only -mstrict-align
	-fno-stack-protector -fno-asynchronous-unwind-tables -Wall -Wextra $EXTRA_FLAGS"
SRCS="start.S shim.c console.c log.c util.c mmu.c fdt.c loader.c ufs.c spmi.c sde.c showlog.c diag.c disptest.c stridetest.c gpuprobe.c gpufw.S smmuprobe.c ramlog.c"

O=out/vayu
mkdir -p $O
objs=
for f in $SRCS; do
	$CC $CFLAGS -c "$f" -o "$O/${f%.*}.o"
	objs="$objs $O/${f%.*}.o"
done
abs=$(llvm-readelf -r $(echo "$objs" | sed "s| $O/start.o||") | grep -c R_AARCH64_ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
ld.lld -static -nostdlib -T shim.ld --build-id=none -N $objs -o $O/shim.elf
llvm-objcopy -O binary $O/shim.elf $O/Image
size=$(llvm-nm $O/shim.elf | awk '$3=="_end"{print $1}')
truncate -s $((16#$size)) $O/Image

if [ -n "${1:-}" ]; then
	cp "$1" $O/ramdisk.bin
else
	# empty newc cpio (just the trailer), gzipped: ABL wants a ramdisk
	python3 -c 'import gzip,sys;t=b"TRAILER!!!\0";h=b"070701"+b"".join(b"%08X"%v for v in (0,0,0,0,1,0,0,0,0,0,0,len(t),0));e=h+t;e+=b"\0"*(-len(e)%4);e+=b"\0"*(-len(e)%512);sys.stdout.buffer.write(gzip.compress(e,9,mtime=0))' > $O/ramdisk.bin
fi

OUT=${2:-$O/shim-vayu-probe.img}
python3 "$ROOT/tools/mkbootimg_vayu.py" --kernel $O/Image --ramdisk $O/ramdisk.bin --dtb "$DTB" \
	--cmdline "androidboot.boot_devices=soc/1d84000.ufshc androidboot.hardware=qcom androidboot.usbcontroller=a600000.dwc3 lpm_levels.sleep_disabled=1" \
	-o "$OUT"
ls -l $O/Image "$OUT"
