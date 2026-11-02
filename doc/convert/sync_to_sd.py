# -*- coding: utf-8 -*-
"""
TF 卡一键同步工具 (FAT32 多媒体播放器版)

FPGA 端通过 FAT32 目录解析读取文件, 不再按物理扇区搜索 BMP, 因此无需再破坏旧文件头.
默认按文件夹分类写入 (FPGA 优先读取这几个文件夹, 没有时读根目录, 旧卡照常使用):
  IMG/IMG01.BMP ...  MUSIC/MUSIC.WAV  SUB/SUB.TXT  SUB/SUB.FNT  以及根目录的播放列表 PLAY.CFG:
      每行 "图片编号 显示秒数" (编号 = IMGnn.BMP 的 nn), 行的先后 = 播放顺序, '#' 后为注释;
      可直接用记事本编辑: 调换行的顺序 = 改播放顺序, 改秒数 = 改显示时长 (1~255, 0 = 默认 4 秒)
加 --flat 则全部放在根目录 (旧版布局, 按目录顺序播放, 每张 4 秒). 文件要求:
  * *.BMP  任意分辨率 (宽高 16~4096) 24/32bit 非压缩, 最多 16 张, 按目录顺序播放
           (本脚本按文件名排序后依次复制). FPGA 加载时等比缩放到 640x400, 比例不同时补黑边;
           大图读卡时间长 (约与文件大小成正比), 预先转成 640x400 加载最快
  * *.WAV  第一个 WAV 作为背景音乐 (8/16 bit PCM, 8k~48k)
  * SUB.TXT / SUB.FNT  滚动字幕与字库 (由 make_subtitle.py 生成)

用法:
  python sync_to_sd.py E:                      # 源目录默认 ./output_bmp
  python sync_to_sd.py E: -s 图片目录 -w MUSIC.WAV -t SUB.TXT -f SUB.FNT
  python sync_to_sd.py E: --keep               # 不清空 TF 卡根目录 (IMG / MUSIC / SUB 文件夹仍会先清空)
  python sync_to_sd.py E: -d 5                  # 每张图显示 5 秒 (写入 PLAY.CFG)
  python sync_to_sd.py E: --flat                # 旧版布局: 全部放根目录, 不写播放列表
"""
import os
import sys
import glob
import struct
import shutil
import re
import argparse

MAX_IMG = 16
DUR_DEFAULT = 4              # 默认每张图显示秒数 (FPGA 端 0 也按 4 秒)
DUR_MAX = 255
CFG_NAME = "PLAY.CFG"
FOLDERS = ("IMG", "MUSIC", "SUB")
BMP_MIN, BMP_MAX = 16, 4096  # FPGA (bmp_fit_scaler) 支持的宽 / 高范围


