#!/usr/bin/env python3
"""Draws the hobo signs for VM icons as chalk-style SVGs, into Sources/HoboVM/Resources/Signs: each
stroke is laid down three times with a different wobble, which gives uneven edges like a chalk line.
The output is deterministic. A sign added or removed here must also change VMIcon.signs.

    python3 assets/draw_signs.py
"""
import math, os, random

# The default sweep passes 360 degrees, so a circle's ends overlap as a hand-drawn one's do.
def circle(cx, cy, r, start=-100, sweep=375, ry=None):
    ry = ry or r
    n = 64
    return [(cx + r * math.cos(math.radians(start + sweep * i / n)),
             cy + ry * math.sin(math.radians(start + sweep * i / n))) for i in range(n + 1)]

def bezier(p0, p1, p2, p3, n=24):
    out = []
    for i in range(n + 1):
        t = i / n; u = 1 - t
        out.append((u**3*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t**3*p3[0],
                    u**3*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t**3*p3[1]))
    return out

def x_mark(cx, cy, r):
    return [[(cx - r, cy - r), (cx + r, cy + r)], [(cx + r, cy - r), (cx - r, cy + r)]]

def wave(x0, x1, y, amp, cycles):
    n = 60
    return [(x0 + (x1 - x0) * i / n, y + amp * math.sin(2 * math.pi * cycles * i / n)) for i in range(n + 1)]

def dot(cx, cy, r):
    return circle(cx, cy, r, 0, 720)

def coil():
    n = 90; turns = 2.5
    pts = []
    for i in range(n + 1):
        t = 2 * math.pi * turns * i / n
        pts.append((500 + 85 * math.cos(t), 310 + 380 * i / n + 62 * math.sin(t)))
    return pts

def shovel(x):
    return [[(x - 75, 200), (x + 75, 200)], [(x, 200), (x, 560)],
            [(x - 100, 560), (x + 100, 560), (x + 100, 690), (x, 815), (x - 100, 690), (x - 100, 560)]]

def hatch():
    strokes = [[(150, 800), (860, 215)]]
    for t in (0.14, 0.29, 0.44, 0.59, 0.74, 0.89):
        cx, cy = 150 + 710 * t, 800 - 585 * t
        strokes.append([(cx - 55, cy - 125), (cx + 55, cy + 125)])
    return strokes

