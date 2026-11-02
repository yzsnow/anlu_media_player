# -*- coding: utf-8 -*-
"""
背景音乐转换工具: 任意 WAV (PCM 8/16/24/32 bit, float32, EXTENSIBLE) -> 播放器可用 WAV

FPGA 端 (sd_media_loader + audio_i2s_player) 支持:
  * 格式标签 1 (PCM), 8 或 16 bit, 单声道或立体声
  * 采样率 8000 ~ 48000 Hz (硬件线性插值重采样到 48k 后经 HDMI 输出)
  * 播放 TF 卡根目录下找到的第一个 *.WAV, 播完自动循环

本脚本输出 16 bit PCM, 44 字节标准文件头. 默认一律重采样到 48000 Hz (--rate),
与第十一讲 make_audio_corpus.py 的做法一致: 采样率转换在电脑上用高质量滤波器做,
FPGA 端 48k 样本与 48k 输出帧一一对应, 不经硬件插值, 音调和音质与原曲相同.
--keep-rate: 采样率在 8k~48k 内时保持原值 (交给硬件线性插值, 适合想减小文件/带宽时).
其他格式 (mp3/flac...) 如装有 ffmpeg 会自动调用.

用法:
  python convert_wav.py input.wav                  -> MUSIC.WAV (48000 Hz)
  python convert_wav.py song.mp3 -o <TF卡根目录>/MUSIC.WAV --mono
"""
import os
import sys
import struct
import argparse
import shutil
import subprocess
import tempfile
from array import array

try:
    import numpy as np
except ImportError:          # 没有 numpy 时退回线性插值
    np = None

RATE_MIN, RATE_MAX = 8000, 48000
TAG_NAMES = {1: "PCM", 3: "IEEE float", 0xFFFE: "EXTENSIBLE"}


def _chunks(path):
    """返回 (fmt, data 偏移, data 长度); fmt = (tag, 声道, 采样率, 位深)"""
    with open(path, "rb") as f:
        head = f.read(12)
        if len(head) < 12 or head[0:4] != b"RIFF" or head[8:12] != b"WAVE":
            raise ValueError("不是 RIFF/WAVE 文件")
        fmt, doff, dlen = None, None, None
        while True:
            h = f.read(8)
            if len(h) < 8:
                break
            cid, size = h[0:4], struct.unpack("<I", h[4:8])[0]
            if cid == b"fmt ":
                body = f.read(size)
                tag, chn, rate, _, _, bits = struct.unpack_from("<HHIIHH", body, 0)
                if tag == 0xFFFE and len(body) >= 26:
                    tag = struct.unpack_from("<H", body, 24)[0]
                fmt = (tag, chn, rate, bits)
                f.seek(size & 1, 1)
            elif cid == b"data":
                doff = f.tell()
                end = f.seek(0, 2)
                dlen = min(size, end - doff)        # 部分软件写出的 data 长度不正确
                break
            else:
                f.seek(size + (size & 1), 1)
    if fmt is None or doff is None:
        raise ValueError("缺少 fmt 或 data 块")
    return fmt, doff, dlen


def wav_info(path):
    """只读文件头: 返回 dict(tag, chans, rate, bits, frames, seconds, fpga_ok)"""
    (tag, chn, rate, bits), _, dlen = _chunks(path)
    frames = dlen // max(1, chn * bits // 8)
    return {
        "tag": tag, "tag_name": TAG_NAMES.get(tag, str(tag)), "chans": chn, "rate": rate, "bits": bits,
        "frames": frames, "seconds": frames / rate if rate else 0.0,
        # 不经转换就能直接放到 TF 卡上播放
        "fpga_ok": tag == 1 and bits in (8, 16) and chn in (1, 2) and RATE_MIN <= rate <= RATE_MAX,
    }


