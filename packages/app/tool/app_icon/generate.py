#!/usr/bin/env python3
"""Generates every SpeedDial app icon from one vector design.

The artwork is a full-bleed square (no baked-in corners or shadow): platforms
apply their own mask. On Android it ships as an adaptive icon (graphite
background + orange foreground + monochrome for themed icons), with the glyph
kept inside the 66/108 safe zone.

Not a project dependency; run by hand after changing the design:

    python3 -m venv /tmp/iconvenv
    /tmp/iconvenv/bin/pip install cairosvg pillow
    /tmp/iconvenv/bin/python packages/app/tool/app_icon/generate.py
"""

import io
import math
from pathlib import Path

import cairosvg
from PIL import Image

APP = Path(__file__).resolve().parents[2]

ACCENT = '#FF7A33'  # Graphite & Signal dark accent (lib/src/theme.dart)
BG_TOP = '#252422'
BG_BOTTOM = '#121211'

# Material "call" glyph (Apache 2.0), 24-unit viewBox.
HANDSET = (
    'M20.01 15.38c-1.23 0-2.42-.2-3.53-.56-.35-.12-.74-.03-1.01.24l-1.57 1.97'
    'c-2.83-1.35-5.48-3.9-6.89-6.83l1.95-1.66c.27-.28.35-.67.24-1.02'
    '-.37-1.11-.56-2.3-.56-3.53 0-.54-.45-.99-.99-.99H4.19C3.65 3 3 3.24 3 3.99'
    ' 3 13.28 10.73 21 20.01 21c.71 0 .99-.63.99-1.18v-3.45'
    'c0-.54-.45-.99-.99-.99z'
)

# Layout on a 1024 canvas that maps to Android's 108dp foreground layer.
SCALE = 22.0
ORIGIN_X, ORIGIN_Y = 372.0, 262.0  # where glyph point (3, 3) lands
STROKE = 40
LINE_GAP = 46
# (offset across the motion axis, length) for each speed line.
SPEED_LINES = ((-112, 105), (0, 165), (112, 105))


def _foreground(color: str) -> str:
    # Speed lines trail bottom-left of the handset's curved back, parallel to
    # the up-right motion, each starting LINE_GAP clear of the curve.
    cx = ORIGIN_X + SCALE * 17.5
    cy = ORIGIN_Y + SCALE * 0.5
    r = 17.5 * SCALE
    k = 1 / math.sqrt(2)
    lines = []
    for offset, length in SPEED_LINES:
        d = math.sqrt(r * r - offset * offset) + LINE_GAP
        x1 = cx + offset * k - d * k
        y1 = cy + offset * k + d * k
        x2 = x1 - length * k
        y2 = y1 + length * k
        lines.append(
            f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}"/>')
    tx = ORIGIN_X - 3 * SCALE
    ty = ORIGIN_Y - 3 * SCALE
    return (
        f'<path transform="translate({tx:g} {ty:g}) scale({SCALE:g})" '
        f'd="{HANDSET}" fill="{color}"/>'
        f'<g stroke="{color}" stroke-width="{STROKE}" stroke-linecap="round" '
        f'fill="none">{"".join(lines)}</g>'
    )


_BACKGROUND = (
    '<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
    f'<stop offset="0" stop-color="{BG_TOP}"/>'
    f'<stop offset="1" stop-color="{BG_BOTTOM}"/>'
    '</linearGradient></defs>'
    '<rect width="1024" height="1024" fill="url(#bg)"/>'
)


def _svg(body: str) -> str:
    return ('<svg xmlns="http://www.w3.org/2000/svg" '
            f'viewBox="0 0 1024 1024">{body}</svg>')


FULL = _svg(_BACKGROUND + _foreground(ACCENT))
BACKGROUND = _svg(_BACKGROUND)
FOREGROUND = _svg(_foreground(ACCENT))
MONOCHROME = _svg(_foreground('#FFFFFF'))


def _render(svg: str, size: int, path: Path, opaque: bool) -> None:
    png = cairosvg.svg2png(bytestring=svg.encode(),
                           output_width=size, output_height=size)
    image = Image.open(io.BytesIO(png))
    image = image.convert('RGB' if opaque else 'RGBA')
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)
    print(f'{path.relative_to(APP)} ({size}px)')


def main() -> None:
    (APP / 'tool/app_icon/speeddial_icon.svg').write_text(FULL + '\n')

    res = APP / 'android/app/src/main/res'
    for density, mult in (('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2),
                          ('xxhdpi', 3), ('xxxhdpi', 4)):
        mipmap = res / f'mipmap-{density}'
        _render(FULL, round(48 * mult), mipmap / 'ic_launcher.png', True)
        layer = round(108 * mult)
        _render(BACKGROUND, layer, mipmap / 'ic_launcher_background.png', True)
        _render(FOREGROUND, layer, mipmap / 'ic_launcher_foreground.png', False)
        _render(MONOCHROME, layer, mipmap / 'ic_launcher_monochrome.png', False)

    ios = APP / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    for points, scales in ((20, (1, 2, 3)), (29, (1, 2, 3)), (40, (1, 2, 3)),
                           (60, (2, 3)), (76, (1, 2)), (83.5, (2,)),
                           (1024, (1,))):
        for scale in scales:
            name = f'Icon-App-{points:g}x{points:g}@{scale}x.png'
            _render(FULL, round(points * scale), ios / name, True)

    web = APP / 'web'
    _render(FULL, 16, web / 'favicon.png', True)
    for size in (192, 512):
        _render(FULL, size, web / f'icons/Icon-{size}.png', True)
        _render(FULL, size, web / f'icons/Icon-maskable-{size}.png', True)

    _render(FULL, 512, APP / 'linux/runner/resources/speeddial_launcher.png',
            True)


if __name__ == '__main__':
    main()
