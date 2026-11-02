# -*- coding: utf-8 -*-
"""
tb_spec 结果处理 (SW2 音频频谱画面):
  * frames/sNN.hex -> frames/sNN.png, 以及频谱区放大图 frames/sNN_zoom.png
  * s00 (SW2=0): 频谱区域 (y 320~367) 全部是原图 0x606060
  * s01 (200 Hz + 3 kHz): 区域内只有 原图 / 柱 (绿黄红) / 峰值帽 (白) 三类像素 -> 背景透明;
        最高的两根柱分别在 200 Hz、3 kHz 所在频段; 至少一个峰值帽
  * s02 (静音 3 帧后): 柱子比 s01 矮, 峰值帽仍在 (保持 20 帧)
"""
import os
import re
import sys
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
FR = os.path.join(HERE, "frames")
TAB = os.path.join(HERE, "..", "user_source", "hdl_source", "player", "fft_tables.vh")
W, H = 640, 400
PX0, PY0 = 128, 332
BG = 0x606060
BAR = {0x40E060, 0xFFD040, 0xFF4040}
CAP = 0xFFFFFF


def load(n):
    with open(os.path.join(FR, "s%02d.hex" % n)) as f:
        px = [int(l, 16) for l in f if l.strip()]
    assert len(px) == W * H, len(px)
    return px


def save(n, px):
    img = Image.new("RGB", (W, H))
    img.putdata([((v >> 16) & 255, (v >> 8) & 255, v & 255) for v in px])
    img.save(os.path.join(FR, "s%02d.png" % n))
    img.crop((96, 316, 544, 372)).resize((1344, 168), Image.NEAREST).save(os.path.join(FR, "s%02d_zoom.png" % n))


def heights(px):
    """每根柱的亮格数 (取柱中间一列) 与峰值帽行"""
    hs, caps = [], []
    for b in range(24):
        x = PX0 + b * 16 + 8
        col = [px[(PY0 + r) * W + x] for r in range(32)]
        hs.append(sum(1 for v in col if v in BAR))
        caps.append(sum(1 for v in col if v == CAP))
    return hs, caps


def band_of(freq):
    txt = open(TAB, encoding="utf-8").read()
    ends = [int(v) for v in re.findall(r"band_end = 9'd(\d+)\s*;", txt)][:24]
    k, start = round(freq / 46.875), 1
    for b, e in enumerate(ends):
        if start <= k <= e:
            return b
        start = e + 1
    return -1


def main():
    n = len([l for l in open(os.path.join(FR, "slist.txt"), encoding="utf-8") if l.strip()])
    fr = {i: load(i) for i in range(n)}
    for i in fr:
        save(i, fr[i])
    errs = 0
    area = [(x, y) for y in range(320, 368) for x in range(W)]

    bad = sum(1 for x, y in area if fr[0][y * W + x] != BG)
    print("%-32s %s" % ("s00 SW2=0 untouched", "OK" if bad == 0 else "%d pixels changed" % bad))
    errs += bad != 0

    other = sum(1 for x, y in area if fr[1][y * W + x] not in BAR and fr[1][y * W + x] not in (BG, CAP))
    print("%-32s %s" % ("s01 transparent background", "OK" if other == 0 else "%d foreign pixels" % other))
    errs += other != 0

    h1, c1 = heights(fr[1])
    top2 = sorted(sorted(range(24), key=lambda b: -h1[b])[:2])
    want = sorted([band_of(200), band_of(3000)])
    ok = top2 == want
    print("%-32s %s (expect %s)  %s" % ("s01 tallest bands", top2, want, "OK" if ok else "FAIL"))
    print("     heights:", " ".join("%2d" % h for h in h1))
    errs += not ok
    okc = sum(c1) > 0
    print("%-32s %d  %s" % ("s01 peak caps", sum(c1), "OK" if okc else "FAIL"))
    errs += not okc

    h2, c2 = heights(fr[2])
    okd = all(h2[b] < h1[b] for b in want) and all(c2[b] for b in want)
    print("%-32s %s -> %s, caps %s  %s" % ("s02 decay + cap hold", [h1[b] for b in want], [h2[b] for b in want],
                                           [c2[b] for b in want], "OK" if okd else "FAIL"))
    errs += not okd

    print("check_spec_img %s" % ("PASS" if errs == 0 else "FAIL"))
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
