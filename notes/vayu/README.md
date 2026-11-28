# vayu laptop archive (2026-11-28)

Small files saved from the laptop's `platform-tools` folder before it was cleaned
(phone died: EDL / SoC solder failure). Binaries (test images, kernels, overlays)
are not kept here; rebuild them with `test-image-kit.txt`.

- `test-image-kit.txt`, `cmd82.txt`: how test images were built, boot-args.
- `partition-backup-SHA256SUMS.txt`: hashes of the stock partition backup
  (persist, modemst1/2, fsg, ...). The images themselves are device-unique and
  not in git.
- `dumps/`: dsc-peek symbol queries (`symNN.txt`) with outputs (`symNN-out.txt`)
  and other one-off dumps from debugging.
- Scripts: `tools/getlog.ps1` (pull kernel log via OrangeFox), `tools/run-test.ps1`,
  `tools/wrd.py` (decode texture dumps from a log), `tools/dsc-peek.py`.
