#!/usr/bin/env python3
"""Generate the Dits app icon: the Morse code for "CW" rendered as glowing
dits and dahs.

A deep night-sky gradient with two centered rows of rounded elements —
the top row spells C (-.-.), the bottom spells W (.--) — keyed in a warm
amber sidetone glow. Flat, full-bleed 1024x1024; iOS applies the corner
mask.

Usage: python3 tools/make_icon.py <output.png>
"""

import sys
from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def make_background():
    top = (18, 42, 78)      # deep radio blue
    bottom = (5, 8, 18)      # near black
    img = Image.new("RGB", (SIZE, SIZE))
    px = img.load()
    for y in range(SIZE):
        t = (y / (SIZE - 1)) ** 0.85
        color = lerp(top, bottom, t)
        for x in range(SIZE):
            px[x, y] = color
    return img


# Warm sidetone palette: amber core fading to orange.
AMBER = (255, 200, 92)
ORANGE = (255, 138, 32)


def draw_element(draw, x, y, length, height, t):
    """A rounded dit (square-ish) or dah (long bar) at a vertical center."""
    color = lerp(AMBER, ORANGE, t)
    draw.rounded_rectangle(
        [x, y - height / 2, x + length, y + height / 2],
        radius=height / 2,
        fill=color,
    )


def draw_morse(img):
    """Render '-.-.' over '.--', centered, glowing."""
    overlay = Image.new("RGB", (SIZE, SIZE), (0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    unit = 70           # one dit length
    height = 70          # element thickness
    dit = unit
    dah = unit * 3
    gap = unit           # gap between elements within a letter

    rows = [
        [dah, dit, dah, dit],   # C
        [dit, dah, dah],        # W
    ]
    row_y = [SIZE * 0.40, SIZE * 0.62]

    for elements, cy in zip(rows, row_y):
        total = sum(elements) + gap * (len(elements) - 1)
        x = (SIZE - total) / 2
        for i, length in enumerate(elements):
            t = i / max(1, len(elements) - 1)
            draw_element(draw, x, cy, length, height, t)
            x += length + gap

    # Screen-blend a soft glow under the crisp elements.
    glow = overlay.filter(ImageFilter.GaussianBlur(26))
    img = ImageChops.screen(img, glow)
    img = ImageChops.screen(img, overlay.filter(ImageFilter.GaussianBlur(1.2)))
    return img


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png"
    img = make_background()
    img = draw_morse(img)
    img.save(out, "PNG")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
