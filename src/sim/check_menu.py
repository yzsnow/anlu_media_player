# -*- coding: utf-8 -*-
"""
tb_menu 结果处理:
  * frames/mNN.hex -> frames/mNN.png
  * 对图像区域逐像素核对画面调节查找表 (color_lut_gen.v):
        y = min(255, x * bri >> 7)                       bri = 级别 * 16  (第十四讲公式)
        z = clamp(((y - 128) * con >> 7) + 128, 0, 255)  con = 级别 * 16
        w = min(255, z * gain_c >> 8)                    色温增益 (gen_gamma_rom.temp_gain)
        q = gamma_curve(伽马级别)[w]                     伽马曲线 (gen_gamma_rom.gamma_curve)
  * 默认值 (亮度 8 / 对比度 8) 必须与原图完全相同; 对比度 0 为中灰 128
  * 帧中途改参数不影响当前帧 (VS 锁存)
"""
import os
import sys
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "user_source", "hdl_source", "python"))
from gen_gamma_rom import gamma_curve, temp_gain       # noqa: E402  与硬件 ROM 同一份数据
FR = os.path.join(HERE, "frames")
W, H = 640, 400


def pat_a(x, y):
    v = x * 255 // 639
    if y < 136:
        return (v, v, v)
    if y < 272:
        return (v, 255 - v, 128)
    return (20, v, 240)


GAMMA = [gamma_curve(l) for l in range(17)]


def adj(c, bl, cl, ch=0, tl=8, gl=8):
    b, k = bl * 16, cl * 16
    y = min(255, (c * b) >> 7)
    z = max(0, min(255, (((y - 128) * k) >> 7) + 128))
    w = min(255, (z * temp_gain(tl)[ch]) >> 8)
    return GAMMA[gl][w]


def load(n):
    with open(os.path.join(FR, "m%02d.hex" % n)) as f:
        px = [int(l, 16) for l in f if l.strip()]
    assert len(px) == W * H, len(px)
    return px


def to_png(n, px):
    img = Image.new("RGB", (W, H))
    img.putdata([((v >> 16) & 255, (v >> 8) & 255, v & 255) for v in px])
    img.save(os.path.join(FR, "m%02d.png" % n))


def check(n, px, bl, cl, rows, xs=range(W), bl2=None, row2=None, tl=8, gl=8):
    bad = 0
    for y in rows:
        b = bl2 if (row2 is not None and y >= row2) else bl
        for x in xs:
            exp = tuple(adj(c, b, cl, ch, tl, gl) for ch, c in enumerate(pat_a(x, y)))
            v = px[y * W + x]
            got = ((v >> 16) & 255, (v >> 8) & 255, v & 255)
            if got != exp:
                if bad < 5:
                    print("  m%02d (%d,%d) got %s exp %s" % (n, x, y, got, exp))
                bad += 1
    return bad


def main():
    lines = open(os.path.join(FR, "mlist.txt"), encoding="utf-8").read().split("\n")
    lines = [l for l in lines if l.strip()]
    for l in lines:
        print(l)
    frames = {}
    for n in range(len(lines)):
        frames[n] = load(n)
        to_png(n, frames[n])

    img_rows = range(0, 368)                 # 信息栏关闭, 368 行以下为滚动字幕区
    total = 0
    tests = [
        (0, "bypass (8/8)",      lambda px: check(0, px, 8, 8, img_rows)),
        (1, "bright 12",         lambda px: check(1, px, 12, 8, img_rows)),
        (2, "contrast 13",       lambda px: check(2, px, 8, 13, img_rows)),
        (3, "sat 16/16",         lambda px: check(3, px, 16, 16, img_rows)),
        (4, "contrast 0 = grey", lambda px: check(4, px, 8, 0, img_rows)),
        # 菜单画面: 框外 (y < 40, y 328~367) 仍按 5/11 调节
        (5, "menu outside box",  lambda px: check(5, px, 5, 11, list(range(0, 40)) + list(range(328, 368)))),
        # 帧中途改亮度: 本帧全部仍为 8, 下一帧为 4
        (7, "mid-frame change",  lambda px: check(7, px, 8, 8, img_rows)),
        (8, "next frame",        lambda px: check(8, px, 4, 8, img_rows)),
        (9, "temp 2 (warm)",     lambda px: check(9, px, 8, 8, img_rows, tl=2)),
        (10, "temp 14 (cool)",   lambda px: check(10, px, 8, 8, img_rows, tl=14)),
        (11, "gamma 4",          lambda px: check(11, px, 8, 8, img_rows, gl=4)),
        (12, "gamma 12",         lambda px: check(12, px, 8, 8, img_rows, gl=12)),
        (13, "night 5/7/4/10",   lambda px: check(13, px, 5, 7, img_rows, tl=4, gl=10)),
        (14, "menu_mode outside", lambda px: check(14, px, 7, 8, list(range(0, 40)) + list(range(328, 368)), tl=1)),
    ]
    for n, name, fn in tests:
        b = fn(frames[n])
        print("%-20s %s" % (name, "OK" if b == 0 else "%d mismatches" % b))
        total += b
    # 对比度 0: 全部中灰
    grey = all(frames[4][y * W + x] == 0x808080 for y in img_rows for x in range(W))
    print("%-20s %s" % ("con0 all 0x808080", "OK" if grey else "FAIL"))
    total += 0 if grey else 1
    # 菜单框内: 背景变暗, 至少有文字像素
    box = [frames[5][y * W + x] for y in range(40, 328) for x in range(128, 512)]
    txt = sum(1 for v in box if v in (0xFFE060, 0xE0E0E0, 0x60E0FF, 0x4090B0, 0x607080, 0xFFD040, 0x80E0FF, 0xFFFFFF))
    print("%-20s %d text pixels" % ("menu box", txt))
    total += 0 if txt > 3000 else 1
    # 色温方向: 偏暖时蓝通道变小、红不变; 偏冷时红变小、蓝不变 (灰阶区 x = 600, y = 50)
    def rgb(n, x, y):
        v = frames[n][y * W + x]
        return (v >> 16) & 255, (v >> 8) & 255, v & 255
    w, c, o = rgb(9, 600, 50), rgb(10, 600, 50), rgb(0, 600, 50)
    ok = w[0] == o[0] and w[2] < o[2] and c[2] == o[2] and c[0] < o[0]
    print("%-20s %s  orig %s warm %s cool %s" % ("temp direction", "OK" if ok else "FAIL", o, w, c))
    total += 0 if ok else 1
    # 伽马方向: 级别大 (0.71) 暗部变亮, 级别小 (1.41) 暗部变暗 (x = 160 灰阶约 64)
    g4, g12, o = rgb(11, 160, 50)[0], rgb(12, 160, 50)[0], rgb(0, 160, 50)[0]
    ok = g4 < o < g12
    print("%-20s %s  orig %d gamma4 %d gamma12 %d" % ("gamma direction", "OK" if ok else "FAIL", o, g4, g12))
    total += 0 if ok else 1

    print("check_menu %s" % ("PASS" if total == 0 else "FAIL"))
    return 0 if total == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
