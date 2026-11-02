# -*- coding: utf-8 -*-
"""
生成 OSD 字库 ROM (osd_font_rom.v) 与字符串 ROM (osd_str_rom.v)。

字符编码 (9 bit):
  0x000~0x07F : 图标 + ASCII (8x16, 宋体点阵加粗)
  0x080~0x0FF : 用户字库 (运行时从 TF 卡 SUB.FNT 加载, 不在本 ROM 中)
  0x100~0x1FF : 内置汉字, 每个汉字 16x16 拆成左右两个 8x16 半字 (偶数=左半, 奇数=右半)
  0x009~0x01E : 超出 128 个的汉字 (最多 11 个, 同样左右两个半字), 占用未用的控制码

用法:  python gen_osd_rom.py        (输出到 ../player/)
"""
import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, '..', 'player')
FONT_CN = "C:/Windows/Fonts/simsun.ttc"

# ---------------- 硬件中用到的字符串 (sid 与 RTL 中 localparam 一一对应) ----------------
STRINGS = [
    ("S_TITLE",    "智能多媒体信息展示终端系统"),
    ("S_INFO",     "HX4S20C  EG4S20BG256  HDMI 1.4b  1280x800@60Hz  48kHz"),
    ("S_ST_INIT",  "正在初始化TF卡..."),
    ("S_ST_SCAN",  "正在扫描FAT32文件系统..."),
    ("S_ST_LOAD",  "正在加载图片: "),
    ("S_ST_NOCARD","未检测到TF卡, 正在重试..."),
    ("S_ST_FSERR", "文件系统错误, 请格式化为FAT32"),
    ("S_ST_NOIMG", "未找到图片 (24/32位 BMP)"),
    ("S_HINT1",    "KEY1: 报警触发  KEY2: 自动轮播/长按切换特效  KEY3: 下一张/长按上一张"),
    ("S_HINT2",    "拨码开关 SW1: 报警  SW2: 音频频谱  SW3: 参数调节  SW4: 音源 (0: WAV / 1: 音阶)"),
    ("S_EFF0",     "淡入淡出"),
    ("S_EFF1",     "横向擦除"),
    ("S_EFF2",     "纵向擦除"),
    ("S_EFF3",     "圆形展开"),
    ("S_EFF4",     "百叶窗  "),
    ("S_EFF5",     "马赛克  "),
    ("S_EFF6",     "随机溶解"),
    ("S_EFF7",     "黑场过渡"),
    ("S_EFF_AUTO", "特效轮换"),
    ("S_AUD_WAV",  "WAV音乐 "),
    ("S_AUD_TONE", "音阶测试"),
    ("S_MARQUEE",  "欢迎使用智能多媒体信息展示终端系统 -- 支持多图片轮播、八种转场特效、OSD字幕叠加与WAV音频播放 -- 根目录放入SUB.TXT可自定义字幕"),
    ("S_LOADING",  "加载中..."),
    ("S_RATES",    "  --   8kHz 11kHz 16kHz 22kHz 32kHz 44kHz 48kHz"),
    ("S_BADIMG",   "图片格式错误"),
    ("S_NOWAV",    "无文件"),
    # 参数调节菜单 (SW3): 标题 / 7 个菜单项 (每项 8 列, 第 0~55 列) + 复位行说明 (第 56 列起)
    #                     + 画面模式名 (第 72 列起, 每个 8 列) / 按键说明
    ("S_MENU_T",   "显示参数调节 (SW3)"),
    ("S_MENU_IT",  "模式    亮度    对比度  色温    伽马    音量    复位    按 KEY2 复位    "
                   "正常    日间    夜间    护眼    "),
    ("S_MENU_H",   "KEY3: 下一项/长按上一项  KEY2: +1/长按 -1"),
]
STR_COLS = 128

ICONS = {
    0x01: [  # play
        "........", "........", "........", ".#......", ".##.....", ".###....", ".####...", ".#####..",
        ".######.", ".#####..", ".####...", ".###....", ".##.....", ".#......", "........", "........"],
    0x02: [  # pause
        "........", "........", "........", ".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##..##.",
        ".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##..##.", "........", "........"],
    0x03: [  # speaker
        "........", "........", "........", "....#...", "...##...", "..###...", "####.#..", "###..#.#",
        "###..#.#", "####.#..", "..###...", "...##...", "....#...", "........", "........", "........"],
    0x04: [  # note
        "........", "........", "...####.", "...#..#.", "...####.", "...#..#.", "...#..#.", "...#..#.",
        "...#..#.", ".###.##.", "########", "###.###.", ".#...#..", "........", "........", "........"],
    0x05: ["########"] * 16,  # full block
    0x06: [  # star
        "........", "........", "........", "...##...", "...##...", "########", ".######.", "..####..",
        "..####..", ".##..##.", ".#....#.", "........", "........", "........", "........", "........"],
    0x07: [  # 数值条: 实格
        "........", "........", "........", "#######.", "#######.", "#######.", "#######.", "#######.",
        "#######.", "#######.", "#######.", "#######.", "#######.", "........", "........", "........"],
    0x08: [  # 数值条: 空格
        "........", "........", "........", "#######.", "#.....#.", "#.....#.", "#.....#.", "#.....#.",
        "#.....#.", "#.....#.", "#.....#.", "#.....#.", "#######.", "........", "........", "........"],
}


def rows_of(img, x0, w=8):
    out = []
    for y in range(16):
        v = 0
        for x in range(w):
            if img.getpixel((x0 + x, y)):
                v |= 1 << (w - 1 - x)
        out.append(v)
    return out