def bmp_ok(path):
    """检查是否为 FPGA 可读的 BMP (与 sd_media_loader / bmp_fit_scaler 的判断一致):
    宽高 16~4096 (高度可为负, 即自上而下存储), 24bit 非压缩或 32bit (BI_RGB / BI_BITFIELDS)"""
    try:
        with open(path, "rb") as f:
            h = f.read(54)
        if len(h) < 54 or h[0:2] != b"BM":
            return False
        off, w, hh, bpp, comp = (struct.unpack_from("<I", h, 10)[0], struct.unpack_from("<i", h, 18)[0],
                                 struct.unpack_from("<i", h, 22)[0], struct.unpack_from("<H", h, 28)[0],
                                 struct.unpack_from("<I", h, 30)[0])
        h_abs = abs(hh)
        fmt_ok = (bpp == 24 and comp == 0) or (bpp == 32 and comp in (0, 3))
        stride = (w * (bpp // 8) + 3) // 4 * 4 if fmt_ok else 0
        return (off >= 54 and fmt_ok and BMP_MIN <= w <= BMP_MAX and BMP_MIN <= h_abs <= BMP_MAX
                and os.path.getsize(path) >= off + stride * h_abs)
    except OSError:
        return False


def collect_bmps(src, log=print):
    """源目录中可用的 BMP, 按文件名排序"""
    bmps = sorted(set(glob.glob(os.path.join(src, "*.bmp")) + glob.glob(os.path.join(src, "*.BMP"))))
    good = [b for b in bmps if bmp_ok(b)]
    for b in bmps:
        if b not in good:
            log(f"[跳过] {os.path.basename(b)} 不是 FPGA 支持的 BMP (宽高 16~4096, 24/32bit 非压缩), 可用 convert_images_to_bmp.py 转换")
    return good


def clean_drive(target, log=print):
    log(f"正在清空 {target} 中的旧文件...")
    for item in os.listdir(target):
        if item.startswith(".") or item.lower() == "system volume information":
            continue
        p = os.path.join(target, item)
        try:
            if os.path.isfile(p):
                os.remove(p)
            elif os.path.isdir(p):
                shutil.rmtree(p)
        except Exception as e:
            log(f"  [警告] 无法删除 {p}: {e}")


def clean_folder(d, log=print):
    """清空 IMG / MUSIC / SUB 文件夹 (保留 TF 卡原有文件时也要清, 否则旧图片会混进来)"""
    if os.path.isdir(d):
        for n in os.listdir(d):
            p = os.path.join(d, n)
            try:
                if os.path.isfile(p):
                    os.remove(p)
                else:
                    shutil.rmtree(p)
            except Exception as e:
                log(f"  [警告] 无法删除 {p}: {e}")
    else:
        os.makedirs(d)


def cfg_text(items):
    """播放列表 PLAY.CFG 文本. items = [(编号, 秒数, 说明)], 按播放顺序"""
    lines = ["# FPGA 多媒体播放器 播放列表 (素材工具生成)",
             "# 每行: 图片编号 显示秒数    编号 = IMG 文件夹中 IMGnn.BMP 的 nn; 行的先后 = 播放顺序",
             "# 可以用记事本直接修改: 调换行的顺序即改变播放顺序, 修改秒数即改变显示时长 (1~255)",
             "# '#' 之后是注释"]
    for n, d, note in items:
        lines.append(f"{n:02d} {d:<4d}# {note}" if note else f"{n:02d} {d}")
    return "\r\n".join(lines) + "\r\n"


def read_cfg(path):
    """读取 PLAY.CFG (与 FPGA 解析规则相同): 返回 [(编号, 秒数, 注释)], 按行的先后"""
    out, seen = [], set()
    try:
        with open(path, "rb") as f:
            text = f.read(2048).decode("utf-8", "replace")
    except OSError:
        return out
    for line in text.splitlines():
        body, _, note = line.partition("#")
        nums = re.findall(r"\d+", body)
        if not nums:
            continue
        n = int(nums[0])
        d = min(int(nums[1]), DUR_MAX) if len(nums) > 1 else 0
        if 1 <= n <= MAX_IMG and n not in seen and len(out) < MAX_IMG:
            seen.add(n)
            out.append((n, d, note.strip()))
    return out


def copy(src, dst, log=print):
    shutil.copyfile(src, dst)
    log(f"  {os.path.basename(src)} -> {os.path.basename(dst)}")


def is_system_root(target):
    t = os.path.abspath(target)
    drv = os.path.splitdrive(t)[0]
    return drv.upper() == os.path.splitdrive(os.environ.get("SystemRoot", "C:"))[0].upper() and t == drv + os.sep


def sync(target, bmps, wav=None, txt=None, fnt=None, keep=False, log=print, folder=True, durs=None):
    """把文件写入 TF 卡. bmps 为按播放顺序排好的 BMP 列表, durs 为对应的显示秒数.
    folder=True: IMG/IMGnn.BMP, MUSIC/MUSIC.WAV, SUB/SUB.TXT, SUB/SUB.FNT + 根目录 PLAY.CFG;
    folder=False: 旧版布局, 全部放根目录 (不写播放列表)"""
    if len(target) == 2 and target[1] == ":":
        target += os.sep
    if not os.path.isdir(target):
        raise ValueError(f"找不到 {target}")
    bmps = bmps[:MAX_IMG]
    durs = list(durs or [])[:len(bmps)] + [DUR_DEFAULT] * (len(bmps) - len(durs or []))
    if not keep:
        clean_drive(target, log)
    if folder:
        d_img, d_mus, d_sub = (os.path.join(target, n) for n in FOLDERS)
        for d in (d_img, d_mus, d_sub):
            clean_folder(d, log)
        cfg = os.path.join(target, CFG_NAME)
        if os.path.exists(cfg):
            os.remove(cfg)
    else:
        d_img = d_mus = d_sub = target
    log(f"复制 {len(bmps)} 张图片:")
    for i, b in enumerate(bmps):
        # 8.3 短文件名, OSD 信息栏显示前 8 个字符; 文件名中的编号即播放列表中的编号
        copy(b, os.path.join(d_img, f"IMG{i + 1:02d}.BMP"), log)
    if wav:
        copy(wav, os.path.join(d_mus, "MUSIC.WAV"), log)
    if txt:
        copy(txt, os.path.join(d_sub, "SUB.TXT"), log)
    if fnt:
        copy(fnt, os.path.join(d_sub, "SUB.FNT"), log)
    if folder and bmps:
        with open(os.path.join(target, CFG_NAME), "w", encoding="utf-8", newline="") as f:
            f.write(cfg_text([(i + 1, durs[i], os.path.basename(b)) for i, b in enumerate(bmps)]))
        log(f"  播放列表 -> {CFG_NAME} ({len(bmps)} 行: " + ", ".join(f"{i + 1:02d}={d}s" for i, d in enumerate(durs)) + ")")
    log("同步完成, 安全弹出后插入开发板即可.")


def main():
    ap = argparse.ArgumentParser(description="FPGA 多媒体播放器 TF 卡同步工具")
    ap.add_argument("drive", help="TF 卡盘符或挂载目录, 例如 E:")
    ap.add_argument("-s", "--source", help="BMP 源目录 (默认 ./output_bmp)")
    ap.add_argument("-n", "--num", type=int, default=MAX_IMG, help=f"最多复制的图片数 (默认 {MAX_IMG})")
    ap.add_argument("-w", "--wav", help="背景音乐 WAV (可先用 convert_wav.py 转换)")
    ap.add_argument("-t", "--txt", help="字幕 SUB.TXT")
    ap.add_argument("-f", "--fnt", help="字库 SUB.FNT")
    ap.add_argument("--keep", action="store_true", help="不清空 TF 卡根目录")
    ap.add_argument("-d", "--dur", type=int, default=DUR_DEFAULT, help=f"每张图显示秒数 (默认 {DUR_DEFAULT})")
    ap.add_argument("--flat", action="store_true", help="旧版布局: 全部放根目录, 不写播放列表")
    a = ap.parse_args()

    target = a.drive
    if len(target) == 2 and target[1] == ":":
        target += os.sep
    if not os.path.isdir(target):
        print(f"[错误] 找不到 {target}")
        sys.exit(1)
    if is_system_root(target):
        if input("警告: 目标是系统盘根目录, 确定继续? (y/N): ").lower() != "y":
            sys.exit(0)

    here = os.path.dirname(os.path.abspath(__file__))
    good = collect_bmps(a.source or os.path.join(here, "output_bmp"))
    good = good[:min(a.num, MAX_IMG)]
    sync(target, good, a.wav, a.txt, a.fnt, a.keep, folder=not a.flat,
         durs=[max(1, min(a.dur, DUR_MAX))] * len(good))


if __name__ == "__main__":
    main()
