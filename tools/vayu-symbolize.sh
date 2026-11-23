#!/bin/bash
# Symbolicate the vayu test13 crash and stack samples against the iOS 26
# shared cache that is actually on the phone (the de-PAC'd root image).
# Read-only on the image; writes only ~/vayu-dsc (about 5 GB, delete after).
#
#   bash tools/vayu-symbolize.sh [ROOT.simg] > ~/vayu-sym.txt
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SIMG=${1:-$HOME/vayu-root/ios26-root-vayu.simg}
OUT=${OUT:-$HOME/vayu-dsc}
SLIDE=0x1ef68000

if [ ! -s "$OUT/com.apple.dyld/dyld_shared_cache_arm64e" ]; then
	python3 "$ROOT/tools/hfs-extract.py" "$SIMG" "$OUT" \
		/System/Library/Caches/com.apple.dyld /Applications/Preferences.app/Preferences >&2 || exit 1
fi
DSC=$OUT/com.apple.dyld/dyld_shared_cache_arm64e

sym() {	# label, slid address
	printf '%-26s %s  ' "$1" "$2"
	ipsw dyld a2s "$DSC" "$2" --slide "$SLIDE" 2>&1 | tail -1
}
unslid() { printf '0x%x' $(( $1 - SLIDE )); }

echo "== Preferences crash (pc, lr, bt) =="
sym "crash pc" 0x1ab4c6c18
sym "crash lr" 0x1ab4c6c10
sym "crash bt1" 0x19f089c1c
echo
echo "== disassembly around crash pc (unslid $(unslid 0x1ab4c6c18)) =="
ipsw dyld disass "$DSC" --vaddr $(printf 0x%x $(( 0x1ab4c6c18 - SLIDE - 0x40 ))) --count 32 2>&1 | tail -34
echo
echo "== Preferences main binary around +0x39cc =="
ipsw macho disass "$OUT/Preferences" --vaddr 0x1000039a0 --count 16 2>&1 | tail -18
echo
echo "== stack samples at 104 s (busy threads) =="
for a in 0x1adf9782c 0x1adf97954 0x1dc8a89a8 0x1dc8c21e4 0x1dc8baa5c 0x1dc8bb098 \
	0x1dc8aa84c 0x1dc8aabb8 \
	0x1cca90094 0x1a2465770 0x1a2465834 0x1ea9a59ac 0x19f00a660 0x19f006358 0x19f0058a4 0x1c84d085c \
	0x2bbcc0c6c 0x2bbcc0cb8 0x2bbcc4f54 \
	0x1dc8c3984 0x1dc8c3d24 0x1b6e95edc 0x19f720714 0x19f70806c 0x19f708920 0x19f70884c 0x1c7b22e24 \
	0x1a247c310 0x1a247b54c 0x1a252bd64 0x1a3134a80 0x1a31432a0 0x242b0072c 0x247c03498 0x1a8174244; do
	sym "" $a
done
