#!/usr/bin/env python3
"""Copy one file out of an HFS+/HFSX image (raw or Android sparse), read-only.

  hfs-cat.py IMAGE /path/in/volume OUT
"""
import importlib.util, os, sys

spec = importlib.util.spec_from_file_location(
    'overlay', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'make-ios26-overlay.py'))
overlay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(overlay)
if len(sys.argv) != 4:
    sys.exit(__doc__)
hfs = overlay.HFSReadOnly(sys.argv[1])
data = hfs.read_file(sys.argv[2])[0]
open(sys.argv[3], 'wb').write(data)
print(f'{sys.argv[3]}: {len(data)} bytes')
