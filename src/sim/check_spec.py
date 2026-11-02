# -*- coding: utf-8 -*-
"""
tb_spec_unit 结果核对 (audio_spectrum_osd):
  1. 定点模型逐位核对: 用 spec/cN_in.txt 的 1024 个样本, 按 RTL 相同的定点算法
     (Hann 窗 -> 位反序 -> 10 级基 2 DIT, 每级 (a +/- W*b + 1) >> 1) 计算,
     与 spec/cN_fft.txt 全部 1024 点、spec/cN_band.txt 24 个高度必须完全一致
  2. 精度: 与双精度浮点 FFT (同一窗) 比较, 报告信噪比
  3. 频谱形状: 各用例峰值落在正确的频段
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SP = os.path.join(HERE, "spec")
TAB = os.path.join(HERE, "..", "user_source", "hdl_source", "player", "fft_tables.vh")
N = 1024
LG_OFF = 24

S = [min(32767, round(32767 * math.sin(2 * math.pi * k / N))) for k in range(257)]


def load_tables():
    import re
    txt = open(TAB, encoding="utf-8").read()
    ends = [int(v) for v in re.findall(r"band_end = 9'd(\d+)\s*;", txt)][:24]
    tilts = []
    for sgn, v in re.findall(r"band_tilt = (-?)\s*6'sd(\d+);", txt)[:24]:
        tilts.append(-int(v) if sgn else int(v))
    lo = int(re.search(r"BIN_LO = 9'd(\d+)", txt).group(1))
    return lo, ends, tilts


def cos_n(n):
    q, r = n >> 8, n & 255
    v = S[r] if q & 1 else S[256 - r]
    return -v if ((q >> 1) ^ q) & 1 else v


def bitrev(x):
    return int(format(x, "010b")[::-1], 2)


def fft_fixed(samples):
    d = [(0, 0)] * N
    for n, s in enumerate(samples):
        wn = (32768 - cos_n(n)) >> 1
        d[bitrev(n)] = ((s * wn) >> 14, 0)
    for st in range(10):
        half = 1 << st
        for j in range(512):
            k = j & (half - 1)
            a = ((j >> st) << (st + 1)) | k
            b = a + half
            m = k << (9 - st)
            c = S[256 - m] if m < 256 else -S[m - 256]
            sn = S[m] if m < 256 else S[512 - m]
            ar, ai = d[a]
            br, bi = d[b]
            tr = (c * br + sn * bi) >> 15
            ti = (c * bi - sn * br) >> 15
            d[a] = ((ar + tr + 1) >> 1, (ai + ti + 1) >> 1)
            d[b] = ((ar - tr + 1) >> 1, (ai - ti + 1) >> 1)
    return d


def mag(re, im):
    a, b = abs(re), abs(im)
    return max(a, b) + (min(a, b) >> 1)


def hgt(v, tilt):
    if v == 0:
        return 0
    p = v.bit_length() - 1
    f = (v >> (p - 2)) & 3 if p >= 2 else 0
    l = p * 4 + f - LG_OFF + tilt
    return max(0, min(32, l))


def bands(d, lo, ends, tilts):
    out, start = [], lo
    for e, t in zip(ends, tilts):
        out.append(hgt(max(mag(*d[k]) for k in range(start, e + 1)), t))
        start = e + 1
    return out


def band_of(freq, lo, ends):
    k = round(freq / 46.875)
    start = lo
    for b, e in enumerate(ends):
        if start <= k <= e:
            return b
        start = e + 1
    return -1


def main():
    lo, ends, tilts = load_tables()
    expect_peaks = {0: [1000], 1: [200, 3000], 2: [60], 3: None, 4: []}
    errs = 0
    for c in range(5):
        smp = [int(l) for l in open(os.path.join(SP, "c%d_in.txt" % c)) if l.strip()]
        hw = [tuple(int(v) for v in l.split()) for l in open(os.path.join(SP, "c%d_fft.txt" % c)) if l.strip()]
        hb = [int(l) for l in open(os.path.join(SP, "c%d_band.txt" % c)) if l.strip()]
        ok_n = len(smp) == N and len(hw) == N
        md = fft_fixed(smp) if ok_n else []
        nbad = sum(1 for a, b in zip(md, hw) if a != b) if ok_n else -1
        mb = bands(md, lo, ends, tilts) if ok_n else []
        bad_b = mb != hb
        # 与浮点 FFT 比较 (同一窗, 同样 1/1024 缩放)
        xs = [s * ((32768 - cos_n(n)) >> 1) / 16384.0 for n, s in enumerate(smp)]
        sig = err = 0.0
        for k in range(1, 342):
            re = sum(x * math.cos(2 * math.pi * k * n / N) for n, x in enumerate(xs)) / N
            im = -sum(x * math.sin(2 * math.pi * k * n / N) for n, x in enumerate(xs)) / N
            sig += re * re + im * im
            err += (re - hw[k][0]) ** 2 + (im - hw[k][1]) ** 2
        snr = 10 * math.log10(sig / err) if err > 0 and sig > 0 else float("inf")
        top = sorted(range(24), key=lambda b: -hb[b])
        pk = expect_peaks[c]
        if pk is None:
            shape = "noise: %d bands > 0" % sum(1 for h in hb if h > 0)
            ok_s = sum(hb[16:]) > sum(hb[:8])        # 白噪声: 高频段更宽且有倾斜补偿, 应明显高于低频段
        elif not pk:
            shape = "silence: max %d" % max(hb)
            ok_s = max(hb) == 0
        else:
            want = sorted(band_of(f, lo, ends) for f in pk)
            got = sorted(top[:len(pk)])
            shape = "peak bands %s (expect %s)" % (got, want)
            ok_s = got == want
        ok = ok_n and nbad == 0 and not bad_b and ok_s
        errs += not ok
        print("c%d  fft bit-exact %s  bands %s  SNR %5.1f dB  %s  %s" % (
            c, "OK" if nbad == 0 else "%d diff" % nbad, "OK" if not bad_b else "DIFF", snr, shape,
            "PASS" if ok else "FAIL"))
        print("     heights:", " ".join("%2d" % h for h in hb))
    print("check_spec %s" % ("PASS" if errs == 0 else "FAIL"))
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
