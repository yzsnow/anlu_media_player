# -*- coding: utf-8 -*-
"""
生成画面模式用的伽马曲线 ROM (gamma_rom.v) 与色温增益表 (color_temp.vh), 供 color_lut_gen.v 使用。

  伽马: 级别 L = 0~16, gamma = 2 ^ ((8 - L) / 8) (0.5 ~ 2.0), L = 8 为原样 (恒等映射)
        out = round(255 * (in / 255) ^ gamma);  L > 8 提亮暗部 (夜间), L < 8 压暗暗部 (日间更通透)
  色温: 级别 T = 0~16, T = 8 为原样; 每通道增益 (256 = 1.0)
        偏暖 k = 8 - T: G = 256 - 4k, B = 256 - 12k  (T = 0: G 0.875, B 0.625, 护眼 / 低蓝光)
        偏冷 k = T - 8: R = 256 - 10k, G = 256 - 3k  (T = 16: R 0.69, G 0.91)

check_menu.py 直接 import 本文件的 gamma_curve / temp_gain, 与硬件同一份数据.
用法:  python gen_gamma_rom.py        (输出到 ../player/)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rom_util import write_rom      # noqa: E402
OUT_DIR = os.path.join(HERE, '..', 'player')
LEVELS = 17


def gamma_curve(level):
    g = 2.0 ** ((8 - level) / 8.0)
    return [int(round(255.0 * (v / 255.0) ** g)) for v in range(256)]


def temp_gain(level):
    """(R, G, B) 增益, 256 = 1.0"""
    if level <= 8:
        k = 8 - level
        return 256, 256 - 4 * k, 256 - 12 * k
    k = level - 8
    return 256 - 10 * k, 256 - 3 * k, 256


def main():
    rom = []
    for lv in range(LEVELS):
        rom += gamma_curve(lv)
    assert gamma_curve(8) == list(range(256))
    n = len(rom)
    write_rom(OUT_DIR, 'gamma_rom', rom, 13, 'gen_gamma_rom.py 伽马曲线 17 级 x 256, addr = {级别[4:0], 输入[7:0]}')
    with open(os.path.join(OUT_DIR, 'color_temp.vh'), 'w', encoding='utf-8') as f:
        f.write("// 自动生成, 请勿手改: python/gen_gamma_rom.py\n")
        f.write("// 色温增益 (256 = 1.0): {R[8:0], G[8:0], B[8:0]}, 级别 8 为原样\n")
        f.write("function [26:0] temp_gain;\n    input [4:0] t;\n    begin\n        case (t)\n")
        for lv in range(LEVELS):
            r, g, b = temp_gain(lv)
            f.write("            5'd%d: temp_gain = {9'd%d, 9'd%d, 9'd%d};\n" % (lv, r, g, b))
        f.write("            default: temp_gain = {9'd256, 9'd256, 9'd256};\n")
        f.write("        endcase\n    end\nendfunction\n")
    print(f"gamma_rom.v {n} x 8 bit, color_temp.vh {LEVELS} levels")


if __name__ == "__main__":
    main()