def read_wav(path):
    (tag, chn, rate, bits), doff, dlen = _chunks(path)
    if tag not in (1, 3):
        raise ValueError(f"不支持的编码 (format tag {tag})")
    if chn < 1:
        raise ValueError("声道数为 0")
    step = bits // 8
    n = dlen // (step * chn)
    with open(path, "rb") as f:
        f.seek(doff)
        pcm = f.read(n * step * chn)

    # 常见格式用 array 批量解码, 比逐个 struct.unpack 快一个数量级
    typecode, scale, offset = None, 1.0, 0.0
    if tag == 3 and bits == 32:
        typecode = "f"
    elif tag == 3 and bits == 64:
        typecode = "d"
    elif tag == 1 and bits == 8:
        typecode, scale, offset = "B", 1 / 128.0, -1.0
    elif tag == 1 and bits == 16:
        typecode, scale = "h", 1 / 32768.0
    elif tag == 1 and bits == 32:
        typecode, scale = "i", 1 / 2147483648.0
    elif not (tag == 1 and bits == 24):
        raise ValueError(f"不支持的位深 {bits}")

    if typecode:
        a = array(typecode)
        a.frombytes(pcm)
        if sys.byteorder == "big" and typecode != "B":
            a.byteswap()
        chans = [[v * scale + offset for v in a[c::chn]] for c in range(chn)]
    else:
        vals = [int.from_bytes(pcm[o:o + 3], "little", signed=True) / 8388608.0
                for o in range(0, n * chn * 3, 3)]
        chans = [vals[c::chn] for c in range(chn)]
    return rate, chans


SINC_TAPS = 16              # 单侧抽头数
SINC_PHASES = 4096          # 分数延迟量化级数
_sinc_tab = {}


def _sinc_table(fc):
    """Kaiser 窗 sinc 插值核, 形状 (SINC_PHASES + 1, 2 * SINC_TAPS); fc 为相对输入奈奎斯特的截止"""
    if fc not in _sinc_tab:
        k = np.arange(-SINC_TAPS + 1, SINC_TAPS + 1)
        d = np.arange(SINC_PHASES + 1)[:, None] / SINC_PHASES - k[None, :]
        win = np.i0(8.0 * np.sqrt(np.clip(1.0 - (d / SINC_TAPS) ** 2, 0.0, 1.0))) / np.i0(8.0)
        _sinc_tab[fc] = fc * np.sinc(fc * d) * win
    return _sinc_tab[fc]


