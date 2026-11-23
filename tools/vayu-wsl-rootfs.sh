#!/bin/bash
# Build the iOS 26.5.2 (23F84) HFSX root for vayu on Windows WSL2 Debian.
#
#   tools/vayu-wsl-rootfs.sh setup HFSPLUS.ko   install tools, load the HFS+ module
#   tools/vayu-wsl-rootfs.sh build [WORKDIR]    download 3 DMGs, build the root image
#
# Nothing here touches the phone. The result is WORKDIR/ios26-root-vayu.img
# (default WORKDIR ~/vayu-root), which you flash yourself to userdata only.
#
# Why setup is needed: the stock WSL2 kernel has no hfsplus module and Debian
# no longer ships hfsprogs or apfs-fuse. HFSPLUS.ko is built for the exact WSL
# kernel (linux-msft-wsl-6.18.58.1); hfsprogs comes from Ubuntu 24.04 (its
# libc/libssl deps match Debian 13); apfs-fuse is built from source; ipsw
# (blacktop) decrypts the .dmg.aea images with Apple's published keys.
# insmod does not survive `wsl --shutdown`: re-run setup after a restart.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEVICE=iPhone12,3 BUILD=23F84 SIZE=28G
HFSPROGS_DEB=hfsprogs_540.1.linux3-5build3_amd64.deb

setup() {
	local ko=${1:?usage: setup HFSPLUS.ko}
	sudo apt-get update
	sudo apt-get install -y git cmake g++ pkg-config libfuse3-dev fuse3 zlib1g-dev \
		libbz2-dev libattr1-dev rsync python3 curl unzip kmod
	if ! command -v mkfs.hfsplus >/dev/null; then
		curl -fL -o "/tmp/$HFSPROGS_DEB" "http://archive.ubuntu.com/ubuntu/pool/universe/h/hfsprogs/$HFSPROGS_DEB"
		sudo apt-get install -y "/tmp/$HFSPROGS_DEB"
	fi
	if ! command -v apfs-fuse >/dev/null; then
		rm -rf "$HOME/src/apfs-fuse"
		git clone --recursive https://github.com/sgan81/apfs-fuse "$HOME/src/apfs-fuse"
		cmake -S "$HOME/src/apfs-fuse" -B "$HOME/src/apfs-fuse/build" -DUSE_FUSE3=ON
		make -C "$HOME/src/apfs-fuse/build" -j"$(nproc)"
		sudo install -m 0755 "$HOME/src/apfs-fuse/build/apfs-fuse" /usr/local/bin/
	fi
	if ! command -v ipsw >/dev/null; then
		# The plain CLI tarball (the ipswd .deb is a systemd daemon: not wanted).
		local tgz
		tgz=$(curl -fsL https://api.github.com/repos/blacktop/ipsw/releases/latest |
			python3 -c 'import json,re,sys; print(next(a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if re.fullmatch(r"ipsw_[0-9.]+_linux_x86_64\.tar\.gz", a["name"])))')
		mkdir -p /tmp/ipsw-cli
		curl -fL "$tgz" | tar -xz -C /tmp/ipsw-cli
		sudo install -m 0755 "$(find /tmp/ipsw-cli -type f -name ipsw | head -1)" /usr/local/bin/ipsw
	fi
	if ! grep -qw hfsplus /proc/filesystems; then
		local want got
		want=$(uname -r)
		got=$(/sbin/modinfo -F vermagic "$ko" | cut -d' ' -f1)
		[[ $got == "$want" ]] || { echo "error: $ko is for $got, this kernel is $want" >&2; exit 1; }
		sudo /sbin/insmod "$ko"
	fi
	grep -qw hfsplus /proc/filesystems && echo "HFS+ module loaded"
	for t in mkfs.hfsplus fsck.hfsplus apfs-fuse ipsw rsync; do
		printf '%-14s %s\n' "$t" "$(command -v "$t" || echo MISSING)"
	done
}

