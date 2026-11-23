#!/usr/bin/env python3
"""Small root overlay that stages only a Lock/Home Screen wallpaper.

  make-wallpaper-overlay.py OUT.tar [--png IMAGE.png] [--size 1125x2499]

For a root that already got the full overlay once (make-ios26-overlay.py; it
persists with rootrw=1) but was built without --wallpaper. Stages the same
files as make-ios26-overlay.py --wallpaper: Wallpaper bundle, SpringBoard
CPBitmaps, PaperBoard/SpringBoard wallpaper prefs, and the Autobahn feature
flag override in /private/var/preferences/FeatureFlags (the System domain file
is left alone), so SBWallpaperController draws the still image in-process
instead of waiting on PosterBoard. Without --png a built-in blue/violet
gradient is used. Pass the tar to mkpayload.py --overlay (or repack-adt).
"""
import argparse
import importlib.util
import os
import plistlib
import tarfile

spec = importlib.util.spec_from_file_location(
    'overlay', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'make-ios26-overlay.py'))
ov = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ov)
MOBILE = ov.MOBILE_UID


def gradient_rgb(w, h):
    """Diagonal deep blue -> violet -> warm pink gradient (pure stdlib)."""
    stops = [(0.0, (12, 24, 74)), (0.5, (88, 52, 160)), (1.0, (226, 110, 150))]

    def col(t):
        for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
            if t <= t1:
                f = (t - t0) / (t1 - t0)
                return bytes(int(a + (b - a) * f) for a, b in zip(c0, c1))
        return bytes(stops[-1][1])
    out = bytearray(w * h * 3)
    for y in range(h):
        row = bytearray()
        for x in range(0, w, 8):
            t = min(1.0, max(0.0, 0.8 * y / h + 0.2 * x / w))
            row += col(t) * min(8, w - x)
        out[y * w * 3:(y + 1) * w * 3] = row
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--png')
    ap.add_argument('--size', default='1125x2499')
    a = ap.parse_args()
    w, h = ov._parse_wh(a.size)
    tw, th = max(1, w // 3), max(1, h // 3)
    if a.png:
        sw, sh, src = ov._decode_png_rgb(open(a.png, 'rb').read())
        full = ov._resize_rgb_cover(src, sw, sh, w, h)
    else:
        full = gradient_rgb(w, h)
        sw, sh, src = w, h, full
    thumb = ov._resize_rgb_cover(src, sw, sh, tw, th)
    full_png, thumb_png = ov._encode_png_rgb(full, w, h), ov._encode_png_rgb(thumb, tw, th)
    full_cpb, thumb_cpb = ov._encode_cpbitmap_png(full_png, w, h), ov._encode_cpbitmap_png(thumb_png, tw, th)
    asset = {'disableParallax': True, 'fullSizeImageFileName': 'Wallpaper.png', 'identifier': 7565,
             'name': 'Default', 'thumbnailImageFileName': 'Thumbnail.png', 'type': 'Still'}
    bundle_plist = plistlib.dumps({
        'appearanceAware': False, 'assets': {'lockAndHome': {'default': asset}},
        'disableParallax': True, 'family': 'iOS 17', 'fullSizeImageFileName': 'Wallpaper.png',
        'identifier': 7565, 'logicalScreenClass': '375w-812h@3x~iphone', 'name': 'Default',
        'thumbnailImageFileName': 'Thumbnail.png', 'type': 'Still', 'version': 1,
    }, fmt=plistlib.FMT_BINARY)
    wp_defaults = {
        'SBWallpaperHasVideoKey': False,
        'SBWallpaperMagnifyHomeScreenKey': False, 'SBWallpaperMagnifyLockScreenKey': False,
        'SBWallpaperParallaxFactorHomeScreen': 0.0, 'SBWallpaperParallaxFactorLockScreen': 0.0,
        'SBWallpaperPortraitHomeScreenKey': True, 'SBWallpaperPortraitLockScreenKey': True,
        'SBWallpaperZoomScaleHomeScreen': 1.0, 'SBWallpaperZoomScaleLockScreen': 1.0,
        'kSBProceduralWallpaperHomeUserSetKey': False, 'kSBProceduralWallpaperLockUserSetKey': False,
    }
    # Same content make-ios26-overlay.py writes to com.apple.springboard.plist (it rewrites it every boot).
    sb = {'BKNoWatchdogs': True, 'FBLaunchWatchdogExceptions': {'com.apple.purplebuddy': 100.0},
          'MCForceShowCloudConfigurationUI': False, **wp_defaults}
    autobahn = {'Autobahn': {'Enabled': False}, 'AutobahnLegacyMigration': {'Enabled': False},
                'AutobahnLegacyMigrationSupportingDistinctHome': {'Enabled': False}}

    bundle = ('Library/Wallpaper/Collections/iOS_17~iphone.wallpaperCollection/'
              'Wallpapers/7565.iOS_17-375w-812h@3x~iphone.wallpaper')
    with tarfile.open(a.out, 'w', format=tarfile.USTAR_FORMAT) as tf:
        parts = bundle.split('/')
        for i in range(2, len(parts) + 1):
            ov.add_ustar_dir(tf, '/'.join(parts[:i]))
        ov.add_ustar_bytes(tf, f'{bundle}/Wallpaper.png', full_png)
        ov.add_ustar_bytes(tf, f'{bundle}/Thumbnail.png', thumb_png)
        ov.add_ustar_bytes(tf, f'{bundle}/Wallpaper.plist', bundle_plist)
        for d in ('private/var/preferences', 'private/var/preferences/FeatureFlags',
                  'private/var/preferences/FeatureFlags/Domain'):
            ov.add_ustar_dir(tf, d)
        ov.add_ustar_bytes(tf, 'private/var/preferences/FeatureFlags/Domain/SpringBoard.plist',
                           plistlib.dumps(autobahn, fmt=plistlib.FMT_BINARY))
        for d in ('private/var/mobile/Library', 'private/var/mobile/Library/Preferences',
                  'private/var/mobile/Library/SpringBoard'):
            ov.add_ustar_dir(tf, d, uid=MOBILE, gid=MOBILE)
        for name, data in (('LockBackground.cpbitmap', full_cpb), ('HomeBackground.cpbitmap', full_cpb),
                           ('LockBackgroundThumbnail.cpbitmap', thumb_cpb),
                           ('HomeBackgroundThumbnail.cpbitmap', thumb_cpb),
                           ('LockBackgroundThumbnail.jpg', thumb_png), ('HomeBackgroundThumbnail.jpg', thumb_png)):
            ov.add_ustar_bytes(tf, f'private/var/mobile/Library/SpringBoard/{name}', data, uid=MOBILE, gid=MOBILE)
        for name, d in (('com.apple.PaperBoard.plist', wp_defaults), ('com.apple.springboard.plist', sb)):
            ov.add_ustar_bytes(tf, f'private/var/mobile/Library/Preferences/{name}',
                               plistlib.dumps(d, fmt=plistlib.FMT_BINARY), mode=0o600, uid=MOBILE, gid=MOBILE)
    print(f'{a.out}: {os.path.getsize(a.out)} bytes ({w}x{h} wallpaper)')


if __name__ == '__main__':
    main()