def resample_sinc(ch, src, dst):
    """带限 (Kaiser 窗 sinc) 重采样; 降采样时截止频率随之降低, 防止混叠"""
    x = np.asarray(ch, dtype=np.float64)
    n = int(len(x) * dst / src)
    tab = _sinc_table(min(1.0, dst / src) * 0.95)
    xp = np.concatenate([np.zeros(SINC_TAPS), x, np.zeros(SINC_TAPS + 1)])
    k = np.arange(-SINC_TAPS + 1, SINC_TAPS + 1) + SINC_TAPS
    out = np.empty(n)
    for s in range(0, n, 32768):
        i = np.arange(s, min(n, s + 32768))
        num = i * src                      # 整数运算, 长文件也没有累积误差
        base = num // dst
        ph = ((num - base * dst) * SINC_PHASES + dst // 2) // dst
        out[s:s + len(i)] = np.sum(tab[ph] * xp[base[:, None] + k[None, :]], axis=1)
    return out.tolist()


def resample(ch, src, dst):
    if src == dst:
        return ch
    if np is not None:
        return resample_sinc(ch, src, dst)
    n = int(len(ch) * dst / src)
    out = [0.0] * n
    r = src / dst
    last = len(ch) - 1
    for i in range(n):
        x = i * r
        k = int(x)
        f = x - k
        a = ch[min(k, last)]
        b = ch[min(k + 1, last)]
        out[i] = a + (b - a) * f
    return out


def write_wav(path, rate, chans):
    chn = len(chans)
    n = len(chans[0])
    pcm = array("h", bytes(n * chn * 2))
    for c in range(chn):
        pcm[c::chn] = array("h", [32767 if v >= 1.0 else -32768 if v <= -1.0 else int(round(v * 32767.0))
                                  for v in chans[c]])
    if sys.byteorder == "big":
        pcm.byteswap()
    data = pcm.tobytes()
    hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
    hdr += b"fmt " + struct.pack("<IHHIIHH", 16, 1, chn, rate, rate * chn * 2, chn * 2, 16)
    hdr += b"data" + struct.pack("<I", len(data))
    with open(path, "wb") as f:
        f.write(hdr)
        f.write(data)


def ffmpeg_to_wav(src):
    exe = shutil.which("ffmpeg")
    if not exe:
        return None
    tmp = os.path.join(tempfile.gettempdir(), "fpga_audio_tmp.wav")
    subprocess.run([exe, "-y", "-loglevel", "error", "-i", src, "-acodec", "pcm_s16le", tmp], check=True)
    return tmp


def convert(src, out, rate=48000, force_rate=None, mono=False, seconds=None, gain=1.0,
            normalize=False, log=print, keep_rate=False):
    """完整转换流程, 出错时抛出 ValueError. 返回结果信息 dict
    目标采样率: force_rate > (keep_rate 且原采样率在 8k~48k 时保持原值) > rate (默认 48000)"""
    try:
        in_rate, chans = read_wav(src)
    except Exception as e:
        log(f"不能直接按 WAV 读取 ({e}), 尝试用 ffmpeg 解码...")
        tmp = ffmpeg_to_wav(src)
        if not tmp:
            raise ValueError(f"无法读取 {src}: {e} (非 WAV 文件需要安装 ffmpeg)")
        in_rate, chans = read_wav(tmp)
        os.remove(tmp)
    if not chans or not chans[0]:
        raise ValueError("音频为空")

    if len(chans) > 2 or mono:
        k = 1.0 / len(chans)
        mix = [sum(v) * k for v in zip(*chans)]
        chans = [mix] if mono else [mix, list(mix)]

    dst = force_rate or (in_rate if keep_rate and RATE_MIN <= in_rate <= RATE_MAX else rate)
    if not RATE_MIN <= dst <= RATE_MAX:
        raise ValueError(f"目标采样率需在 {RATE_MIN}~{RATE_MAX}")
    if seconds:
        chans = [c[:int(seconds * in_rate)] for c in chans]
    if dst != in_rate:
        log(f"重采样 {in_rate} Hz -> {dst} Hz ({'sinc 滤波' if np is not None else '线性插值, 装 numpy 可提高音质'}) ...")
    chans = [resample(c, in_rate, dst) for c in chans]
    if not chans[0]:
        raise ValueError("截取后音频为空")

    peak = max(max(max(c), -min(c)) for c in chans)
    if normalize and peak > 0:
        gain = gain * 0.98 / peak
    if gain != 1.0:
        chans = [[v * gain for v in c] for c in chans]
    clipped = peak * gain > 1.0

    write_wav(out, dst, chans)
    n = len(chans[0])
    info = {"in_rate": in_rate, "rate": dst, "chans": len(chans), "seconds": n / dst,
            "bytes": os.path.getsize(out), "gain": gain, "clipped": clipped}
    log(f"{src}: {in_rate} Hz -> {out}: {dst} Hz, {len(chans)} 声道, 16 bit, {n / dst:.1f} s, "
        f"{info['bytes'] / 1024:.0f} KB" + (f", 增益 {gain:.2f}" if gain != 1.0 else ""))
    if clipped:
        log("[提示] 增益过大, 部分采样被削波, 可降低音量倍数")
    return info


def main():
    ap = argparse.ArgumentParser(description="转换 FPGA 播放器背景音乐 WAV")
    ap.add_argument("input")
    ap.add_argument("-o", "--out", default="MUSIC.WAV", help="输出文件 (默认 MUSIC.WAV)")
    ap.add_argument("--rate", type=int, default=48000, help="目标采样率 (默认 48000, 与 HDMI 输出一致)")
    ap.add_argument("--keep-rate", action="store_true",
                    help="原采样率在 8k~48k 内时不转换 (由 FPGA 线性插值到 48k)")
    ap.add_argument("--force-rate", type=int, help="强制重采样到指定采样率 (同 --rate)")
    ap.add_argument("--mono", action="store_true", help="混成单声道 (TF 卡带宽减半, 推荐)")
    ap.add_argument("--seconds", type=float, help="只保留前 N 秒")
    ap.add_argument("--gain", type=float, default=1.0, help="音量倍数")
    ap.add_argument("--normalize", action="store_true", help="把峰值归一化到 98%% (再乘以 --gain)")
    a = ap.parse_args()

    try:
        convert(a.input, a.out, a.rate, a.force_rate, a.mono, a.seconds, a.gain, a.normalize,
                keep_rate=a.keep_rate)
    except (ValueError, OSError, subprocess.CalledProcessError) as e:
        print(f"[错误] {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
