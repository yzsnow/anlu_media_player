# -*- coding: utf-8 -*-
"""
生成应急报警画面的文字点阵 ROM (alarm_rom.v) 与位置参数 (alarm_rom.vh)。

报警画面由 RTL 按坐标实时生成 (红色脉动底 + 上下警示斜纹 + 两侧警告三角), 这里只提供文字点阵:
  AT  大标题        微软雅黑粗体 60 px
  A1  说明前半      微软雅黑粗体 30 px, 按触发来源选 3 种之一 (同宽同高连续存放, 每种 A1_SZ 字节):
                    0 "有危险发生" (KEY1 / 终端命令)  1 "检测到烟雾"  2 "检测到明火"
  AQ  说明后半      "· 请立即疏散", 与 A1 同一行, 两段合起来水平居中
  A2  英文          Arial Bold 22 px
  AL  "报警持续"    微软雅黑粗体 28 px,  其后接计时 mm:ss
  AD  数字 0~9 与 ':' (每个 16 px 宽的字格, 计时用)
  AH  操作提示      宋体 16 px
  AS  滚动应急字幕  微软雅黑粗体 20 px, 一整条 (宽 AS_PW 像素), 在 y SB_Y0~SB_Y1 的暗色字幕带内从右向左滚动
每项 1 bit/像素, 每字节 8 个像素 (bit7 在左), 按行连续存放; ROM 地址 13 bit, 数据 8 bit, 1 拍同步读.
坐标为 640x400 合成坐标 (输出放大 2 倍到 1280x800).

用法:  python gen_alarm_rom.py        (输出到 ../player/, 预览 alarm_preview.png)
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rom_util import write_rom      # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, '..', 'player')
F_YH = "C:/Windows/Fonts/msyhbd.ttc"
F_AR = "C:/Windows/Fonts/arialbd.ttf"
F_SS = "C:/Windows/Fonts/simsun.ttc"
W, H = 640, 400
ROM_BYTES = 8192

# (名称, 文字, 字体, 字号, 顶行 y)
ITEMS = [
    ("AT", "紧急警报",                                          F_YH, 60, 44),
    ("A2", "EMERGENCY  ALARM",                                  F_AR, 22, 180),
    ("AH", "拨码开关 SW1 拨回 0 解除报警",                     F_SS, 16, 292),
]
LABEL = ("AL", "报警持续", F_YH, 28, 224)
# 说明行: 前半按触发来源 (alm_src: 0 KEY1, 1 烟雾, 2 火焰, 3 终端命令 -> 用 0), 后半固定
CAUSE = (["有危险发生", "检测到烟雾", "检测到明火"], "· 请立即疏散", F_YH, 30, 132)
CAUSE_GAP = 8
# 滚动应急字幕 (预置疏散指引, 不占 OSD 字库)
SCROLL = ("AS", "请保持冷静  ·  沿安全出口指示有序撤离  ·  切勿乘坐电梯  ·  听从现场工作人员指挥",
          F_YH, 20)
SB_Y0, SB_Y1 = 326, 362                       # 字幕带 (暗底, 上下黄线), 文字在带内竖直居中
DIGITS = "0123456789:"
DIG_FONT, DIG_SIZE, DIG_CW = F_AR, 30, 16     # 数字字格 16 px 宽
GAP = 12                                      # 标签与计时之间的间距


def render(text, font, size, thr=110):
    """灰度渲染后按阈值二值化 (大字号比直接 1 bit 渲染的笔画更匀称), 返回裁掉空白的 0/1 图"""
    f = ImageFont.truetype(font, size)
    img = Image.new('L', (size * (len(text) + 2), size * 2), 0)
    ImageDraw.Draw(img).text((size // 2, size // 2), text, font=f, fill=255)
    if font == F_SS:        # 16 px 宋体用点阵直出, 与 OSD 字库风格一致
        img = Image.new('1', img.size, 0)
        d = ImageDraw.Draw(img)
        d.fontmode = '1'
        d.text((size // 2, size // 2), text, font=f, fill=1)
        img = img.convert('L').point(lambda v: 255 if v else 0)
    b = img.point(lambda v: 255 if v >= thr else 0)
    return b


def crop(img, box):
    return img.crop(box)


def to_bytes(img, wb):
    """img 宽度 <= wb*8, 每行 wb 字节"""
    out = []
    for y in range(img.height):
        for bx in range(wb):
            v = 0
            for k in range(8):
                x = bx * 8 + k
                if x < img.width and img.getpixel((x, y)):
                    v |= 0x80 >> k
            out.append(v)
    return out


def main():
    rom = []
    params = []
    placed = []                 # (name, x0, y0, img) 预览用

    def add(name, img, x0, y0, wb=None):
        wb = wb or (img.width + 7) // 8
        base = len(rom)
        rom.extend(to_bytes(img, wb))
        params.append((name, x0, y0, wb, img.height, base))
        placed.append((x0, y0, img))
        return base

    for name, text, font, size, y0 in ITEMS:
        img = render(text, font, size)
        img = crop(img, img.getbbox())
        x0 = W // 2 - img.width // 2
        add(name, img, x0, y0)

    # 说明行: 各段按同一竖直范围裁剪 (基线对齐); 前半 3 种居中放进同宽字格, 连续存放
    texts, tail, font, size, y0 = CAUSE
    imgs = [render(t, font, size) for t in texts + [tail]]
    top = min(i.getbbox()[1] for i in imgs)
    bot = max(i.getbbox()[3] for i in imgs)
    crops = [i.crop((i.getbbox()[0], top, i.getbbox()[2], bot)) for i in imgs]
    cwb = (max(c.width for c in crops[:-1]) + 7) // 8
    slot = cwb * 8
    cx0 = W // 2 - (slot + CAUSE_GAP + crops[-1].width) // 2
    cbase = len(rom)
    for c in crops[:-1]:
        cell = Image.new('L', (slot, bot - top), 0)
        cell.paste(c, ((slot - c.width) // 2, 0))
        rom.extend(to_bytes(cell, cwb))
    params.append(("A1", cx0, y0, cwb, bot - top, cbase))
    placed.append((cx0, y0, cell))              # 预览显示最后一种 (明火)
    a1_sz = cwb * (bot - top)
    add("AQ", crops[-1], cx0 + slot + CAUSE_GAP, y0)

    # 标签 + 数字: 竖直方向按各自墨迹居中到同一中线
    name, text, font, size, y0 = LABEL
    lab = render(text, font, size)
    lab = crop(lab, lab.getbbox())
    digs = [render(c, DIG_FONT, DIG_SIZE) for c in DIGITS]
    box = [min(d.getbbox()[1] for d in digs), max(d.getbbox()[3] for d in digs)]
    dh = box[1] - box[0]
    total = lab.width + GAP + 5 * DIG_CW
    lx = W // 2 - total // 2
    dx = lx + lab.width + GAP
    dy = y0 + (lab.height - dh) // 2
    add(name, lab, lx, y0)
    dbase = len(rom)
    cells = []
    for c, d in zip(DIGITS, digs):
        bb = d.getbbox()
        g = d.crop((bb[0], box[0], bb[2], box[1]))
        assert g.width <= DIG_CW, (c, g.width)
        cell = Image.new('L', (DIG_CW, dh), 0)
        cell.paste(g, ((DIG_CW - g.width) // 2, 0))
        rom.extend(to_bytes(cell, DIG_CW // 8))
        cells.append(cell)
    params.append(("AD", dx, dy, DIG_CW // 8, dh, dbase))

    # 滚动字幕: 整条存入 ROM, x0 字段记录像素宽度 (滚动周期 = 宽度 + 640)
    name, text, font, size = SCROLL
    st = render(text, font, size)
    st = crop(st, st.getbbox())
    sy = (SB_Y0 + SB_Y1) // 2 - st.height // 2
    add(name, st, st.width, sy)
    placed[-1] = (W - 40 - st.width // 3, sy, st)       # 预览: 显示滚到中途的样子
    assert len(rom) <= ROM_BYTES, len(rom)

    # 警告三角: 标题左右各一个, 与标题竖直居中
    at = params[0]
    tri_h = 56
    tri_y = at[2] + at[4] // 2 - tri_h // 2
    tri_lx = at[1] - 56
    tri_rx = at[1] + at[3] * 8 + 56

    # ---- ROM ----
    # EG_LOGIC_BRAM + .mif (case 写法曾被综合成 3000+ LUT; initial 数组 TD 综合为无驱动, 上板全 0)
    write_rom(OUT_DIR, 'alarm_rom', rom, 13, 'gen_alarm_rom.py 应急报警画面文字点阵, bit7 为最左像素')
    with open(os.path.join(OUT_DIR, 'alarm_rom.vh'), 'w', encoding='utf-8') as f:
        f.write("// 自动生成: 应急报警画面文字位置 (python/gen_alarm_rom.py)\n")
        f.write("// 每项: 左上角 X/Y, 每行字节数 WB, 行数 H, ROM 起始地址 B\n")
        for name, x0, y0, wb, h, base in params:
            f.write("localparam [9:0]  %s_X = 10'd%d;\n" % (name, x0))
            f.write("localparam [8:0]  %s_Y = 9'd%d;\n" % (name, y0))
            f.write("localparam [9:0]  %s_WB = 10'd%d;\n" % (name, wb))
            f.write("localparam [8:0]  %s_H = 9'd%d;\n" % (name, h))
            f.write("localparam [12:0] %s_B = 13'd%d;\n" % (name, base))
        f.write("localparam [12:0] A1_SZ  = 13'd%d;          // 说明前半每种的字节数\n" % a1_sz)
        f.write("localparam [12:0] AD_GSZ = 13'd%d;          // 每个数字字格的字节数\n" % (DIG_CW // 8 * dh))
        f.write("localparam [8:0]  SB_Y0  = 9'd%d;           // 滚动字幕带\n" % SB_Y0)
        f.write("localparam [8:0]  SB_Y1  = 9'd%d;\n" % SB_Y1)
        f.write("localparam [8:0]  TRI_Y  = 9'd%d;\n" % tri_y)
        f.write("localparam [9:0]  TRI_LX = 10'd%d;\n" % tri_lx)
        f.write("localparam [9:0]  TRI_RX = 10'd%d;\n" % tri_rx)

    # ---- 预览 (仅文字, 白底黑字) ----
    pv = Image.new('L', (W, H), 40)
    pv.paste(10, (0, SB_Y0, W, SB_Y1))
    for x0, y0, img in placed:
        pv.paste(255, (x0, y0), img.point(lambda v: 255 if v else 0).convert('1'))
    for i, c in enumerate("12:34"):
        cell = cells[DIGITS.index(c)]
        pv.paste(255, (dx + i * DIG_CW, dy), cell.point(lambda v: 255 if v else 0).convert('1'))
    pv.save(os.path.join(HERE, 'alarm_preview.png'))
    for p in params:
        print("%-3s x %3d y %3d  %2d B x %2d rows  base %4d" % p)
    print("tri y %d lx %d rx %d, rom %d bytes" % (tri_y, tri_lx, tri_rx, len(rom)))


if __name__ == '__main__':
    main()