build() {
	local work=${1:-$HOME/vayu-root}
	local out=$work/ios26-root-vayu.img
	grep -qw hfsplus /proc/filesystems || { echo "error: run setup first (no hfsplus module)" >&2; exit 1; }
	[[ ! -e $out ]] || { echo "error: $out exists" >&2; exit 1; }
	mkdir -p "$work/ipsw"
	local url
	url=$(curl -fsL "https://api.ipsw.me/v4/ipsw/$DEVICE/$BUILD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')
	echo "IPSW: $url"

	# Fetch BuildManifest, pick the OS + two cryptex images, check free space, fetch them.
	readarray -t dmgs < <(python3 - "$ROOT/tools" "$url" "$work/ipsw" <<'PY'
import os, plistlib, shutil, sys
sys.path.insert(0, sys.argv[1])
out = sys.stdout
sys.stdout = sys.stderr	# remotezip progress must not land in the path list
import remotezip as rz
url, outdir = sys.argv[2], sys.argv[3]
entries = {e[0]: e for e in rz.central_dir(url)}
rz.extract(url, entries['BuildManifest.plist'], outdir)
bm = plistlib.load(open(os.path.join(outdir, 'BuildManifest.plist'), 'rb'))
m = bm['BuildIdentities'][0]['Manifest']
paths = [m[k]['Info']['Path'] for k in ('OS', 'Cryptex1,SystemOS', 'Cryptex1,AppOS')]
need = sum(entries[p][3] for p in paths if not os.path.exists(os.path.join(outdir, p)))
free = shutil.disk_usage(outdir).free
# WSL's virtual disk reports ~1 TB; the real limit is free space on C:.
if os.path.isdir('/mnt/c'):
    free = min(free, shutil.disk_usage('/mnt/c').free)
print(f'DMGs to download: {need / 2**30:.1f} GiB, free: {free / 2**30:.1f} GiB', file=sys.stderr)
# DMGs + the root image (about the size of the uncompressed files) at once.
if free < need * 2.6:
    sys.exit(f'error: need roughly {need * 2.6 / 2**30:.0f} GiB free')
for p in paths:
    rz.extract(url, entries[p], outdir)
    print(os.path.join(outdir, p), file=out, flush=True)
PY
)
	[[ ${#dmgs[@]} == 3 ]] || { echo "error: DMG download failed" >&2; exit 1; }

	# Decrypt now and drop each .aea at once, so both copies never sit on disk together.
	local i
	for i in 0 1 2; do
		if [[ ${dmgs[$i]} == *.aea ]]; then
			ipsw fw aea "${dmgs[$i]}" -o "$(dirname "${dmgs[$i]}")"
			[[ -f ${dmgs[$i]%.aea} ]] || { echo "error: decrypt failed for ${dmgs[$i]}" >&2; exit 1; }
			rm -f "${dmgs[$i]}"
			dmgs[$i]=${dmgs[$i]%.aea}
		fi
	done

	bash "$ROOT/tools/mkiosroot.sh" "${dmgs[0]}" "${dmgs[1]}" "${dmgs[2]}" "$out" "$SIZE"
	rm -f "${dmgs[@]}"

	# Same bring-up tweaks as the RMX1931 root (no device firmware staged yet).
	local mnt
	mnt=$(mktemp -d)
	fsck.hfsplus -fy "$out" >/dev/null || true
	sudo mount -t hfsplus -o loop,force "$out" "$mnt"
	sudo python3 "$ROOT/tools/sweet-root-tweaks.py" "$mnt"
	df -h "$mnt"
	sudo umount "$mnt"
	rmdir "$mnt"
	fsck.hfsplus -f -n "$out"
	ls -ls "$out"
	echo "done: $out (flash it to userdata only, after review)"
}

case ${1:-} in
setup) shift; setup "$@" ;;
build) shift; build "$@" ;;
*) sed -n '2,16p' "$0"; exit 2 ;;
esac
