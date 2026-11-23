#!/usr/bin/env python3
"""Pack an Android boot image v2 for Xiaomi Poco X3 Pro (vayu), for `fastboot boot` only.

Same layout as vayu's stock boot.img (MIUI V14.0.3.0.TJUMIXM, read 2026-11-23):
  header_version 2 (header_size 1660), page_size 4096, base 0,
  kernel_addr 0x8000 (uncompressed arm64 Image), ramdisk_addr 0x1000000,
  tags_addr 0x100, dtb section at dtb_addr 0x1f00000 (the stock DTB blob:
  ABL picks the entry matching msm-id 0x153 v2, dtb_idx 0), os_version 0x1a000175.
Output is never larger than the 128 MiB boot partition, but nothing here flashes it.
"""
import argparse, hashlib, struct, sys

PAGE = 4096
BOOT_PART = 128 << 20


def pad(b):
    return b + b"\0" * (-len(b) % PAGE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--ramdisk", required=True)
    ap.add_argument("--dtb", required=True, help="stock DTB blob (boot.img dtb section)")
    ap.add_argument("--cmdline", default="")
    ap.add_argument("-o", "--output", required=True)
    a = ap.parse_args()
    k, r, d = (open(p, "rb").read() for p in (a.kernel, a.ramdisk, a.dtb))
    if k[56:60] != b"ARMd":
        sys.exit("kernel is not an arm64 Image")
    if d[:4] != b"\xd0\x0d\xfe\xed":
        sys.exit("dtb is not a flattened device tree")
    c = a.cmdline.encode()
    if len(c) > 512 + 1024 - 1:
        sys.exit("cmdline too long")
    sha = hashlib.sha1()
    for blob in (k, r, b""):
        sha.update(blob)
        sha.update(struct.pack("<I", len(blob)))
    sha.update(struct.pack("<I", 0))  # recovery dtbo
    sha.update(d)
    sha.update(struct.pack("<I", len(d)))
    h = bytearray(PAGE)
    h[0:8] = b"ANDROID!"
    struct.pack_into("<10I", h, 8, len(k), 0x8000, len(r), 0x1000000, 0, 0, 0x100, PAGE, 2, 0x1A000175)
    h[64:64 + min(len(c), 512)] = c[:512]
    h[576:596] = sha.digest()
    h[608:608 + len(c[512:])] = c[512:]
    struct.pack_into("<IQI", h, 1632, 0, 0, 1660)
    struct.pack_into("<IQ", h, 1648, len(d), 0x1F00000)
    img = bytes(h) + pad(k) + pad(r) + pad(d)
    if len(img) > BOOT_PART:
        sys.exit(f"image is {len(img)} bytes, more than the 128 MiB boot partition")
    open(a.output, "wb").write(img)
    print(f"{a.output}: v2 boot image, {len(img)} bytes")


if __name__ == "__main__":
    main()
