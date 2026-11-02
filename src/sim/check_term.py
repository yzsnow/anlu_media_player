# -*- coding: utf-8 -*-
"""
tb_term 结果核对: 用 python/gen_term_rom.py 的参考模型 (与 term_top.v 微程序逐条一致) 重放仿真记录的
日志事件与按键, 再按仿真结束时的状态刷新一遍, 与导出的显存逐格比较; 再用模型渲染整帧, 与仿真输出逐像素比较.
输出 frames/term_sim.png (仿真画面) 供查看.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'user_source', 'hdl_source', 'python'))
import gen_term_rom as g          # noqa: E402
from PIL import Image             # noqa: E402

F = os.path.join(HERE, 'frames')


def t_of(x):
    """ev_t {h1, h0, m1[2:0], m0, s1[2:0], s0} -> (h, m, s)"""
    s0, s1, m0, m1, h0, h1 = x & 15, (x >> 4) & 7, (x >> 7) & 15, (x >> 11) & 7, (x >> 14) & 15, (x >> 18) & 15
    return h1 * 10 + h0, m1 * 10 + m0, s1 * 10 + s0


def main():
    m = g.Model()
    snap = t = head = fc = None
    nlog = nkey = 0
    for line in open(os.path.join(F, 'term_log.txt')):
        p = line.split()
        if p[0] == 'LOG':
            e, val, arg, has, tt = int(p[1]), int(p[2]), int(p[3]), int(p[4]), int(p[5], 16)
            m.log(e, val, arg, has, t_of(tt))
            nlog += 1
        elif p[0] == 'KEY':
            m.key(int(p[1]))
            nkey += 1
        elif p[0] == 'SNAP':
            snap = [int(x) for x in p[1:]]
        elif p[0] == 'TIME':
            t = t_of(int(p[1], 16))
        elif p[0] == 'HEAD':
            head = [int(x) for x in p[1:]]
        elif p[0] == 'FC':
            fc = int(p[1])
    (st, cnt, wav, txt, fnt, prog, cur, eff, aut, wave, menu, amode, pmode,
     bri, con, temp, gam, vol, vu, rate, sw, alarm, fsm, logn, pre) = snap
    src = g.src_vals(st=st, cnt=cnt, wav=wav, txt=txt, fnt=fnt, sw=[(sw >> i) & 1 for i in range(4)], alarm=alarm, pre=pre,
                     cur=cur, fsm=fsm, prog=prog, eff=eff, auto=aut, wave=wave, menu=menu, amode=amode, pmode=pmode,
                     lv=(bri, con, temp, gam, vol), vu=vu, rate=rate, logn=logn)
    m.status(src, t)
    err = 0
    print('日志 %d 条, 按键 %d 个, 日志总数 %d, 环头 %s' % (nlog, nkey, logn, head))
    if nlog < 16 or logn != nlog:
        print('日志条数不对'); err += 1
    if head != [m.log_wr, m.log_cnt, m.cur]:
        print('日志环 / 光标位置不一致: 硬件 %s 模型 %s' % (head, [m.log_wr, m.log_cnt, m.cur])); err += 1

    vc = [int(x, 16) for x in open(os.path.join(F, 'term_vram_c.hex')) if x.strip() and not x.startswith('//')]
    va = [int(x, 16) for x in open(os.path.join(F, 'term_vram_a.hex')) if x.strip() and not x.startswith('//')]
    mc, ma = g.flat(m.code), g.flat(m.color)
    bad = [i for i in range(g.NCELL) if vc[i] != mc[i] or va[i] != ma[i]]
    for i in bad[:10]:
        print('显存 (%d, %d): 硬件 %03x/%d 模型 %03x/%d' % (i // 128, i % 128, vc[i], va[i], mc[i], ma[i]))
    print('显存 %d 格, 不一致 %d' % (g.NCELL, len(bad)))
    err += len(bad) > 0

    font = g.CS.font()
    blink = bool(fc & 1)            # tb: BLINK = 0
    ref = g.render(mc, ma, font, m.head(), m.cur, blink)
    px = [int(x, 16) for x in open(os.path.join(F, 'term_frame.hex'))]
    sim = Image.new('RGB', (1024, 600))
    sim.putdata([((v >> 16) & 255, (v >> 8) & 255, v & 255) for v in px])
    sim.save(os.path.join(F, 'term_sim.png'))
    rp = list(ref.getdata())
    nb = 0
    for i, v in enumerate(px):
        x, y = i % 1024, i // 1024
        if y < 16 and 113 * 8 <= x < 121 * 8:      # 运行时间在抓帧期间会走秒, 已在显存比较中核对
            continue
        if rp[i] != ((v >> 16) & 255, (v >> 8) & 255, v & 255):
            if nb < 5:
                print('像素 (%d, %d): 硬件 %06x 模型 %s' % (x, y, v, rp[i]))
            nb += 1
    print('整帧 1024x600 像素不一致 %d (光标%s)' % (nb, '显示' if blink else '隐藏'))
    err += nb > 0
    print('check_term PASS' if err == 0 else 'check_term FAIL')
    return 0 if err == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
