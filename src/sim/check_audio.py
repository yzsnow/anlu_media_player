# -*- coding: utf-8 -*-
"""
tb_audio 前后处理
  python check_audio.py gen  RATE N      生成 audio_in.hex: 左 1000 Hz (0.9 满幅), 右 440 Hz (0.5 满幅)
  python check_audio.py check RATE       分析 audio_out.txt: 频率、幅度、断续
  python check_audio.py starve RATE      欠载情形: 去掉暂停期间保持不变的帧后, 剩下的必须是连续的正弦
                                         (频率/幅度正确, 无断续), 并统计暂停次数
"""
import sys
import numpy as np

FL, AL = 1000.0, 0.9
FR, AR = 440.0, 0.5


def gen(rate, n):
    t = np.arange(n) / rate
    l = np.round(AL * 32767 * np.sin(2 * np.pi * FL * t)).astype(np.int64) & 0xFFFF
    r = np.round(AR * 32767 * np.sin(2 * np.pi * FR * t)).astype(np.int64) & 0xFFFF
    with open("audio_in.hex", "w") as f:
        for a, b in zip(l, r):
            f.write("%04x%04x\n" % (a, b))


def tone(x, fs=48000.0):
    """返回 (频率, 幅度): FFT 峰值 + 抛物线插值"""
    w = np.hanning(len(x))
    s = np.abs(np.fft.rfft(x * w))
    k = int(np.argmax(s[1:])) + 1
    a, b, c = np.log(s[k - 1:k + 2] + 1e-30)
    d = 0.5 * (a - c) / (a - 2 * b + c)
    return (k + d) * fs / len(x), np.sqrt(np.mean(x ** 2)) * np.sqrt(2)


def check(rate, starve=False):
    d = np.loadtxt("audio_out.txt", dtype=np.int64)
    l = d[:, 0] / 8388608.0
    r = d[:, 1] / 8388608.0
    nz = np.nonzero(np.abs(l) > 1e-3)[0]
    if len(nz) == 0:
        print("check_audio FAIL: 输出全为 0")
        return 1
    st = nz[0] + 16
    l, r = l[st:], r[st:]
    if starve:
        # 暂停时左右声道都保持上一帧不变; 去掉这些帧
        hold = np.concatenate([[False], (np.diff(l) == 0) & (np.diff(r) == 0)])
        runs = np.diff(hold.astype(int))
        pauses = int(np.sum(runs == 1))
        print(f"paused frames {int(hold.sum())} in {pauses} pauses")
        l, r = l[~hold], r[~hold]
    fl, al = tone(l)
    fr, ar = tone(r)
    # 断续检测: 相邻样本差超出正弦最大斜率的 1.5 倍
    lim = 1.5 * 2 * np.pi * FL / 48000 * AL
    jumps = int(np.sum(np.abs(np.diff(l)) > lim))
    holds = int(np.sum(np.diff(l) == 0))
    print(f"left : {fl:8.2f} Hz  amp {al:.4f}  (expect {FL} Hz, {AL})")
    print(f"right: {fr:8.2f} Hz  amp {ar:.4f}  (expect {FR} Hz, {AR})")
    print(f"discontinuities {jumps}, repeated samples {holds}, frames analysed {len(l)}")
    ok = abs(fl - FL) < 2 and abs(fr - FR) < 2 and abs(al - AL) < 0.02 and abs(ar - AR) < 0.02 and jumps == 0
    print("check_audio PASS" if ok else "check_audio FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    if sys.argv[1] == "gen":
        gen(int(sys.argv[2]), int(sys.argv[3]))
    else:
        sys.exit(check(int(sys.argv[2]), sys.argv[1] == "starve"))
