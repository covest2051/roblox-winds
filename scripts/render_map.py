#!/usr/bin/env python3
"""Рисует архипелаг и гонку ботов (вид сверху) из build/map.json → docs/img/map.png. Нужен Pillow.

Путь пилота окрашен цветом слоя, в котором он летел: видно, как гонка складывается
из смены слоёв. Справа — роза ветров: стрелка каждого слоя."""
import json, math, sys
from PIL import Image, ImageDraw

src = sys.argv[1] if len(sys.argv) > 1 else "build/map.json"
dst = sys.argv[2] if len(sys.argv) > 2 else "build/map.png"
d = json.load(open(src))

R = d["spread"] + 140
S = 0.5
PAD = 20
W = H = int(R * 2 * S) + PAD * 2
SIDE = 300
img = Image.new("RGB", (W + SIDE, H), (34, 104, 160))
dr = ImageDraw.Draw(img, "RGBA")


def P(x, z):
    return (PAD + (x + R) * S, PAD + (z + R) * S)


# острова
for isl in d["islands"]:
    cx, cz = P(isl["x"], isl["z"])
    r = isl["r"] * S
    dr.ellipse([cx - r, cz - r, cx + r, cz + r], fill=(232, 214, 160))
    r2 = (isl["r"] - 7) * S
    dr.ellipse([cx - r2, cz - r2, cx + r2, cz + r2], fill=(96, 176, 86))
for h in d["houses"]:
    cx, cz = P(h["x"], h["z"])
    s = h["size"] / 2 * S
    dr.rectangle([cx - s, cz - s, cx + s, cz + s], fill=(190, 80, 60))

# чекпоинты
for i, c in enumerate(d["checkpoints"]):
    cx, cz = P(c["x"], c["z"])
    r = c["r"] * S
    finish = i == len(d["checkpoints"]) - 1
    col = (255, 215, 70) if finish else (150, 235, 255)
    dr.ellipse([cx - r, cz - r, cx + r, cz + r], outline=col, width=3)
    dr.text((cx + r + 3, cz - 7), "F" if finish else str(i + 1), fill=col)
sx, sz = P(d["start"]["x"], d["start"]["z"])
dr.text((sx - 14, sz - 6), "START", fill=(255, 255, 255))


def lcolor(k):
    if k == 0:
        return tuple(d["surface"]["color"])
    return tuple(d["layers"][k - 1]["color"])


# путь новичка — тонкий белый, пилота — по цветам слоёв
nov = d["trails"][1]
dr.line([P(p["x"], p["z"]) for p in nov], fill=(255, 255, 255, 120), width=2)
pro = d["trails"][0]
for a, b in zip(pro, pro[1:]):
    dr.line([P(a["x"], a["z"]), P(b["x"], b["z"])], fill=lcolor(b["layer"]) + (255,), width=4)

# роза ветров справа
ox = W + 20
dr.rectangle([W, 0, W + SIDE, H], fill=(16, 22, 38))
dr.text((ox, 16), "WIND LAYERS (top -> bottom)", fill=(230, 235, 255))
y = 50
for k in range(len(d["layers"]), -1, -1):
    l = d["layers"][k - 1] if k > 0 else d["surface"]
    col = lcolor(k)
    cx, cy = ox + 34, y + 22
    a = l["angle"]
    ln = 10 + l["speed"] * 0.9
    ex, ey = cx + math.cos(a) * ln, cy + math.sin(a) * ln
    dr.line([cx - math.cos(a) * ln, cy - math.sin(a) * ln, ex, ey], fill=col, width=4)
    for s in (1, -1):
        b = a + math.pi + s * 0.5
        dr.line([ex, ey, ex + math.cos(b) * 9, ey + math.sin(b) * 9], fill=col, width=4)
    name = "breeze" if k == 0 else "layer %d" % k
    dr.text((ox + 74, y + 14), "%s  %d studs/s" % (name, round(l["speed"])), fill=col)
    y += 56
res = d["results"]
y += 10
dr.text((ox, y), "pro pilot: %s s, %d layer changes" % (round(res[0]["time"] or 0), res[0]["switches"]), fill=(230, 235, 255))
dr.text((ox, y + 20), "novice (white): %s s" % round(res[1]["time"] or 0), fill=(230, 235, 255))
dr.text((ox, y + 50), "path color = wind layer", fill=(160, 176, 200))
img.save(dst)
print("saved", dst, img.size)