def render(ch, width):
    font = ImageFont.truetype(FONT_CN, 16)
    img = Image.new('1', (width, 16), 0)
    d = ImageDraw.Draw(img)
    d.fontmode = '1'
    d.text((0, 0), ch, font=font, fill=1)
    return img


def ascii_glyph(c):
    r = rows_of(render(chr(c), 8), 0)
    # 加粗: 每行与右移一位相或, 在电视上更清晰;
    # 但不填补 1 像素宽的笔画间隙 (否则 M W @ 等宽字符会糊成实心块)
    return [(v | ((v >> 1) & ~(v << 1))) & 0xFF for v in r]


def cn_glyph(ch):
    img = render(ch, 16)
    return rows_of(img, 0), rows_of(img, 8)


def chinese_table():
    cs = []
    for _, s in STRINGS:
        for c in s:
            if ord(c) > 127 and c not in cs:
                cs.append(c)
    assert len(cs) <= 128 + len(EXTRA_CODES), len(cs)
    return cs


# 第 129 个起的汉字放到未用的控制码 (0x07/0x08 为数值条, 0x09 起空闲, 0x20 为空格)
EXTRA_CODES = [0x09 + 2 * i for i in range(11)]


def cn_code(k):
    """第 k 个汉字的左半字编码 (右半字 = 左半字 + 1)"""
    return 0x100 + 2 * k if k < 128 else EXTRA_CODES[k - 128]


def encode(s, cs):
    codes = []
    for c in s:
        o = ord(c)
        if o < 128:
            codes.append(o)
        else:
            k = cn_code(cs.index(c))
            codes += [k, k + 1]
    return codes


def main():
    cs = chinese_table()
    font = {}
    for code, pat in ICONS.items():
        font[code] = [int(r.replace('#', '1').replace('.', '0'), 2) for r in pat]
    for c in range(0x21, 0x7F):
        font[c] = ascii_glyph(c)
    for k, ch in enumerate(cs):
        l, r = cn_glyph(ch)
        font[cn_code(k)] = l
        font[cn_code(k) + 1] = r
    print(f"汉字 {len(cs)} 个 (内置区 128, 扩展区 {max(0, len(cs) - 128)}/{len(EXTRA_CODES)}):",
          ''.join(cs[128:]))

    # ---- font ROM ----
    lines = []
    for code in sorted(font):
        for row, v in enumerate(font[code]):
            if v:
                lines.append("        13'h%04x: q <= 8'h%02x;" % ((code << 4) | row, v))
    with open(os.path.join(OUT_DIR, 'osd_font_rom.v'), 'w', encoding='utf-8') as f:
        f.write("// 自动生成, 请勿手改: python/gen_osd_rom.py\n")
        f.write("// 8x16 点阵字库 ROM, addr = {code[8:0], row[3:0]}, 1 拍同步读, bit7 为最左像素\n")
        f.write("module osd_font_rom(\n    input             clk,\n    input      [12:0] addr,\n    output reg [7:0]  q\n);\n")
        f.write("always @(posedge clk) begin\n    case (addr)\n")
        f.write('\n'.join(lines))
        f.write("\n        default: q <= 8'h00;\n    endcase\nend\nendmodule\n")

    # ---- string ROM ----
    lines = []
    params = []
    for sid, (name, s) in enumerate(STRINGS):
        codes = encode(s, cs)
        assert len(codes) <= STR_COLS, (name, len(codes))
        params.append("localparam [4:0] %-12s = 5'd%d;" % (name, sid))
        params.append("localparam [7:0] %-12s = 8'd%d;" % ('L' + name[1:], len(codes)))
        for i, c in enumerate(codes):
            if c != 0x20:
                lines.append("        12'h%03x: q <= 9'h%03x;" % ((sid << 7) | i, c))
    with open(os.path.join(OUT_DIR, 'osd_str_rom.v'), 'w', encoding='utf-8') as f:
        f.write("// 自动生成, 请勿手改: python/gen_osd_rom.py\n")
        f.write("// 字符串 ROM, addr = {sid[4:0], col[6:0]}, 输出 9 bit 字符码, 1 拍同步读\n")
        f.write("module osd_str_rom(\n    input             clk,\n    input      [11:0] addr,\n    output reg [8:0]  q\n);\n")
        f.write("always @(posedge clk) begin\n    case (addr)\n")
        f.write('\n'.join(lines))
        f.write("\n        default: q <= 9'h020;\n    endcase\nend\nendmodule\n")
    with open(os.path.join(OUT_DIR, 'osd_str_ids.vh'), 'w', encoding='utf-8') as f:
        f.write("// 自动生成: 字符串编号 (与 osd_str_rom.v 对应)\n")
        f.write('\n'.join(params) + '\n')
        f.write("localparam [7:0] S_MARQUEE_LEN = 8'd%d;\n" % len(encode(STRINGS[[n for n, _ in STRINGS].index('S_MARQUEE')][1], cs)))

    # 预览
    with open(os.path.join(HERE, 'osd_font_preview.txt'), 'w', encoding='utf-8') as f:
        for code in sorted(font):
            f.write('code %03x\n' % code)
            for v in font[code]:
                f.write(format(v, '08b').replace('1', '#').replace('0', '.') + '\n')
    print('chinese glyphs:', len(cs))
    print(''.join(cs))


if __name__ == '__main__':
    main()
