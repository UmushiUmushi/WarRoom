"""WarRoom's own minimap button art, drawn in the style of the game minimap's + and - (Forever's
ui-hud-minimap-zoom-in/-out: a gold glyph lit from the top, darker below, with a soft shadow down and right; brighter
on mouse-over, dark and pressed down when held). Colours were sampled from those atlases; the drawing is ours.

  reset            the minimap's view back to the player at the game's zoom: a clockwise circular arrow

Each comes in three states, as the game's: <name>.tga, <name>-mouseover.tga, <name>-down.tga (32 x 32, shown at
16-17 UI units, the game's 2x art size).
"""

import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

OUT_DIR = Path(__file__).resolve().parents[2] / "addons" / "WarRoom_Minimap" / "Media"

SIZE = 32
SS = 8  # supersampling
# (top colour, bottom colour) of the glyph's fill, per state, from the game's zoom-in art
FILLS = {
    "": ((251, 219, 98), (192, 148, 51)),
    "-mouseover": ((255, 250, 158), (239, 210, 92)),
    "-down": ((126, 110, 49), (99, 76, 27)),
}
SHADOW = {"": 0.42, "-mouseover": 0.42, "-down": 0.55}  # peak shadow alpha (the game's: about 100-145 of 255)


def reset_mask(down=False):
    """The glyph's coverage at SS x size: a ring open at the top right, an arrowhead on its top end, pointing on round."""
    n = SIZE * SS
    img = Image.new("L", (n, n), 0)
    d = ImageDraw.Draw(img)
    cx, cy = 15.5 * SS, (15.5 + (1.0 if down else 0.0)) * SS
    r_out, r_in = 10.5 * SS, 6.3 * SS
    start, end = -25, 255  # (PIL degrees, clockwise from 3 o'clock; the gap is from `end` round to `start`)
    d.ellipse((cx - r_out, cy - r_out, cx + r_out, cy + r_out), fill=255)
    d.ellipse((cx - r_in, cy - r_in, cx + r_in, cy + r_in), fill=0)
    # (the gap: a wedge from the centre, from `end` round to `start`)
    far = 2 * r_out
    wedge = [(cx, cy)] + [
        (cx + far * math.cos(math.radians(t)), cy + far * math.sin(math.radians(t))) for t in range(end, start + 361, 5)
    ]
    d.polygon(wedge, fill=0)
    # (the arrowhead on the ring's top end, pointing on clockwise, into the gap)
    a = math.radians(end)
    r_mid, half = (r_out + r_in) / 2, (r_out - r_in) * 1.15
    px, py = cx + r_mid * math.cos(a), cy + r_mid * math.sin(a)
    rx, ry = math.cos(a), math.sin(a)  # outwards
    tx, ty = -math.sin(a), math.cos(a)  # clockwise along the ring
    base_out = (px + rx * half, py + ry * half)
    base_in = (px - rx * half, py - ry * half)
    tip = (px + tx * half * 1.3, py + ty * half * 1.3)
    back = 0.6 * SS  # (the base a hair behind the ring's end: no seam)
    d.polygon(
        [(base_out[0] - tx * back, base_out[1] - ty * back), tip, (base_in[0] - tx * back, base_in[1] - ty * back)],
        fill=255,
    )
    return img


def render(mask, state):
    """The glyph in one state: gradient fill over a soft shadow, premultiplied while scaled down."""
    n = SIZE * SS
    top, bottom = FILLS[state]
    fill = Image.new("RGB", (n, n))
    px = fill.load()
    for y in range(n):
        t = y / (n - 1)
        for x in range(n):
            s = 1 - 0.06 * (x / (n - 1))  # (a touch darker to the right, as the game's)
            px[x, y] = tuple(int(round((top[i] + (bottom[i] - top[i]) * t) * s)) for i in range(3))
    shadow = mask.filter(ImageFilter.GaussianBlur(1.6 * SS))
    shadow = ImageChops.offset(shadow, int(1.2 * SS), int(1.8 * SS))
    shadow = shadow.point(lambda v: int(v * SHADOW[state]))
    # composite: the glyph over its shadow (black)
    out = Image.new("RGBA", (n, n))
    o, m, sh, f = out.load(), mask.load(), shadow.load(), fill.load()
    for y in range(n):
        for x in range(n):
            ga = m[x, y] / 255
            sa = sh[x, y] / 255 * (1 - ga)
            a = ga + sa
            if a <= 0:
                o[x, y] = (0, 0, 0, 0)
                continue
            r, g, b = f[x, y]
            # premultiplied
            o[x, y] = (int(r * ga), int(g * ga), int(b * ga), int(round(a * 255)))
    small = out.resize((SIZE, SIZE), Image.BOX)
    sp = small.load()
    for y in range(SIZE):
        for x in range(SIZE):
            r, g, b, a = sp[x, y]
            if a:
                k = 255 / a
                sp[x, y] = (min(255, int(r * k)), min(255, int(g * k)), min(255, int(b * k)), a)
    return small


def build(out_dir=OUT_DIR):
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for state in FILLS:
        img = render(reset_mask(down=state == "-down"), state)
        path = out_dir / f"reset{state}.tga"
        img.save(path)
        written.append(path)
    return written
