# -*- coding: utf-8 -*-
"""
tb_video 结果处理:
  * frames/fNN.hex -> frames/fNN.png, 以及总览图 frames/overview.png
  * 对非 OSD 区域 (第 28~367 行) 逐像素核对转场混合结果 (640x400):
        out = A + (B - A) * q / 256, q 按 video_compositor 中各特效的公式计算
"""
import os
import sys
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
FR = os.path.join(HERE, "frames")
W, H = 640, 400
Y0, Y1 = 28, 368            # 顶部信息栏 / 底部字幕之外的区域


def pat_a(x, y):
    return (x * 255 // 639, y * 255 // 399, 64)


def pat_b(x, y):
    c = 230 if ((x >> 5) ^ (y >> 5)) & 1 else 30
    return (c, 255 - c, (x + y) & 255)


def bit(v, i):
    return (v >> i) & 1


def q_of(eff, p, x, y):
    """返回 (q, blk_a, blk_b), 与 RTL 中 S2 级组合逻辑一致"""
    if p >= 256:
        return 256, False, False
    if eff == 0:
        return p, False, False
    if eff == 1:
        return (256 if x < 2 * p + (p >> 1) else 0), False, False
    if eff == 2:
        return (256 if y < p + (p >> 1) + (p >> 4) else 0), False, False
    if eff == 3:
        d2 = (x - 320) ** 2 + (y - 200) ** 2
        rr = p + (p >> 1) + 1
        return (256 if d2 < (rr * rr) & 0xFFFFF else 0), False, False
    if eff == 4:
        return (256 if (y & 31) < (p >> 3) else 0), False, False
    if eff == 5:
        bk = ((y >> 5) << 5) | (x >> 5)
        rot = (bit(bk, 8) << 7) | ((bk & 7) << 4) | ((bk >> 4) & 15)
        hmb = ((bk & 0xFF) * 157 & 0xFF) ^ rot ^ 0x5A
        return (256 if hmb < p else 0), False, False
    if eff == 6:
        bay = (((bit(x, 0) ^ bit(y, 0)) << 3) | (bit(y, 0) << 2) |
               ((bit(x, 1) ^ bit(y, 1)) << 1) | bit(y, 1))
        hd = ((((y >> 2) & 15) << 4 | ((x >> 2) & 15)) * 109 & 0xFF) ^ (((x >> 6) & 15) << 4 | ((y >> 5) & 15))
        thr = (bay << 4) | (hd >> 4)
        return (256 if thr < p else 0), False, False
    q = (p & 127) * 2
    return (q, False, True) if p < 128 else (q, True, False)


def expect(eff, p, b_en, x, y):
    a = pat_a(x, y)
    if not b_en:
        return a
    b = pat_b(x, y)
    q, ba, bb = q_of(eff, p, x, y)
    if ba:
        a = (0, 0, 0)
    if bb:
        b = (0, 0, 0)
    return tuple((ai + (((bi - ai) * q) >> 8)) & 255 for ai, bi in zip(a, b))


def load(fn):
    with open(fn) as f:
        v = [int(l, 16) for l in f if l.strip()]
    if len(v) != W * H:
        raise ValueError(f"{fn}: {len(v)} pixels")
    return [((c >> 16) & 255, (c >> 8) & 255, c & 255) for c in v]


def main():
    entries = []
    with open(os.path.join(FR, "list.txt")) as f:
        for line in f:
            t = line.split()
            if not t:
                continue
            kv = dict(s.split("=") for s in t[2:])
            entries.append((t[0], t[1], {k: int(v) for k, v in kv.items()}))

    errors = 0
    thumbs = []
    for name, tag, kv in entries:
        px = load(os.path.join(FR, name + ".hex"))
        img = Image.new("RGB", (W, H))
        img.putdata(px)
        img.save(os.path.join(FR, name + ".png"))
        label = f"{name} {tag} eff={kv['eff']} p={kv['p']}"
        if not kv["splash"]:
            bad = 0
            first = None
            for y in range(Y0, Y1):
                for x in range(W):
                    e = expect(kv["eff"], kv["p"], kv["b_en"], x, y)
                    if px[y * W + x] != e:
                        bad += 1
                        if first is None:
                            first = (x, y, px[y * W + x], e)
            print(f"{label:48s} mismatches: {bad}" + (f"  first {first}" if first else ""))
            errors += bad != 0
        else:
            print(f"{label:48s} (splash, png only)")
        t = img.resize((W // 2, H // 2))
        ImageDraw.Draw(t).text((4, H // 2 - 18), f"{name} {tag}", fill=(255, 255, 0))
        thumbs.append(t)

    cols = 4
    rows = (len(thumbs) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * W // 2, rows * H // 2))
    for i, t in enumerate(thumbs):
        sheet.paste(t, ((i % cols) * W // 2, (i // cols) * H // 2))
    sheet.save(os.path.join(FR, "overview.png"))
    for name, _, _ in entries:
        os.remove(os.path.join(FR, name + ".hex"))
    print("==== check_video PASS ====" if errors == 0 else f"==== check_video FAIL ({errors} frames) ====")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
