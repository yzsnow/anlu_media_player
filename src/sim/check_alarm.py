# -*- coding: utf-8 -*-
"""
tb_alarm 结果处理 (应急报警画面):
  * frames/aNN.hex -> frames/aNN.png
  * 报警帧: 按 alarm_screen.v 的算法 (点阵 ROM / 三角 / 斜纹 / 脉动底 / 计时数字, 帧计数 fc 与
    锁存的计时、滚动字幕位置 sc 取自 alist.txt) 逐像素计算期望画面, 整帧必须完全一致 (不叠加频谱等任何 OSD);
    报警第 1 帧 sc = 0 (字幕从屏幕右边外进入), 之后每帧 +1 (alarm_first 为报警第 2 帧, 见下)
  * 正常帧: 字幕栏以上 (y < 368) 必须与原图完全一致 (亮度对比度默认直通)
  * a01 (第 100 行按下 KEY3): 整帧正常; a02: 整帧报警 -> 帧边界硬切
"""
import os
import re
import sys
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
FR = os.path.join(HERE, "frames")
PL = os.path.join(HERE, "..", "user_source", "hdl_source", "player")
W, H = 640, 400
SPEC = {0x40E060, 0xFFD040, 0xFF4040, 0xFFFFFF}


def pat_a(x, y):
    v = x * 255 // 639
    if y < 136:
        return (v << 16) | (v << 8) | v
    if y < 272:
        return (v << 16) | ((255 - v) << 8) | 128
    return (20 << 16) | (v << 8) | 240


def load_params():
    txt = open(os.path.join(PL, "alarm_rom.vh"), encoding="utf-8").read()
    return {k: int(v) for k, v in re.findall(r"localparam \[[\d:]+\]\s+(\w+)\s*=\s*\d+'d(\d+);", txt)}


def load_rom():
    rom = [0] * 8192
    for a, v in re.findall(r"mem\[(\d+)\] = 8'h([0-9a-f]+);", open(os.path.join(PL, "alarm_rom.v"), encoding="utf-8").read()):
        rom[int(a)] = int(v, 16)
    return rom


P = load_params()
ROM = load_rom()


def alarm_px(x, y, fc, t, sc, src=0):
    """alarm_screen.v 的软件模型 (src: 触发来源, 选说明行前半 A1 的第几种)"""
    hit, addr, bsel, csel = False, 0, 0, 1
    for n, cs in (("AT", 0), ("A1", 1), ("AQ", 1), ("A2", 2), ("AL", 3)):
        ry, rx = y - P[n + "_Y"], x - P[n + "_X"]
        if 0 <= ry < P[n + "_H"] and rx >= 0 and (rx >> 3) < P[n + "_WB"]:
            off = P["A1_SZ"] * {1: 1, 2: 2}.get(src, 0) if n == "A1" else 0
            hit, addr, bsel, csel = True, P[n + "_B"] + off + ry * P[n + "_WB"] + (rx >> 3), rx & 7, cs
            break
    if not hit:
        ddx, ddy = x - P["AD_X"], y - P["AD_Y"]
        if 0 <= ddy < P["AD_H"] and ddx >= 0 and (ddx >> 4) < 5:
            c = ddx >> 4
            d = [(t >> 12) & 15, (t >> 8) & 15, 10, (t >> 4) & 15, t & 15][c]
            hit, addr, bsel, csel = True, P["AD_B"] + d * P["AD_GSZ"] + ddy * 2 + ((ddx >> 3) & 1), ddx & 7, 1
    if not hit:
        ry, rx = y - P["AH_Y"], x - P["AH_X"]
        if 0 <= ry < P["AH_H"] and rx >= 0 and (rx >> 3) < P["AH_WB"]:
            hit, addr, bsel, csel = True, P["AH_B"] + ry * P["AH_WB"] + (rx >> 3), rx & 7, 4
    if not hit:
        ry, sx = y - P["AS_Y"], x + sc - 640
        if 0 <= ry < P["AS_H"] and 0 <= sx < P["AS_X"]:
            hit, addr, bsel, csel = True, P["AS_B"] + ry * P["AS_WB"] + (sx >> 3), sx & 7, 1
    if hit and (ROM[addr] >> (7 - bsel)) & 1:
        return {0: 0xFFE040 if fc & 32 else 0xFFFFFF, 2: 0xFFD8A0, 3: 0xFFE0A0, 4: 0xE8E8E8}.get(csel, 0xFFFFFF)
    tr = y - P["TRI_Y"]
    in_ty = 0 <= tr < 56
    cx = P["TRI_LX"] if x < 320 else P["TRI_RX"]
    tdx = abs(x - cx)
    tri_in = in_ty and tdx <= ((tr * 37) >> 6)
    if tri_in and tdx < 4 and (18 <= tr < 40 or 45 <= tr < 52):
        return 0x000000
    if tri_in:
        return 0xFFD000
    if y < 16 or y >= 384:
        return 0xFFC800 if ((x + y + 2 * fc) >> 4) & 1 else 0x181818
    if y == P["SB_Y0"] or y == P["SB_Y1"] - 1:
        return 0xFFC800
    if P["SB_Y0"] <= y < P["SB_Y1"]:
        return 0x280408
    pul = (~fc & 31) if fc & 32 else (fc & 31)
    return ((0x50 + pul * 4) << 16) | 0x18


