# -*- coding: utf-8 -*-
"""
生成 audio_spectrum_osd 用的常数表 -> ../player/fft_tables.vh
  sin_q(k)     : round(32767 * sin(2*pi*k/1024)), k = 0..256 (四分之一周期, 旋转因子与 Hann 窗共用)
  band_end(b)  : 第 b 个频段的最后一个 FFT 点 (1024 点, 48 kHz, 每点 46.875 Hz)
  band_tilt(b) : 显示倾斜补偿 (每倍频程 +3 dB = 2 格, 以 1 kHz 为 0), 让低音多的音乐看起来均衡
频段: 24 段, 约 50 Hz ~ 16 kHz 按对数等分, 低频每段至少 1 个点
用法: python gen_fft_tables.py
"""
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'player', 'fft_tables.vh')

N, FS, NBAND = 1024, 48000, 24
F_LO, F_HI = 50.0, 16000.0
DF = FS / N


def bands():
    lo_bin = max(1, round(F_LO / DF))
    hi_bin = round(F_HI / DF)
    ends, start = [], lo_bin
    for b in range(NBAND):
        e = round(lo_bin * (hi_bin / lo_bin) ** ((b + 1) / NBAND))
        e = max(e, start)                     # 每段至少 1 个点
        ends.append(e)
        start = e + 1
    # 前面强制至少 1 点后可能挤压到后面, 重新保证严格递增且最后一段到 hi_bin
    for b in range(1, NBAND):
        if ends[b] <= ends[b - 1]:
            ends[b] = ends[b - 1] + 1
    return lo_bin, ends


def main():
    lo_bin, ends = bands()
    starts = [lo_bin] + [e + 1 for e in ends[:-1]]
    tilt = []
    for s, e in zip(starts, ends):
        fc = math.sqrt(s * e) * DF
        tilt.append(round(2 * math.log2(fc / 1000.0)))
    L = []
    L.append('// 由 python/gen_fft_tables.py 生成, 不要手改')
    L.append('localparam integer NBAND  = %d;' % NBAND)
    L.append("localparam [8:0]   BIN_LO = 9'd%d;     // 第 0 段起始点 (%.0f Hz)" % (lo_bin, lo_bin * DF))
    L.append("localparam [8:0]   BIN_HI = 9'd%d;    // 最后一段结束点 (%.0f Hz)" % (ends[-1], ends[-1] * DF))
    L.append('')
    L.append('function [8:0] band_end;')
    L.append('    input [4:0] b;')
    L.append('    case (b)')
    for b, (s, e) in enumerate(zip(starts, ends)):
        L.append("        5'd%-2d: band_end = 9'd%-3d;   // %5.0f ~ %5.0f Hz" % (b, e, (s - 0.5) * DF, (e + 0.5) * DF))
    L.append("        default: band_end = 9'd511;")
    L.append('    endcase')
    L.append('endfunction')
    L.append('')
    L.append('function signed [5:0] band_tilt;')
    L.append('    input [4:0] b;')
    L.append('    case (b)')
    for b, t in enumerate(tilt):
        L.append("        5'd%-2d: band_tilt = %s6'sd%d;" % (b, '-' if t < 0 else ' ', abs(t)))
    L.append("        default: band_tilt = 6'sd0;")
    L.append('    endcase')
    L.append('endfunction')
    L.append('')
    L.append('function [14:0] sin_q;')
    L.append('    input [8:0] k;')
    L.append('    case (k)')
    for k in range(257):
        v = min(32767, round(32767 * math.sin(2 * math.pi * k / N)))
        L.append("        9'd%d: sin_q = 15'd%d;" % (k, v))
    L.append("        default: sin_q = 15'd0;")
    L.append('    endcase')
    L.append('endfunction')
    with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(L) + '\n')
    print('bands (bin ranges):', list(zip(starts, ends)))
    print('tilt:', tilt)
    print('wrote', os.path.normpath(OUT))


if __name__ == '__main__':
    main()
