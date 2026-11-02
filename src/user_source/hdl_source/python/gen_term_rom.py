# -*- coding: utf-8 -*-
"""
第二屏运维终端 (HDMI1, 1024x600) 的字库 / 界面模板 / 微程序生成器, 同时是硬件行为的 Python 参考模型.

  屏幕: 128 列 x 37 行字符, 每格 8x16 (最下 8 行像素为状态栏底色)
  显存: 每格 {字符码[8:0], 前景色[2:0]}, 上电初值 = 界面模板 (边框/面板标题/标签全部预置, 不占逻辑)
  字符码: 0x00~0x1F 制表符/图标, 0x20~0x7E ASCII, 0x80 起汉字 (16x16 拆成左右两个半字)
  微程序 ROM (9 bit/字): 字符串 (状态枚举 / 日志消息 / 命令名) + 四段程序:
      P_STATUS 循环刷新状态字段,  P_LOG 写一条日志,  P_CMDW 命令行写入所选命令名,  P_CMDCLR 清命令行
  指令 (与 player/term_top.v 一一对应):
      0x000~0x17F  字符: 写到当前位置, 列 +1
      0x180+s  STR  s, d     写字符串: 地址 = (d[6:0] + 值) << (4 + d[8:7]), 遇 END 返回
      0x1A0+s  DEC  s, f     写十进制: f[1:0] 位数, f[2] 前导补 0 (否则补空格), f[3] 去掉前导 (变长)
      0x1C0+s  BAR  s        16 格数值条: 第 k 格 k < 值 为实格 (当前色) 否则空格 (色 0)
      0x1E0 END  0x1E1 HALT  0x1E2 TIME (hh:mm:ss)  0x1E3 PAD c (补空格到第 c 列)
      0x1E4 SETPOS r, c      0x1E5 SETPOS_LOG c (行 = 日志环当前写行)   0x1F0+k SETCOL k
用法:  python gen_term_rom.py   (输出到 ../player/, 预览图 term_preview.png)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rom_util import write_rom, write_ram          # noqa: E402
from gen_osd_rom import ascii_glyph, cn_glyph       # noqa: E402

OUT_DIR = os.path.join(HERE, '..', 'player')
COLS, ROWS = 128, 37
NCELL = COLS * ROWS                 # 4736
LOG_TOP, LOG_N = 12, 15             # 日志环: 第 12~26 行
CMD_ROW, CMD_C0, CMD_MAX = 29, 18, 126
PROG_DEPTH = 2048

# ---------------- 调色板 ----------------
PAL = [0x4A5868,   # 0 暗灰 (空格 / 无)
       0xE6EDF3,   # 1 白 (数值)
       0x4DD0E1,   # 2 青 (边框 / 标签)
       0x69F0AE,   # 3 绿 (正常)
       0xFFD740,   # 4 黄 (警告)
       0xFF5252,   # 5 红 (错误 / 报警)
       0x9AA8B6,   # 6 浅灰 (时间戳 / 说明)
       0x82B1FF]   # 7 淡蓝 (强调)
BG_MAIN, BG_TITLE, BG_SBAR, CURSOR = 0x0B1622, 0x0D47A1, 0x1C2833, 0xE6EDF3
C_DIM, C_WHITE, C_CYAN, C_GREEN, C_YELLOW, C_RED, C_GREY, C_BLUE = range(8)

# ---------------- 数据源 (与 term_top.v src_val 一致) ----------------
SRC = ['ST', 'CNT', 'WAV', 'TXT', 'FNT', 'ALM', 'SW1', 'SW2', 'SW3', 'SW4', 'CUR', 'FSM',
       'PROG16', 'PCT', 'EFF', 'AUTO', 'WAVE', 'MENU', 'AMODE', 'PMODE',
       'BRI', 'CON', 'TEMP', 'GAM', 'VOL', 'VU', 'RATE', 'CMDSEL', 'LOGN', 'ESUF', 'EMSG', 'EARG']
S = {n: i for i, n in enumerate(SRC)}

# ---------------- 字符集 ----------------
GFX = {'─': 0x01, '│': 0x02, '┌': 0x03, '┐': 0x04, '└': 0x05, '┘': 0x06, '├': 0x07, '┤': 0x08,
       '■': 0x0B, '□': 0x0C, '◆': 0x0D, '●': 0x0E, '▶': 0x0F, '·': 0x10, '▸': 0x11}
BAR_FULL, BAR_EMPTY = 0x0B, 0x0C


def gfx_glyph(code):
    g = [[0] * 8 for _ in range(16)]

    def h(x0, x1, y=8):
        for x in range(x0, x1 + 1):
            g[y][x] = 1

    def v(y0, y1, x=3):
        for y in range(y0, y1 + 1):
            g[y][x] = 1
    if code == 0x01: h(0, 7)
    elif code == 0x02: v(0, 15)
    elif code == 0x03: h(3, 7); v(8, 15)
    elif code == 0x04: h(0, 3); v(8, 15)
    elif code == 0x05: h(3, 7); v(0, 8)
    elif code == 0x06: h(0, 3); v(0, 8)
    elif code == 0x07: v(0, 15); h(3, 7)
    elif code == 0x08: v(0, 15); h(0, 3)
    elif code == 0x0B:
        for y in range(3, 13):
            h(0, 6, y)
    elif code == 0x0C:
        h(0, 6, 3); h(0, 6, 12); v(3, 12, 0); v(3, 12, 6)
    elif code == 0x0D:
        for i, w in enumerate([0, 1, 2, 3, 2, 1, 0]):
            h(3 - w, 3 + w, 5 + i)
    elif code == 0x0E:
        for i, (a, b) in enumerate([(2, 4), (1, 5), (0, 6), (0, 6), (0, 6), (1, 5), (2, 4)]):
            h(a, b, 5 + i)
    elif code == 0x0F:
        for i, w in enumerate([0, 1, 2, 3, 4, 3, 2, 1, 0]):
            h(1, 1 + w, 4 + i)
    elif code == 0x10:
        h(3, 4, 7); h(3, 4, 8)
    elif code == 0x11:
        for i, w in enumerate([0, 1, 2, 1, 0]):
            h(2, 2 + w, 6 + i)
    return [sum(b << (7 - x) for x, b in enumerate(r)) for r in g]


class Charset:
    def __init__(self):
        self.cn = []

    def code(self, ch):
        if ch in GFX:
            return [GFX[ch]]
        o = ord(ch)
        if o < 128:
            return [o]
        if ch not in self.cn:
            self.cn.append(ch)
        k = 0x80 + 2 * self.cn.index(ch)
        return [k, k + 1]

    def width(self, s):
        return sum(len(self.code(c)) for c in strip_col(s))

    def font(self):
        n = 0x80 + 2 * len(self.cn)
        rom = []
        for c in range(n):
            if c in GFX.values():
                rom += gfx_glyph(c)
            elif 0x21 <= c < 0x7F:
                rom += ascii_glyph(c)
            elif c >= 0x80:
                l, r = cn_glyph(self.cn[(c - 0x80) // 2])
                rom += l if c % 2 == 0 else r
            else:
                rom += [0] * 16
        return rom


CS = Charset()


def strip_col(s):
    out, i = '', 0
    while i < len(s):
        if s[i] == '{':
            i = s.index('}', i) + 1
        else:
            out += s[i]
            i += 1
    return out


def enc_words(s):
    """带 {k} 颜色标记的字符串 -> 微程序字 (字符码 / SETCOL)"""
    w, i = [], 0
    while i < len(s):
        if s[i] == '{':
            j = s.index('}', i)
            w.append(0x1F0 + int(s[i + 1:j]))
            i = j + 1
        else:
            cc = CS.code(s[i])
            # 微程序字 0x180 起为指令: 字符串中的汉字编号必须 < 128 (先分配的字符串先编号)
            assert cc[-1] < 0x180, ('微程序字符串中的汉字超过 128 个', s[i])
            w += cc
            i += 1
    return w


# ---------------- 微程序 ----------------
OP_STR, OP_DEC, OP_BAR = 0x180, 0x1A0, 0x1C0
END, HALT, TIME, PAD, SETPOS, SETPOS_LOG, SETCOL = 0x1E0, 0x1E1, 0x1E2, 0x1E3, 0x1E4, 0x1E5, 0x1F0

# 枚举表: 每表各项补齐到同一显示宽度 (短的覆盖长的)
ENUMS = {
    'ST':    ['{4}初始化中', '{4}扫描目录中', '{3}就绪', '{5}未插卡', '{5}文件系统错误', '{4}无图片'],
    'YN':    ['{0}无', '{3}有'],
    'TXT':   ['{0}无', '{3}SUB.TXT'],
    'FNT':   ['{0}无', '{3}SUB.FNT'],
    'ALM':   ['{0}未布防', '{3}已布防 (待命)', '{5}报警中 !!', '{4}MQ-2 未就绪'],
    'FSM':   ['{3}1 空闲', '{4}2 搜索BMP', '{4}3 写入SDRAM', '{7}4 OSD叠加', '{5}E 错误'],
    'EFF':   ['{1}淡入淡出', '{1}横向擦除', '{1}纵向擦除', '{1}圆形展开', '{1}百叶窗',
              '{1}马赛克', '{1}随机溶解', '{1}黑场过渡', '{7}自动轮换'],      # eff_sel 0~8
    'ONOFF': ['{0}关', '{3}开'],
    'AMODE': ['{1}WAV 音乐', '{1}音阶测试', '{0}--', '{5}警笛'],
    'PMODE': ['{1}正常', '{4}日间', '{7}夜间', '{3}护眼'],
    'RATE':  ['{0}--', '{1}8kHz', '{1}11kHz', '{1}16kHz', '{1}22kHz', '{1}32kHz', '{1}44kHz', '{1}48kHz'],
}
# 命令名 (term_top.v 命令号 1~9; 带参数的命令末尾有空格), 命令行与 CMD 日志共用, 不补齐
CMDS = ['', '{1}show ', '{1}next', '{1}prev', '{1}mode ', '{1}bright ', '{1}vol ', '{1}eff ', '{1}auto ', '{1}alarm']

# 日志事件 (与 term_top.v 事件编号一致): (名称, 消息列表, 后缀枚举表)
#   消息列表多于 1 条时按事件值选择; 后缀表非空时消息后再接 枚举表[值] (与状态面板同一字符串)
EVENTS = [
    ('BOOT',  ['{3}INFO  {1}系统启动完成, 终端上线'], None),
    ('ST',    ['{6}INFO  {1}TF 卡初始化...', '{6}INFO  {1}扫描 FAT32 目录...',
               '{3}INFO  {1}TF 卡就绪, 图片数: ', '{5}ERROR {5}未检测到 TF 卡',
               '{5}ERROR {5}文件系统错误', '{4}WARN  {4}未找到 BMP 图片'], None),
    ('IMG',   ['{6}INFO  {1}显示图片 #'], None),
    ('MENU',  ['{6}INFO  {1}参数菜单 (SW3): '], 'ONOFF'),
    ('PMODE', ['{6}INFO  {1}画面模式: '], 'PMODE'),
    ('ARM',   ['{4}WARN  {1}报警撤防 (SW1=0)', '{3}INFO  {1}报警布防 (SW1=1)'], None),
    ('ALM',   ['{3}INFO  {3}报警解除, 恢复播放', '{5}ALARM {5}!! 应急报警触发 !!',          # KEY1 / 终端命令
               '{5}ALARM {5}!! 烟雾报警 !! MQ-2', '{5}ALARM {5}!! 火警 !! FLAME'], None),       # 烟雾 / 火焰传感器
    ('WAVE',  ['{6}INFO  {1}音频频谱 (SW2): '], 'ONOFF'),
    ('AUTO',  ['{6}INFO  {1}自动轮播: '], 'ONOFF'),
    ('EFF',   ['{6}INFO  {1}转场特效: '], 'EFF'),
    ('AMODE', ['{6}INFO  {1}音源: '], 'AMODE'),
    ('WAV',   ['{3}INFO  {1}WAV 音频已加载'], None),
    ('BAD',   ['{4}WARN  {4}图片格式错误, 已跳过'], None),
    ('CMD',   ['{6}CMD   {7}执行 '], 'CMDS'),
    ('CMDERR', ['{4}WARN  {4}未选命令, 请按 A/B', '{4}WARN  {4}参数错误', '{4}WARN  {4}报警未布防 (SW1=0)',
                '{5}WARN  {5}报警中, 命令无效', '{4}WARN  {4}TF 卡未就绪'], None),
]
EV = {e[0]: i for i, e in enumerate(EVENTS)}


class Rom:
    def __init__(self):
        self.w = []
        self.enum_d = {}          # 表名 -> STR 数据字
        self.ev_d = []            # 事件 -> STR 数据字

    def alloc(self, strings, pad=True):
        """分配一组等长槽位, 返回 STR 数据字 {sz, idx}"""
        wd = max(CS.width(s) for s in strings)
        words = []
        for s in strings:
            ww = enc_words(s)
            if pad:
                ww += [0x20] * (wd - CS.width(s))
            words.append(ww + [END])
        n = max(len(x) for x in words)
        sz = 0 if n <= 16 else 1 if n <= 32 else 2
        slot = 16 << sz
        while len(self.w) % slot:
            self.w.append(0)
        idx = len(self.w) // slot
        assert idx + len(strings) <= 128, idx
        for x in words:
            self.w += x + [0] * (slot - len(x))
        return (sz << 7) | idx


ROM = Rom()
# 槽号只有 7 位: 16 字槽位 (枚举) 放低地址, 32/64 字槽位 (日志消息, 不补齐, 由 PAD 补到行尾) 放后面
_ev = {}
for name in sorted(ENUMS, key=lambda k: max(len(enc_words(m)) for m in ENUMS[k])):
    ROM.enum_d[name] = ROM.alloc(ENUMS[name])
ROM.enum_d['CMDS'] = ROM.alloc(CMDS, pad=False)
for name, msgs, _ in sorted(EVENTS, key=lambda e: max(len(enc_words(m)) for m in e[1])):
    _ev[name] = ROM.alloc(msgs, pad=False)
# 每个事件: (消息数据字, 按值选消息, 后缀数据字, 有后缀)
ROM.ev_d = [(_ev[e[0]], len(e[1]) > 1, ROM.enum_d[e[2]] if e[2] else 0, e[2] is not None) for e in EVENTS]

# ---------------- 界面模板 ----------------
code = [[0x20] * COLS for _ in range(ROWS)]
color = [[C_WHITE] * COLS for _ in range(ROWS)]


def put(r, c, s, col=C_WHITE):
    cur = col
    i = 0
    while i < len(s):
        if s[i] == '{':
            j = s.index('}', i)
            cur = int(s[i + 1:j])
            i = j + 1
            continue
        for k in CS.code(s[i]):
            assert k < 0x200, ('汉字超过 192 个 (字符码 9 位)', s[i])
            code[r][c], color[r][c] = k, cur
            c += 1
        i += 1
    return c


def box(r0, c0, r1, c1, title, col=C_CYAN):
    put(r0, c0, '┌' + '─' * (c1 - c0 - 1) + '┐', col)
    put(r1, c0, '└' + '─' * (c1 - c0 - 1) + '┘', col)
    for r in range(r0 + 1, r1):
        put(r, c0, '│', col)
        put(r, c1, '│', col)
    put(r0, c0 + 2, ' ' + title + ' ', C_WHITE)


prog = []


def pos(r, c):
    assert 0 <= r < ROWS and 0 <= c < COLS
    prog.extend([SETPOS, r, c])


def f_str(r, c, src, table, colr=C_WHITE):
    pos(r, c)
    prog.extend([SETCOL + colr, OP_STR + S[src], ROM.enum_d[table]])


def f_dec(r, c, src, n, zero=False, trim=False, colr=C_WHITE):
    pos(r, c)
    prog.extend([SETCOL + colr, OP_DEC + S[src], n | (4 if zero else 0) | (8 if trim else 0)])


def f_bar(r, c, src, colr=C_GREEN):
    pos(r, c)
    prog.extend([SETCOL + colr, OP_BAR + S[src]])


# 标题栏 (第 0 行, 蓝底)
put(0, 1, '◆ 多媒体信息发布系统 · 运维终端', C_WHITE)
put(0, 40, 'HX4S20C · EG4S20BG256 · HDMI1 1024x600@60Hz', C_BLUE)
put(0, 104, '运行时间', C_WHITE)
pos(0, 113)
prog.extend([SETCOL + C_WHITE, TIME])

# 三个状态面板 (第 2~10 行)
A, B, C = 0, 43, 86
box(2, A, 10, A + 41, '存储与系统')
box(2, B, 10, B + 41, '播放状态')
box(2, C, 10, C + 41, '画面与音频')
LA = [(3, 'TF 卡'), (4, '图片数量'), (5, 'WAV 音频'), (6, '字幕文件'), (7, '字库文件'),
      (8, '报警状态'), (9, '拨码开关')]
for r, s in LA:
    put(r, A + 2, s, C_CYAN)
f_str(3, A + 12, 'ST', 'ST')
f_dec(4, A + 12, 'CNT', 2)
put(4, A + 15, '张', C_WHITE)
f_str(5, A + 12, 'WAV', 'YN')
put(5, A + 18, '采样率', C_CYAN)
f_str(5, A + 25, 'RATE', 'RATE')
f_str(6, A + 12, 'TXT', 'TXT')
f_str(7, A + 12, 'FNT', 'FNT')
f_str(8, A + 12, 'ALM', 'ALM')
for i in range(4):
    put(9, A + 12 + 6 * i, 'SW%d:' % (i + 1), C_GREY)
    f_dec(9, A + 16 + 6 * i, 'SW%d' % (i + 1), 1, colr=C_WHITE)

LB = [(3, '当前图片'), (4, '状态机'), (5, '加载进度'), (6, '转场特效'), (7, '自动轮播'),
      (8, '频谱显示'), (9, '参数菜单')]
for r, s in LB:
    put(r, B + 2, s, C_CYAN)
f_dec(3, B + 12, 'CUR', 2)
put(3, B + 15, '/', C_GREY)
f_dec(3, B + 17, 'CNT', 2)
f_str(4, B + 12, 'FSM', 'FSM')
f_bar(5, B + 12, 'PROG16')
f_dec(5, B + 29, 'PCT', 3)
put(5, B + 32, '%', C_WHITE)
f_str(6, B + 12, 'EFF', 'EFF')
f_str(7, B + 12, 'AUTO', 'ONOFF')
f_str(8, B + 12, 'WAVE', 'ONOFF')
f_str(9, B + 12, 'MENU', 'ONOFF')

LC = [(3, '画面模式'), (4, '亮度'), (5, '对比度'), (6, '色温'), (7, '伽马'), (8, '音量'), (9, '音源')]
for r, s in LC:
    put(r, C + 2, s, C_CYAN)
f_str(3, C + 12, 'PMODE', 'PMODE')
for r, src in [(4, 'BRI'), (5, 'CON'), (6, 'TEMP'), (7, 'GAM'), (8, 'VOL')]:
    f_bar(r, C + 12, src, C_CYAN)
    f_dec(r, C + 30, src, 2)
f_str(9, C + 12, 'AMODE', 'AMODE')
put(9, C + 21, '电平', C_CYAN)
f_bar(9, C + 25, 'VU', C_GREEN)

# 日志 / 命令行 / 系统信息
box(LOG_TOP - 1, 0, LOG_TOP + LOG_N, COLS - 1, '系统日志 (最近 15 条)')
put(LOG_TOP - 1, 99, ' 共 ', C_GREY)
f_dec(LOG_TOP - 1, 103, 'LOGN', 3, colr=C_WHITE)
put(LOG_TOP - 1, 106, ' 条 ', C_GREY)
box(28, 0, 31, COLS - 1, '命令行')
put(CMD_ROW, 2, 'admin@player:~$ ', C_GREEN)
assert put(CMD_ROW, 2, 'admin@player:~$ ', C_GREEN) == CMD_C0
put(30, 2, '{1}A/B{6}选命令 {1}0~9{6}参数 {1}*{6}退格 {1}#{6}执行 {1}C/D{6}上/下一张 {2}│ {6}show<n> next prev '
        'mode<0-3> bright<0-16> vol<0-16> eff<0-8> auto<0|1> alarm', C_GREY)
assert put(30, 2, '') <= COLS - 1
box(32, 0, 35, COLS - 1, '系统信息')
put(33, 2, 'FPGA EG4S20BG256 · 主屏 HDMI2 1280x800@60Hz · 终端屏 HDMI1 1024x600@60Hz · '
        'SDRAM 4 bank 帧缓存 · 音频 48kHz', C_GREY)
put(34, 2, '按键 KEY1 报警触发  KEY2 自动轮播/长按特效  KEY3 下一张/长按上一张   '
        '拨码 SW1 报警布防  SW2 频谱  SW3 参数  SW4 音源', C_GREY)
# 状态栏 (第 36 行, 深灰底)
put(36, 1, '键盘:', C_CYAN)
put(36, 7, '4x4 矩阵 (A0~A3 = H16 H15 J16 K15, B0~B3 = G14 G16 F15 F14)', C_GREEN)
put(36, 72, '│ HDMI1 1024x600@60Hz · TMDS (DVI) │ 状态 1 ms 刷新', C_GREY)
prog.append(HALT)
P_STATUS_BODY = prog
prog = []

# 日志行: [hh:mm:ss] 消息 数值, 补空格到边框
prog.extend([SETPOS_LOG, 2, SETCOL + C_GREY] + CS.code('[') + [TIME] + CS.code(']') + CS.code(' ') +
            [OP_STR + S['EMSG'], 0, OP_STR + S['ESUF'], 0, SETCOL + C_WHITE, OP_DEC + S['EARG'], 3 | 8, PAD, COLS - 1, HALT])
P_LOG_BODY = prog
P_CMDCLR_BODY = [SETPOS, CMD_ROW, CMD_C0, PAD, COLS - 1, HALT]
# 清行后写所选命令名, 结束时的列号即光标位置
P_CMDW_BODY = [SETPOS, CMD_ROW, CMD_C0, PAD, COLS - 1, SETPOS, CMD_ROW, CMD_C0,
               OP_STR + S['CMDSEL'], ROM.enum_d['CMDS'], HALT]

P_STATUS = len(ROM.w)
ROM.w += P_STATUS_BODY
P_LOG = len(ROM.w)
ROM.w += P_LOG_BODY
P_CMDCLR = len(ROM.w)
ROM.w += P_CMDCLR_BODY
P_CMDW = len(ROM.w)
ROM.w += P_CMDW_BODY
assert len(ROM.w) <= PROG_DEPTH, len(ROM.w)


# ---------------- 参考模型 (与 term_top.v 逐条一致) ----------------
def bcd3(v):
    return [v // 100 % 10, v // 10 % 10, v % 10]


class Model:
    def __init__(self):
        self.code = [row[:] for row in code]
        self.color = [row[:] for row in color]
        self.log_wr = 0
        self.log_cnt = 0
        self.log_total = 0
        self.cur = CMD_C0
        self.sel = 0              # 所选命令 0 = 无, 1~9
        self.ndig = 0             # 已输入参数位数 (最多 2)

    def run(self, pc, src, t=(0, 0, 0), ev=None):
        r = c = 0
        col = C_WHITE
        rom = ROM.w

        def wr(k):
            nonlocal c
            self.code[r][c], self.color[r][c] = k, col
            assert c < 127 or k == 0x20, (r, c)
            c = (c + 1) & 127
        while True:
            w = rom[pc]
            pc += 1
            if w < 0x180:
                wr(w)
            elif w < 0x1A0 or (0x1A0 <= w < 0x1C0) or (0x1C0 <= w < 0x1E0):
                s = w & 31
                # ev = (消息数据字, 按值选, 后缀数据字, 有后缀, 事件值, 数值, 有数值)
                v = ev[5] if s == S['EARG'] else src[s] if src else 0
                if w < 0x1A0:
                    d = rom[pc]
                    pc += 1
                    if s == S['EMSG']:
                        d, v = ev[0], ev[4] if ev[1] else 0
                    elif s == S['ESUF']:
                        if not ev[3]:
                            continue
                        d, v = ev[2], ev[4]
                    a = ((d & 127) + v) << (4 + (d >> 7))
                    while rom[a] != END:
                        x = rom[a]
                        if x >= SETCOL:
                            col = x & 7
                        else:
                            wr(x)
                        a += 1
                elif w < 0x1C0:
                    f = rom[pc]
                    pc += 1
                    if s == S['EARG'] and not ev[6]:
                        continue
                    n = f & 3
                    dg = bcd3(v)[3 - n:]
                    lead = True
                    for i, x in enumerate(dg):
                        if lead and x == 0 and i < n - 1:
                            if f & 8:
                                continue
                            wr(0x30 if f & 4 else 0x20)
                        else:
                            lead = False
                            wr(0x30 + x)
                else:
                    keep = col
                    for k in range(16):
                        col = keep if k < v else C_DIM
                        wr(BAR_FULL if k < v else BAR_EMPTY)
                    col = keep
            elif w == END:
                raise ValueError('END outside string')
            elif w == HALT:
                return c
            elif w == TIME:
                h, m, s_ = t
                for k in [h // 10, h % 10, -1, m // 10, m % 10, -1, s_ // 10, s_ % 10]:
                    wr(0x3A if k < 0 else 0x30 + k)
            elif w == PAD:
                tgt = rom[pc]
                pc += 1
                while c < tgt:
                    wr(0x20)
            elif w == SETPOS:
                r, c = rom[pc], rom[pc + 1]
                pc += 2
            elif w == SETPOS_LOG:
                r, c = LOG_TOP + self.log_wr, rom[pc]
                pc += 1
            elif w >= SETCOL:
                col = w & 7
            else:
                raise ValueError(hex(w))

    def status(self, src, t=(0, 0, 0)):
        self.run(P_STATUS, src, t)

    def log(self, ev_idx, val, arg, has, t):
        self.run(P_LOG, None, t, ROM.ev_d[ev_idx] + (val, arg, has))
        self.log_wr = (self.log_wr + 1) % LOG_N
        self.log_cnt = min(self.log_cnt + 1, LOG_N)

    def key(self, k):
        """命令行编辑 (与 term_top.v S_KB 一致; 命令执行 / 日志由硬件记录的 LOG 行重放)"""
        r = CMD_ROW
        if 0x30 <= k <= 0x39:
            if self.sel and self.ndig < 2:
                self.code[r][self.cur], self.color[r][self.cur] = k, C_WHITE
                self.cur += 1
                self.ndig += 1
        elif k == 0x08:
            if self.ndig:
                self.cur -= 1
                self.ndig -= 1
                self.code[r][self.cur], self.color[r][self.cur] = 0x20, C_WHITE
            elif self.sel:
                self.sel = 0
                self.run(P_CMDCLR, None)
                self.cur = CMD_C0
        elif k in (0x11, 0x12):
            self.sel = (self.sel % 9 + 1) if k == 0x11 else (9 if self.sel <= 1 else self.sel - 1)
            self.ndig = 0
            src = [0] * 32
            src[S['CMDSEL']] = self.sel
            self.cur = self.run(P_CMDW, src)
        elif k == 0x0D:
            self.sel = self.ndig = 0
            self.run(P_CMDCLR, None)
            self.cur = CMD_C0

    def head(self):
        return self.log_wr if self.log_cnt == LOG_N else 0

    def phys_row(self, r):
        if LOG_TOP <= r < LOG_TOP + LOG_N:
            return LOG_TOP + (r - LOG_TOP + self.head()) % LOG_N
        return r


def render(vcode, vcolor, font, head, cur, blink):
    """显存 -> 1024x600 RGB (与 term_top.v 渲染流水线一致)"""
    from PIL import Image
    img = Image.new('RGB', (1024, 600))
    px = img.load()
    for y in range(600):
        r = y >> 4
        bg = BG_TITLE if r == 0 else BG_SBAR if r >= 36 else BG_MAIN
        pr = LOG_TOP + (r - LOG_TOP + head) % LOG_N if LOG_TOP <= r < LOG_TOP + LOG_N else r
        for cx in range(COLS):
            if r < ROWS:
                k, fc = vcode[pr * COLS + cx], vcolor[pr * COLS + cx]
                g = font[k * 16 + (y & 15)] if k * 16 < len(font) else 0
            else:
                g, fc = 0, 0
            inv = blink and r == CMD_ROW and cx == cur
            for b in range(8):
                on = (g >> (7 - b)) & 1
                if inv:
                    v = bg if on else CURSOR
                else:
                    v = PAL[fc] if on else bg
                px[cx * 8 + b, y] = ((v >> 16) & 255, (v >> 8) & 255, v & 255)
    return img


def src_vals(st=2, cnt=12, wav=1, txt=1, fnt=0, sw=(1, 0, 0, 0), alarm=0, pre=0, cur=2, fsm=0, prog=255,
             eff=8, auto=1, wave=0, menu=0, amode=0, pmode=0, lv=(8, 8, 8, 8, 16), vu=9, rate=7, logn=0):
    v = [0] * 32
    v[S['ST']], v[S['CNT']], v[S['WAV']], v[S['TXT']], v[S['FNT']] = st, cnt, wav, txt, fnt
    v[S['ALM']] = 2 if alarm else (3 if pre else 1) if sw[0] else 0
    for i in range(4):
        v[S['SW1'] + i] = sw[i]
    v[S['CUR']] = cur + 1
    v[S['FSM']] = fsm
    v[S['PROG16']] = (prog + 8) >> 4
    v[S['PCT']] = (prog * 100 + 128) >> 8
    v[S['EFF']], v[S['AUTO']], v[S['WAVE']], v[S['MENU']] = eff, auto, wave, menu
    v[S['AMODE']], v[S['PMODE']] = amode, pmode
    for i, n in enumerate(['BRI', 'CON', 'TEMP', 'GAM', 'VOL']):
        v[S[n]] = lv[i]
    v[S['VU']], v[S['RATE']], v[S['LOGN']] = vu, rate, logn
    return v


def flat(m):
    return [x for row in m for x in row]


def main():
    font = CS.font()
    print('汉字 %d 个, 字库 %d 字节, 微程序 %d / %d 字 (状态程序 %d 字)'
          % (len(CS.cn), len(font), len(ROM.w), PROG_DEPTH, len(P_STATUS_BODY)))
    assert len(CS.font()) <= 8192, '字库超过 2 块 BRAM32K'
    # 显存初值: 模板 + 状态字段按全 0 输入刷新一遍
    m = Model()
    m.status(src_vals(st=0, cnt=0, wav=0, txt=0, fnt=0, sw=(0, 0, 0, 0), cur=-1, prog=0, eff=0,
                      auto=0, amode=0, lv=(0, 0, 0, 0, 0), vu=0, rate=0))
    vc, va = flat(m.code), flat(m.color)
    fdepth = len(font)
    write_rom(OUT_DIR, 'term_font_rom', font, 13, 'gen_term_rom.py 终端字库 8x16, addr = {字符码[8:0], 行[3:0]}',
              implement='32K', width=8, depth=fdepth)
    write_rom(OUT_DIR, 'term_prog_rom', ROM.w, 11, 'gen_term_rom.py 终端微程序 (字符串 + 状态/日志/命令行程序)',
              implement='9K', width=9, depth=PROG_DEPTH)
    write_ram(OUT_DIR, 'term_vram_c', vc, 13, 9, NCELL, 'gen_term_rom.py 终端显存: 字符码 (初值 = 界面模板)')
    write_ram(OUT_DIR, 'term_vram_a', va, 13, 3, NCELL, 'gen_term_rom.py 终端显存: 前景色 (初值 = 界面模板)')
    with open(os.path.join(OUT_DIR, 'term_prog.vh'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('// 自动生成, 请勿手改: python/gen_term_rom.py\n')
        f.write('localparam [10:0] P_STATUS = %d, P_LOG = %d, P_CMDCLR = %d, P_CMDW = %d;\n' % (P_STATUS, P_LOG, P_CMDCLR, P_CMDW))
        f.write('localparam FONT_DEPTH = %d;\n' % fdepth)
        f.write('localparam [5:0] LOG_TOP = %d, LOG_N = %d, CMD_ROW = %d;\n' % (LOG_TOP, LOG_N, CMD_ROW))
        f.write('localparam [6:0] CMD_C0 = %d, CMD_MAX = %d;\n' % (CMD_C0, CMD_MAX))
        f.write('localparam NEV = %d;\n' % len(EVENTS))
        for i, (n, _, _) in enumerate(EVENTS):
            f.write('localparam [3:0] E_%s = %d;\n' % (n, i))
        f.write('// 事件表: {按值选消息, 有后缀, 后缀 STR 数据字[8:0], 消息 STR 数据字[8:0]}  (数据字 = {sz[1:0], 槽号[6:0]})\n'
                'function [19:0] ev_tab;\n    input [3:0] e;\n    begin\n        case (e)\n')
        for i, (dm, bv, ds, hs) in enumerate(ROM.ev_d):
            f.write("            4'd%d: ev_tab = {1'b%d, 1'b%d, 9'h%03x, 9'h%03x};  // %s\n"
                    % (i, bv, hs, ds, dm, EVENTS[i][0]))
        f.write("            default: ev_tab = 20'h0;\n        endcase\n    end\nendfunction\n")
        f.write('// 调色板\nfunction [23:0] pal;\n    input [2:0] k;\n    begin\n        case (k)\n')
        for i, v in enumerate(PAL):
            f.write("            3'd%d: pal = 24'h%06X;\n" % (i, v))
        f.write("        endcase\n    end\nendfunction\n")
        f.write("localparam [23:0] BG_MAIN = 24'h%06X, BG_TITLE = 24'h%06X, BG_SBAR = 24'h%06X, CURSOR = 24'h%06X;\n"
                % (BG_MAIN, BG_TITLE, BG_SBAR, CURSOR))
    # 预览: 模拟一段运行
    m.status(src_vals(), (0, 12, 34))
    for i, (e, v, a, h) in enumerate([(EV['BOOT'], 0, 0, 0), (EV['ST'], 0, 0, 0), (EV['ST'], 1, 0, 0),
                                      (EV['ST'], 2, 12, 1), (EV['WAV'], 0, 0, 0), (EV['IMG'], 0, 2, 1),
                                      (EV['MENU'], 1, 0, 0), (EV['PMODE'], 2, 0, 0), (EV['MENU'], 0, 0, 0),
                                      (EV['ARM'], 1, 0, 0), (EV['ALM'], 1, 0, 0), (EV['AMODE'], 3, 0, 0),
                                      (EV['ALM'], 0, 0, 0), (EV['IMG'], 0, 3, 1)]):
        m.log(e, v, a, h, (0, i // 3, (i * 7) % 60))
    m.status(src_vals(logn=14, cur=2), (0, 12, 34))
    for k in [0x11, 0x11, 0x11, 0x11, ord('2')]:          # A x4 -> mode, 参数 2
        m.key(k)
    render(flat(m.code), flat(m.color), font, m.head(), m.cur, True).save(os.path.join(HERE, 'term_preview.png'))
    print('预览: python/term_preview.png')


if __name__ == '__main__':
    main()