def in_spec(x, y):
    return 332 <= y < 364 and (128 <= x < 512 or 120 <= x < 123 or 517 <= x < 520)


def load(n):
    with open(os.path.join(FR, "a%02d.hex" % n)) as f:
        px = [int(l, 16) for l in f if l.strip()]
    assert len(px) == W * H, len(px)
    img = Image.new("RGB", (W, H))
    img.putdata([((v >> 16) & 255, (v >> 8) & 255, v & 255) for v in px])
    img.save(os.path.join(FR, "a%02d.png" % n))
    return px


def band_of(freq):
    txt = open(os.path.join(PL, "fft_tables.vh"), encoding="utf-8").read()
    ends = [int(v) for v in re.findall(r"band_end = 9'd(\d+)\s*;", txt)][:24]
    k, start = round(freq / 46.875), 1
    for b, e in enumerate(ends):
        if start <= k <= e:
            return b
        start = e + 1
    return -1


def check_alarm(px, fc, t, sc, src):
    bad = spec = 0
    for y in range(H):
        for x in range(W):
            v, m = px[y * W + x], alarm_px(x, y, fc, t, sc, src)
            if v == m:
                continue
            bad += 1
            if bad <= 3:
                print("     (%d,%d) = %06X, expect %06X" % (x, y, v, m))
    return bad, spec


def check_normal(px):
    return sum(1 for y in range(368) for x in range(W) if px[y * W + x] != pat_a(x, y))


def main():
    info = {}
    for l in open(os.path.join(FR, "alist.txt"), encoding="utf-8"):
        f = l.split()
        if f:
            kv = dict(s.split("=") for s in f[2:])
            info[int(f[0][1:])] = (f[1], int(kv["alm"]), int(kv["fc"]), int(kv["t"], 16), int(kv["sc"]), int(kv["src"]))
    errs = 0
    prev = None                 # 上一帧 (帧号, sc), 检查滚动
    for n in sorted(info):
        tag, alm, fc, t, sc, src = info[n]
        px = load(n)
        want_alm = tag.startswith("alarm")
        if alm != want_alm:
            print("a%02d %-16s alm=%d, expect %d  FAIL" % (n, tag, alm, want_alm))
            errs += 1
            continue
        if want_alm:
            if tag in ("alarm_fire", "alarm_smoke"):
                prev = None                     # 新的一次报警 (中间撤防过), 字幕从头滚动
            want_src = {"alarm_fire": 2, "alarm_smoke": 1}.get(tag, 0)
            bad, spec = check_alarm(px, fc, t, sc, src)
            if src != want_src:
                print("     %s src=%d, expect %d" % (tag, src, want_src))
                bad += 1
            ok = bad == 0
            # 滚动字幕起点: 报警第 k 帧 sc = k - 1. tb 的 grab 结束时本帧 frame_end 已过, 紧接着的
            # grab 要再等一帧, 所以 alarm_first 实际是报警第 2 帧 (sc = 1); alarm_on_splash 在按键后
            # 等 frame_end 再抓, 正好是报警第 1 帧 (sc = 0, 字幕整条在屏幕右边外)
            want_sc = {"alarm_first": 1, "alarm_on_splash": 0}.get(tag)
            if want_sc is not None and sc != want_sc:
                print("     %s sc=%d, expect %d" % (tag, sc, want_sc))
                ok = False
            if prev is not None and sc <= prev:
                print("     sc=%d did not advance (prev %d)" % (sc, prev))
                ok = False
            prev = sc
            print("a%02d %-16s alarm src=%d fc=%-2d t=%02X:%02X sc=%-4d mismatch %d  %s"
                  % (n, tag, src, fc, t >> 8, t & 255, sc, bad, "OK" if ok else "FAIL"))
        else:
            prev = None
            bad = check_normal(px)
            ok = bad == 0
            print("a%02d %-16s normal, %d pixels differ from image  %s" % (n, tag, bad, "OK" if ok else "FAIL"))
        errs += not ok
    # 放大预览
    Image.open(os.path.join(FR, "a04.png")).resize((1280, 800), Image.NEAREST).save(os.path.join(FR, "a04_x2.png"))
    for n in sorted(info):
        if info[n][0] in ("alarm_fire", "alarm_smoke"):
            Image.open(os.path.join(FR, "a%02d.png" % n)).resize((1280, 800), Image.NEAREST).save(
                os.path.join(FR, "%s_x2.png" % info[n][0]))
    print("check_alarm %s" % ("PASS" if errs == 0 else "FAIL"))
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