# Each sign's meaning, then its strokes in a 1000 x 1000 box. These are our own drawings of the
# traditional signs. Whether hobos really used them is doubtful, so they aren't presented as history.
SIGNS = {
    "this-way": [circle(370, 500, 190), [(560, 500), (850, 500)], [(710, 360), (860, 500), (710, 640)]],
    "hit-the-road": [circle(450, 500, 200), [(140, 435), (800, 435)], [(140, 565), (800, 565)], [(680, 310), (860, 500), (680, 690)]],
    "road-spoiled": [[(180, 225), (820, 225), (500, 810), (180, 225)]],
    "this-is-the-place": [[(215, 750), (215, 470), (785, 470), (785, 750)], [(500, 470), (500, 190)]],
    "good-road": [circle(500, 500, 270), [(190, 190), (810, 810)]],
    "nothing-to-gain": [circle(500, 500, 310)],
    "camp-here": [[(240, 220), (240, 790), (760, 790), (760, 220)]],
    "all-right": x_mark(500, 500, 290),
    "good-for-a-handout": [circle(500, 500, 320)] + x_mark(500, 500, 130),
    "fresh-water": [wave(150, 850, 300, 55, 3)] + x_mark(500, 610, 135) + [circle(235, 620, 75), circle(765, 620, 75)],
    "rich": [[(190, 235), (190, 505), (420, 505), (420, 235), (190, 235)], [(110, 515), (500, 515)], [(510, 790), (690, 400), (880, 790), (510, 790)]],
    "doctor": [[(430, 170), (430, 840)], [(160, 450), (700, 450)], circle(725, 245, 95), dot(725, 245, 18)],
    "keep-quiet": [[(310, 270), (470, 500), (310, 730), (150, 500), (310, 270)], [(690, 270), (850, 500), (690, 730), (530, 500), (690, 270)]],
    "barking-dog": [[(120, 590), (250, 400), (380, 600), (500, 400), (620, 600), (750, 400), (880, 590)]],
    "not-safe": [[(180, 800), (390, 200)], [(395, 800), (605, 200)], [(610, 800), (820, 200)]],
    "defend-yourself": [[(500, 150), (740, 420), (500, 690), (260, 420), (500, 150)], [(500, 690), (500, 870)]],
    "cursed-out": hatch(),
    "police": [circle(360, 500, 195), circle(640, 500, 195, start=80)],
    "thieves": [bezier((385, 245), (410, 110), (620, 120), (600, 260)) + [(390, 425), (620, 425)], [(280, 505), (720, 505)], [(375, 590), (375, 840)], circle(575, 715, 90, ry=125)],
    "jail": [[(x, 170), (x, 830)] for x in (310, 500, 690)] + [[(170, y), (830, y)] for y in (310, 500, 690)],
    "courthouse": [circle(500, 500, 330), coil()],
    "work-here": shovel(310) + shovel(690),
    "burned-house": [[(180, 490), (820, 260)], [(270, 460), (270, 800), (730, 800), (730, 300)], [(270, 800), (730, 470)], [(270, 470), (730, 800)]],
    "man-with-gun": [[(500, 280), (715, 780), (285, 780), (500, 280)],
                     [(395, 530), (210, 420)], [(210, 420), (100, 330)], [(210, 420), (215, 270)], [(210, 420), (75, 465)],
                     [(605, 530), (790, 420)], [(790, 420), (900, 330)], [(790, 420), (785, 270)], [(790, 420), (925, 465)]],
}

def densify(points, step=18):
    out = [points[0]]
    for a, b in zip(points, points[1:]):
        d = math.hypot(b[0] - a[0], b[1] - a[1])
        n = max(1, int(d / step))
        for i in range(1, n + 1):
            out.append((a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n))
    return out

def wobbled(points, rng, amp):
    """Offsets x and y by a long wave plus a fainter short one, measured along the stroke."""
    x_long, x_short, y_long, y_short = [rng.uniform(0, 2 * math.pi) for _ in range(4)]
    long_wave, short_wave = rng.uniform(170, 320), rng.uniform(70, 130)
    out, travelled = [], 0.0
    prev = points[0]
    for x, y in points:
        travelled += math.hypot(x - prev[0], y - prev[1]); prev = (x, y)
        out.append((x + amp * (math.sin(travelled / long_wave + x_long) + 0.4 * math.sin(travelled / short_wave + x_short)),
                    y + amp * (math.sin(travelled / long_wave + y_long) + 0.4 * math.sin(travelled / short_wave + y_short))))
    return out

CHALK = "#F5F0E4"
# Stroke width, wobble amplitude and opacity of each time a stroke is laid down.
PASSES = [(46, 8, 1.0), (44, 7, 0.9), (38, 6, 0.75)]

def svg(name, strokes):
    rng = random.Random(name)
    paths = []
    for width, amp, opacity in PASSES:
        for stroke in strokes:
            pts = wobbled(densify(stroke), rng, amp)
            d = "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in pts)
            paths.append(f'  <path d="{d}" stroke-width="{width}" stroke-opacity="{opacity}"/>')
    body = "\n".join(paths)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000" width="1000" height="1000">\n'
            f'<title>{name}</title>\n<g fill="none" stroke="{CHALK}" stroke-linecap="round" stroke-linejoin="round">\n'
            f'{body}\n</g>\n</svg>\n')

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "HoboVM", "Resources", "Signs")
os.makedirs(out, exist_ok=True)
for name, strokes in SIGNS.items():
    with open(os.path.join(out, name + ".svg"), "w") as f:
        f.write(svg(name, strokes))
print(len(SIGNS), "signs")
