# -*- coding: utf-8 -*-
"""
滚动字幕生成工具: UTF-8 文本 -> SUB.TXT + SUB.FNT

FPGA 端约定 (sd_media_loader / video_compositor):
  * SUB.TXT : 取前 512 字节, 每字节一个 8x16 字符格
              0x20~0x7F  内置 ASCII 字库
              0x80~0xFF  用户字库 (SUB.FNT) 第 code-0x80 个字模
              <0x20      显示为空格 (换行等会被替换成空格)
  * SUB.FNT : 2048 字节 = 128 个 8x16 字模, 每字模 16 行, 每行 1 字节, bit7 = 最左像素
  * 一个 16x16 汉字占两个码: 0x80+2k (左半) 和 0x80+2k+1 (右半), 最多 64 个不同汉字

用法:
  python make_subtitle.py "欢迎使用 FPGA 多媒体播放器"            -> 当前目录 SUB.TXT / SUB.FNT
  python make_subtitle.py -f 字幕.txt -o E:\\                      -> 从文件读取, 直接写到 TF 卡
  python make_subtitle.py "..." --font C:\\Windows\\Fonts\\simhei.ttf --preview
"""
import os
import sys
import argparse

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("需要 Pillow: pip install Pillow")
    sys.exit(1)

TXT_MAX = 512
MAX_WIDE = 64
WIN_FONTS = os.path.join(os.environ.get("WINDIR", os.environ.get("SystemRoot", "")), "Fonts")
DEFAULT_FONTS = [
    r"C:\Windows\Fonts\simsun.ttc",
    r"C:\Windows\Fonts\simhei.ttf",
    r"C:\Windows\Fonts\msyh.ttc",
    "/System/Library/Fonts/PingFang.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
]


def find_font(path):
    cands = [path] if path else DEFAULT_FONTS
    for p in cands:
        if p and os.path.exists(p):
            return p
    return None


def render_glyph(font, ch, threshold):
    """把一个字符渲染成 16x16 位图, 返回 16 行 x 16 列的 0/1 列表"""
    img = Image.new("L", (16, 16), 0)
    d = ImageDraw.Draw(img)
    l, t, r, b = d.textbbox((0, 0), ch, font=font)
    x = (16 - (r - l)) // 2 - l
    y = (16 - (b - t)) // 2 - t
    d.text((x, y), ch, fill=255, font=font)
    return [[1 if img.getpixel((c, rr)) >= threshold else 0 for c in range(16)] for rr in range(16)]


def half_bytes(bits, half):
    out = bytearray()
    for row in bits:
        v = 0
        for c in range(8):
            v = (v << 1) | row[half * 8 + c]
        out.append(v)
    return out


def build(text, font_path, size, threshold, log=print):
    """返回 (codes, fnt, wide). 需要中文字体却找不到时抛出 ValueError"""
    codes = bytearray()
    fnt = bytearray(2048)
    wide = {}           # 字符 -> k
    font = None
    dropped = []

    for ch in text:
        o = ord(ch)
        if ch in "\r\n\t":
            ch, o = " ", 0x20
        if o < 0x20:
            continue
        if o < 0x80:
            need = 1
        else:
            need = 2
        if len(codes) + need > TXT_MAX:
            log(f"[提示] 超过 {TXT_MAX} 字节, 后续内容被截断")
            break
        if o < 0x80:
            codes.append(o)
            continue
        if ch not in wide:
            if len(wide) >= MAX_WIDE:
                dropped.append(ch)
                codes.append(ord("?"))
                continue
            if font is None:
                if not font_path:
                    raise ValueError("找不到中文字体, 请用 --font 指定")
                font = ImageFont.truetype(font_path, size)
            k = len(wide)
            wide[ch] = k
            bits = render_glyph(font, ch, threshold)
            fnt[(2 * k) * 16:(2 * k) * 16 + 16] = half_bytes(bits, 0)
            fnt[(2 * k + 1) * 16:(2 * k + 1) * 16 + 16] = half_bytes(bits, 1)
        k = wide[ch]
        codes.append(0x80 + 2 * k)
        codes.append(0x80 + 2 * k + 1)

    if dropped:
        log(f"[提示] 不同汉字超过 {MAX_WIDE} 个, 以下字符以 '?' 代替: {''.join(dropped)}")
    return codes, fnt, wide


def preview(codes, fnt):
    """在终端中用 # 打印前 40 个字符格"""
    cells = codes[:40]
    for r in range(16):
        line = ""
        for c in cells:
            if c >= 0x80:
                v = fnt[(c - 0x80) * 16 + r]
                line += "".join("#" if v & (0x80 >> i) else "." for i in range(8))
            else:
                line += (chr(c) if r == 7 else " ") + "       "
        print(line)


def main():
    ap = argparse.ArgumentParser(description="生成 FPGA 播放器滚动字幕 SUB.TXT / SUB.FNT")
    ap.add_argument("text", nargs="?", help="字幕内容 (UTF-8)")
    ap.add_argument("-f", "--file", help="从 UTF-8 文本文件读取字幕")
    ap.add_argument("-o", "--out", default=".", help="输出目录 (可直接指定 TF 卡根目录)")
    ap.add_argument("--font", help="TTF/TTC 字体路径 (默认宋体)")
    ap.add_argument("--size", type=int, default=16, help="字号 (像素, 默认 16)")
    ap.add_argument("--threshold", type=int, default=110, help="二值化阈值 0~255 (默认 110)")
    ap.add_argument("--preview", action="store_true", help="在终端预览字模")
    a = ap.parse_args()

    if a.file:
        with open(a.file, "r", encoding="utf-8-sig") as f:
            text = f.read().strip()
    elif a.text:
        text = a.text
    else:
        ap.print_help()
        sys.exit(1)

    try:
        codes, fnt, wide = build(text, find_font(a.font), a.size, a.threshold)
    except (ValueError, OSError) as e:
        print(f"[错误] {e}")
        sys.exit(1)
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "SUB.TXT"), "wb") as f:
        f.write(codes)
    print(f"SUB.TXT : {len(codes)} 字节")
    if wide:
        with open(os.path.join(a.out, "SUB.FNT"), "wb") as f:
            f.write(fnt)
        print(f"SUB.FNT : 2048 字节, {len(wide)} 个汉字")
    else:
        print("纯 ASCII 字幕, 不需要 SUB.FNT")
    if a.preview:
        preview(codes, fnt)


if __name__ == "__main__":
    main()
