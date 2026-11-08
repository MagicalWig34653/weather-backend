#!/usr/bin/env python3
"""Scale contract of the temperature/humidity maps (docs/fixtures/scales/scales-v1.json).

  tools/check_palette.py --generate   writes scales-v1.json from the anchor colours below (Lab interpolation, one band per step)
  tools/check_palette.py              checks the file: structure, and that the colours of neighbouring label steps (label_every)
                                      differ by CIE76 delta E >= 10 in normal vision and in simulated protanopia, deuteranopia
                                      and tritanopia (Machado et al. 2009, severity 1.0, linear RGB). Exit code 1 on any failure.
Python 3 standard library only.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(HERE, "..", "docs", "fixtures", "scales", "scales-v1.json")
MIN_DELTA_E = 10.0

# (id, unit, min, max, step, label_every, anchors [(value, hex)])
SCALES = [
    ("t2m-d2-v1", "°C", -30, 40, 1, 5, [
        # cold side: dark -> light up to freezing (pale cyan), warm side: pale yellow (0 °C and above) -> dark red
        (-30, "#240a4a"), (-20, "#3a3fb0"), (-10, "#4a8fe8"), (-1, "#b5ecf7"),
        (0, "#fff6c8"), (10, "#f9cc45"), (20, "#dc5d22"), (30, "#a01a1f"), (39, "#3d0812")]),
    ("td-d2-v1", "°C", -20, 24, 1, 5, [  # dry (light) -> humid (dark), YlGnBu
        (-20, "#ffffe8"), (-14.5, "#d2e89a"), (-9, "#a0d8a8"), (-3.5, "#6cc4b4"), (2, "#2fa5c0"),
        (7.5, "#2a73b8"), (13, "#2c4a9e"), (18.5, "#1e2a6e"), (23, "#040c2e")]),
    ("rh-d2-v1", "%", 0, 100, 5, 20, [  # BuPu, dry (light) -> humid (dark)
        (0, "#f7fcfd"), (12.5, "#e0ecf4"), (25, "#bfd3e6"), (37.5, "#9ebcda"), (50, "#8c96c6"),
        (62.5, "#8c6bb1"), (75, "#88419d"), (87.5, "#810f7c"), (100, "#4d004b")]),
]

CVD = {
    "protanopia": [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]],
    "deuteranopia": [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]],
    "tritanopia": [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]],
}


def hex_to_rgb(h):
    return tuple(int(h[i:i + 2], 16) / 255.0 for i in (1, 3, 5))


def rgb_to_hex(rgb):
    return "#" + "".join("%02x" % max(0, min(255, round(c * 255))) for c in rgb)


def to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def to_srgb(c):
    c = max(0.0, min(1.0, c))
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def rgb_to_lab(rgb):
    r, g, b = (to_linear(c) for c in rgb)
    x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
    y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883

    def f(t):
        return t ** (1 / 3) if t > 216 / 24389 else (24389 / 27 * t + 16) / 116
    fx, fy, fz = f(x), f(y), f(z)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))


def lab_to_rgb(lab):
    l, a, b = lab
    fy = (l + 16) / 116
    fx, fz = fy + a / 500, fy - b / 200

    def finv(t):
        return t ** 3 if t ** 3 > 216 / 24389 else (116 * t - 16) / (24389 / 27)
    x, y, z = finv(fx) * 0.95047, finv(fy), finv(fz) * 1.08883
    r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
    g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
    bl = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
    return tuple(to_srgb(c) for c in (r, g, bl))


def simulate(rgb, matrix):
    lin = [to_linear(c) for c in rgb]
    return tuple(to_srgb(sum(matrix[i][j] * lin[j] for j in range(3))) for i in range(3))


def delta_e(a, b):
    return sum((x - y) ** 2 for x, y in zip(a, b)) ** 0.5


def color_at(anchors, value):
    if value <= anchors[0][0]:
        return anchors[0][1]
    for (v0, h0), (v1, h1) in zip(anchors, anchors[1:]):
        if value <= v1:
            t = (value - v0) / (v1 - v0)
            a, b = rgb_to_lab(hex_to_rgb(h0)), rgb_to_lab(hex_to_rgb(h1))
            return rgb_to_hex(lab_to_rgb(tuple(a[i] + (b[i] - a[i]) * t for i in range(3))))
    return anchors[-1][1]


def generate():
    scales = []
    for sid, unit, lo, hi, step, label_every, anchors in SCALES:
        bands, v = [], lo
        while v < hi:  # the last band (from max - step) also holds every value above max
            bands.append({"from": v, "hex": color_at(anchors, v)})
            v += step
        scales.append({"id": sid, "unit": unit, "min": lo, "max": hi, "step": step, "label_every": label_every, "bands": bands})
    doc = {"schema": 1, "scales": scales}
    lines = ['{', ' "schema": 1,', ' "scales": [']
    for i, sc in enumerate(scales):
        head = ", ".join('"%s": %s' % (k, json.dumps(sc[k], ensure_ascii=False))
                         for k in ("id", "unit", "min", "max", "step", "label_every"))
        lines.append("  {%s," % head)
        lines.append('   "bands": [')
        rows = ['    {"from": %s, "hex": "%s"}' % (b["from"], b["hex"]) for b in sc["bands"]]
        lines.append(",\n".join(rows))
        lines.append("   ]}" + ("," if i < len(scales) - 1 else ""))
    lines += [" ]", "}"]
    with open(PATH, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    print("geschrieben:", os.path.normpath(PATH))


def check():
    with open(PATH, encoding="utf-8") as fh:
        doc = json.load(fh)
    failures = 0
    if doc.get("schema") != 1:
        print("FEHLER: schema != 1")
        return 1
    for s in doc["scales"]:
        bands = s["bands"]
        problems = []
        if bands[0]["from"] != s["min"]:
            problems.append("erstes Band beginnt nicht bei min")
        for a, b in zip(bands, bands[1:]):
            if abs(b["from"] - a["from"] - s["step"]) > 1e-9:
                problems.append("Luecke/Ueberlappung bei %s" % b["from"])
        if bands[-1]["from"] != s["max"] - s["step"]:
            problems.append("letztes Band (ab %s) endet nicht bei max" % bands[-1]["from"])
        if len({b["hex"] for b in bands}) != len(bands):
            problems.append("doppelte Farben")
        print("\nSkala %s (%s, %s bis %s, Schritt %s, %d Baender)" % (s["id"], s["unit"], s["min"], s["max"], s["step"], len(bands)))
        by_value = {b["from"]: b["hex"] for b in bands}
        labels = [v for v in sorted(by_value) if (v - s["min"]) % s["label_every"] == 0]
        views = [("normal", None)] + list(CVD.items())
        print("  %-14s" % "Beschriftung" + "".join("%-14s" % n for n, _ in views))
        for v0, v1 in zip(labels, labels[1:]):
            row, ok = "  %-14s" % ("%g -> %g" % (v0, v1)), True
            for name, matrix in views:
                c0, c1 = hex_to_rgb(by_value[v0]), hex_to_rgb(by_value[v1])
                if matrix:
                    c0, c1 = simulate(c0, matrix), simulate(c1, matrix)
                d = delta_e(rgb_to_lab(c0), rgb_to_lab(c1))
                flag = "" if d >= MIN_DELTA_E else " !"
                ok = ok and d >= MIN_DELTA_E
                row += "%-14s" % ("%.1f%s" % (d, flag))
            print(row + ("" if ok else "  <-- unter %.0f" % MIN_DELTA_E))
            if not ok:
                failures += 1
        for p in problems:
            print("  FEHLER:", p)
            failures += 1
    print("\nErgebnis:", "BESTANDEN" if failures == 0 else "%d Verstoesse" % failures)
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    if "--generate" in sys.argv:
        generate()
    else:
        sys.exit(check())
