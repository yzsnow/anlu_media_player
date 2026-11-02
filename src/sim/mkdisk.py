# -*- coding: utf-8 -*-
"""
生成仿真用 FAT32 TF 卡镜像 disk.img, 以及期望值 expect.vh / wav_exp.hex / txt_exp.hex / fnt_exp.hex

覆盖的情形:
  * MBR 分区表, 分区起始 LBA 8, 每簇 8 扇区, 2 个 FAT
  * 根目录占 2 个不连续簇 (中间用已删除项填充)
  * 卷标、长文件名 (LFN)、已删除项、子目录、过小的 BMP 都应被忽略
  * IMG_A.BMP 正常 (640x400), BAD.BMP 头部错误 (RLE 压缩),
    IMG_C.BMP 为 640x480 (加载器等比缩成 533x400 左右补黑) 且簇链碎片化
  * MUSIC.WAV: 16bit 立体声 22050Hz, fmt 与 data 之间有奇数长度 LIST 块
  * SUB.TXT / SUB.FNT
  --stress : MUSIC.WAV 改为 48kHz 立体声 120000 帧 (2.5 s), 供实际卡时序压力仿真
  --fit    : 任意分辨率镜像 (只有图片), 期望值写入 fit_exp.hex, 供 tb_loader -DFIT
  --folder : 分类文件夹 IMG / MUSIC / SUB + 播放列表 PLAY.CFG, 期望值写入 fold_exp.hex, 供 tb_loader -DFOLDER
             (加 --nocfg: 没有播放列表, 图片按 IMG 文件夹的目录顺序)
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PART = 8
SPC = 8
RSVD = 32
NFATS = 2
FATSZ = 8
CLUS = SPC * 512
DATA_LBA = PART + RSVD + NFATS * FATSZ
STRESS = "--stress" in sys.argv
FIT = "--fit" in sys.argv
FOLDER = "--folder" in sys.argv
if FIT:
    FATSZ = 16
    DATA_LBA = PART + RSVD + NFATS * FATSZ
NCLUS = 1500 if FIT else (900 if STRESS else 760)

W, H = 640, 400                 # 显示内容尺寸 (FPGA 放大成 1280x800 输出)

fat = [0] * (FATSZ * 512 // 4)
fat[0] = 0x0FFFFFF8
fat[1] = 0x0FFFFFFF
data = {}                   # cluster -> bytes
next_free = [2]


VOL_SER = 0x1A2B3C4D


def alloc(n, gap_after=None):
    """分配 n 个簇, gap_after = k 表示在第 k 簇之后空出 5 簇 (制造碎片)"""
    cl = []
    for i in range(n):
        cl.append(next_free[0])
        next_free[0] += 1
        if gap_after is not None and i == gap_after:
            next_free[0] += 5
    return cl


def store(content, clusters):
    for i, c in enumerate(clusters):
        data[c] = content[i * CLUS:(i + 1) * CLUS]
        fat[c] = clusters[i + 1] if i + 1 < len(clusters) else 0x0FFFFFFF


def nclus(size):
    return (size + CLUS - 1) // CLUS


def bmp(pix_fn, w=W, h=H, bpp=24, topdown=False, comp=0):
    """y 为文件内行号 (自下而上存储时第 0 行是图像最底行); 每行补齐到 4 字节"""
    nb = bpp // 8
    stride = (w * nb + 3) // 4 * 4
    hdr = b"BM" + struct.pack("<IHHI", 54 + stride * h, 0, 0, 54)
    hdr += struct.pack("<IiiHHIIiiII", 40, w, -h if topdown else h, 1, bpp, comp, stride * h, 2835, 2835, 0, 0)
    body = bytearray(stride * h)
    for y in range(h):
        o = y * stride
        for x in range(w):
            r, g, b = pix_fn(x, y)
            body[o] = b; body[o + 1] = g; body[o + 2] = r
            if nb == 4:
                body[o + 3] = 0xFF
            o += nb
    return hdr + bytes(body)


def fit_frame(pix_fn, w, h):
    """bmp_fit_scaler 参考模型: 等比缩放 (最近邻) 到 640x400 并补黑边居中.
    返回按写入顺序 (= 文件行顺序) 的 256000 个字 {R,G,B,8'h00}"""
    if w * 400 >= h * 640:
        dw, dh = 640, max(1, h * 640 // w)
    else:
        dw, dh = max(1, w * 400 // h), 400
    pl, pf = (640 - dw) // 2, (400 - dh) // 2
    out = []
    for oy in range(400):
        j = oy - pf
        if not 0 <= j < dh:
            out += [0] * 640
            continue
        sy = j * h // dh
        row = [0] * 640
        for k in range(dw):
            r, g, b = pix_fn(k * w // dw, sy)
            row[pl + k] = (r << 24) | (g << 16) | (b << 8)
        out += row
    return out, dw, dh


def img_a(x, y):
    return (x * 255 // 639, y * 255 // 399, 64)


def img_c(x, y):
    c = 230 if ((x >> 5) ^ (y >> 5)) & 1 else 30
    return (c, 255 - c, (x + y) & 255)


def frame_hash(pix_fn, w=W, h=H):
    """与 tb 中相同的哈希 (FNV-1a, 按 32bit 字, 写入顺序): h = (h ^ word) * 0x01000193"""
    words, _, _ = fit_frame(pix_fn, w, h)
    hv = 0x811C9DC5
    for v in words:
        hv = ((hv ^ v) * 0x01000193) & 0xFFFFFFFF
    return hv


def dirent(name, ext, attr, clus, size, first=None):
    n = name.ljust(8).encode()[:8]
    if first is not None:
        n = bytes([first]) + n[1:]
    e = n + ext.ljust(3).encode()[:3] + bytes([attr]) + bytes(8)
    e += struct.pack("<H", clus >> 16) + bytes(4) + struct.pack("<HI", clus & 0xFFFF, size)
    assert len(e) == 32
    return e


def lfn(seq, text):
    t = (text + "\0").ljust(13, "￿")
    u = t.encode("utf-16-le")
    return bytes([seq]) + u[0:10] + bytes([0x0F, 0, 0]) + u[10:22] + bytes(2) + u[22:26]


def main():
    # ---------------- 文件内容 ----------------
    a = bmp(img_a)
    bad = bytearray(bmp(img_a))
    bad[30] = 1                        # BI_RLE8 压缩, 应被判为损坏
    c = bmp(img_c, h=480)              # 640x480: 等比缩成 533x400 左右补黑
    small = bmp(img_a)[:40]            # 不到一个 BMP 头, 扫描时忽略

    rate, nfr = (48000, 120000) if STRESS else (22050, 1500)
    pcm = bytearray()
    samples = []
    for i in range(nfr):
        l = (i * 97 - 30000) & 0xFFFF
        r = (0x8000 + i * 13) & 0xFFFF
        pcm += struct.pack("<HH", l, r)
        samples.append((l << 16) | r)
    fmt = struct.pack("<HHIIHH", 1, 2, rate, rate * 4, 4, 16)
    wav = b"WAVE" + b"fmt " + struct.pack("<I", 16) + fmt
    wav += b"LIST" + struct.pack("<I", 7) + b"INFOabc" + b"\0"
    wav += b"data" + struct.pack("<I", len(pcm)) + bytes(pcm)
    wav = b"RIFF" + struct.pack("<I", len(wav)) + wav

    txt = "Hello FPGA! ".encode() + bytes([0x80, 0x81, 0x82, 0x83]) + b" end"
    fnt = bytes(((i * 7) ^ (i >> 4)) & 0xFF for i in range(2048))

    # ---------------- 分配簇 ----------------
    root = [2]
    next_free[0] = 3
    cl_a = alloc(nclus(len(a)))
    cl_wav = alloc(nclus(len(wav)))
    cl_bad = alloc(nclus(len(bad)))
    cl_c = alloc(nclus(len(c)), gap_after=100)
    cl_txt = alloc(1)
    cl_fnt = alloc(1)
    cl_small = alloc(1)
    root.append(next_free[0] + 3)      # 根目录第 2 簇, 不连续
    next_free[0] += 4
    assert next_free[0] < NCLUS

    ents = []
    ents.append(dirent("TFCARD", "", 0x08, 0, 0))
    ents.append(lfn(0x41, "img_a.bmp"))
    ents.append(dirent("IMG_A", "BMP", 0x20, cl_a[0], len(a)))
    ents.append(dirent("OLD", "BMP", 0x20, cl_a[0], len(a), first=0xE5))
    ents.append(dirent("BAD", "BMP", 0x20, cl_bad[0], len(bad)))
    ents.append(dirent("SMALL", "BMP", 0x20, cl_small[0], len(small)))
    ents.append(dirent("PICS", "BMP", 0x10, cl_small[0], 0))
    while len(ents) < 130:             # 填满第 1 簇 (128 项), 进入第 2 簇
        ents.append(dirent("DELETED", "TMP", 0x20, 0, 0, first=0xE5))
    ents.append(dirent("MUSIC", "WAV", 0x20, cl_wav[0], len(wav)))
    ents.append(dirent("SUB", "TXT", 0x20, cl_txt[0], len(txt)))
    ents.append(dirent("SUB", "FNT", 0x20, cl_fnt[0], len(fnt)))
    ents.append(dirent("IMG_C", "BMP", 0x20, cl_c[0], len(c)))
    ents.append(bytes(32))             # 目录结束
    rootdata = b"".join(ents)
    ic = next(i for i, e in enumerate(ents) if e[:11] == b"IMG_C   BMP")
    dirc = (DATA_LBA + (root[ic * 32 // CLUS] - 2) * SPC) * 512 + ic * 32 % CLUS

    store(rootdata, root)
    store(a, cl_a)
    store(wav, cl_wav)
    store(bytes(bad), cl_bad)
    store(c, cl_c)
    store(txt, cl_txt)
    store(fnt, cl_fnt)
    store(small, cl_small)

    # ---------------- 镜像 ----------------
    total = DATA_LBA + NCLUS * SPC
    img = bytearray(total * 512)
    mbr = bytearray(512)
    mbr[0x1BE:0x1CE] = struct.pack("<B3sB3sII", 0, b"\0\0\0", 0x0C, b"\0\0\0", PART, total - PART)
    mbr[510:512] = b"\x55\xAA"
    img[0:512] = mbr

    vbr = bytearray(512)
    vbr[0:3] = b"\xEB\x58\x90"
    vbr[3:11] = b"MSWIN4.1"
    struct.pack_into("<HBHBHHBHHHII", vbr, 11, 512, SPC, RSVD, NFATS, 0, 0, 0xF8, 0, 63, 255, PART, total - PART)
    struct.pack_into("<IHHI", vbr, 36, FATSZ, 0, 0, 2)
    vbr[0x42] = 0x29                   # 扩展引导签名, 0x43 起为卷序列号 (加载器心跳核对)
    struct.pack_into("<I", vbr, 0x43, VOL_SER)
    vbr[0x47:0x52] = b"TFCARD     "
    vbr[0x52:0x5A] = b"FAT32   "
    vbr[510:512] = b"\x55\xAA"
    img[PART * 512:PART * 512 + 512] = vbr

    fatb = b"".join(struct.pack("<I", v) for v in fat)
    for k in range(NFATS):
        o = (PART + RSVD + k * FATSZ) * 512
        img[o:o + len(fatb)] = fatb
    for cl, d in data.items():
        o = (DATA_LBA + (cl - 2) * SPC) * 512
        img[o:o + len(d)] = d

    with open(os.path.join(HERE, "disk.img"), "wb") as f:
        f.write(img)

    # ---------------- 期望值 ----------------
    with open(os.path.join(HERE, "expect.vh"), "w") as f:
        f.write(f"localparam integer DISK_BYTES = {len(img)};\n")
        f.write(f"localparam [31:0] HASH_IMG0 = 32'h{frame_hash(img_a):08X};\n")
        f.write(f"localparam [31:0] HASH_IMG2 = 32'h{frame_hash(img_c, 640, 480):08X};\n")
        f.write(f"localparam integer WAV_N = {len(samples)};\n")
        f.write(f"localparam integer WAV_RATE = {rate};\n")
        f.write(f"localparam integer TXT_N = {len(txt)};\n")
        f.write(f"localparam integer VBR_OFF = {PART * 512};\n")
        f.write(f"localparam integer DIRC_OFF = {dirc};\n")
        f.write(f"localparam [31:0] VOL_SER = 32'h{VOL_SER:08X};\n")
    with open(os.path.join(HERE, "wav_exp.hex"), "w") as f:
        f.write("\n".join(f"{s:08X}" for s in samples) + "\n")
    with open(os.path.join(HERE, "txt_exp.hex"), "w") as f:
        f.write("\n".join(f"{b:02X}" for b in txt) + "\n")
    with open(os.path.join(HERE, "fnt_exp.hex"), "w") as f:
        f.write("\n".join(f"{b:02X}" for b in fnt) + "\n")
    print(f"disk.img {len(img)} bytes, data_lba {DATA_LBA}, root {root}, "
          f"IMG_C clusters {cl_c[0]}..{cl_c[-1]} (fragmented at {cl_c[100]}->{cl_c[101]})")


def pat(w, h, seed):
    """每张图不同的测试图案: 渐变 + 异或纹理 + 白边框, 取样错一列 / 一行都会改变哈希"""
    def fn(x, y):
        if x == 0 or y == 0 or x == w - 1 or y == h - 1:
            return (255, 255, 255)
        return ((x * 251 // w + seed * 40) & 255, (y * 241 // h) & 255, ((x ^ y) * 7 + seed) & 255)
    return fn


def main_fit():
    # (文件名, 宽, 高, bpp, 自上而下, 压缩, 截断, 说明)
    cases = [
        ("D800",   800, 500, 24, False, 0, False, "16:10 缩小 1.25 倍, 无黑边"),
        ("WIDE",  1000, 333, 24, False, 0, False, "宽图, 上下黑边"),
        ("TALL",   301, 500, 24, False, 0, False, "竖图, 左右黑边, 每行补 1 字节"),
        ("UP4",    160, 100, 24, False, 0, False, "放大 4 倍"),
        ("TOPDN",  202, 150, 24, True,  0, False, "自上而下存储, 每行补 2 字节"),
        ("ARGB",   123,  77, 32, False, 3, False, "32bit BITFIELDS"),
        ("THIN",    17, 900, 24, False, 0, False, "极窄: 水平放大 + 垂直缩小"),
        ("STRIP", 4096,  16, 24, False, 0, False, "最宽 4096, 只剩 2 行"),
        ("RLE",    320, 200, 24, False, 1, False, "压缩, 应拒绝"),
        ("TRUNC",  320, 200, 24, False, 0, True,  "文件截断, 应拒绝"),
        ("TINY",    15,  15, 24, False, 0, False, "小于 16, 应拒绝"),
        ("BIG",   4097,  16, 24, False, 0, False, "宽于 4096, 应拒绝"),
    ]
    root = [2]
    next_free[0] = 3
    ents = []
    exp = []
    for i, (name, w, h, bpp, td, comp, trunc, note) in enumerate(cases):
        fn = pat(w, h, i)
        b = bmp(fn, w, h, bpp, td, comp)
        if trunc:
            b = b[:len(b) // 2]
        ok = (not trunc) and comp in (0, 3) and 16 <= w <= 4096 and 16 <= h <= 4096
        cl = alloc(nclus(len(b)))
        store(b, cl)
        ents.append(dirent(name, "BMP", 0x20, cl[0], len(b)))
        dw = dh = hv = 0
        if ok:
            # 参考模型按文件行顺序 = 写入顺序; 自上而下存储的图由 vflip=0 保证不翻转
            hv = frame_hash(fn, w, h)
            _, dw, dh = fit_frame(fn, w, h)
        exp.append((ok, 0 if td else 1, hv))
        print(f"  {i:2d} {name:6s} {w}x{h} {bpp}bit -> {dw}x{dh} ok={ok}  {note}")
    ents.append(bytes(32))
    store(b"".join(ents), root)
    assert next_free[0] < NCLUS, next_free[0]

    total = DATA_LBA + NCLUS * SPC
    img = bytearray(total * 512)
    mbr = bytearray(512)
    mbr[0x1BE:0x1CE] = struct.pack("<B3sB3sII", 0, b"\0\0\0", 0x0C, b"\0\0\0", PART, total - PART)
    mbr[510:512] = b"\x55\xAA"
    img[0:512] = mbr
    vbr = bytearray(512)
    vbr[0:3] = b"\xEB\x58\x90"
    struct.pack_into("<HBHBHHBHHHII", vbr, 11, 512, SPC, RSVD, NFATS, 0, 0, 0xF8, 0, 63, 255, PART, total - PART)
    struct.pack_into("<IHHI", vbr, 36, FATSZ, 0, 0, 2)
    vbr[0x42] = 0x29
    struct.pack_into("<I", vbr, 0x43, VOL_SER)
    vbr[510:512] = b"\x55\xAA"
    img[PART * 512:PART * 512 + 512] = vbr
    fatb = b"".join(struct.pack("<I", v) for v in fat)
    for k in range(NFATS):
        o = (PART + RSVD + k * FATSZ) * 512
        img[o:o + len(fatb)] = fatb
    for cl, d in data.items():
        o = (DATA_LBA + (cl - 2) * SPC) * 512
        img[o:o + len(d)] = d
    with open(os.path.join(HERE, "disk.img"), "wb") as f:
        f.write(img)
    with open(os.path.join(HERE, "expect.vh"), "w") as f:
        f.write(f"localparam integer DISK_BYTES = {len(img)};\n")
        f.write(f"localparam integer FIT_N = {len(cases)};\n")
        # tb_loader 其余部分引用的常量 (FIT 模式不检查)
        f.write("localparam [31:0] HASH_IMG0 = 0;\nlocalparam [31:0] HASH_IMG2 = 0;\n")
        f.write("localparam integer WAV_N = 1;\nlocalparam integer WAV_RATE = 0;\nlocalparam integer TXT_N = 1;\n")
        f.write(f"localparam integer VBR_OFF = {PART * 512};\nlocalparam integer DIRC_OFF = 0;\n")
        f.write(f"localparam [31:0] VOL_SER = 32'h{VOL_SER:08X};\n")
    with open(os.path.join(HERE, "fit_exp.hex"), "w") as f:
        f.write("\n".join(f"{int(ok):X}{vf:X}{hv:08X}" for ok, vf, hv in exp) + "\n")
    print(f"disk.img {len(img)} bytes (fit), {len(cases)} images")


def write_disk(total_clus):
    """MBR + VBR + 2 份 FAT + 数据区 -> disk.img, 返回镜像字节数"""
    total = DATA_LBA + total_clus * SPC
    img = bytearray(total * 512)
    mbr = bytearray(512)
    mbr[0x1BE:0x1CE] = struct.pack("<B3sB3sII", 0, b"\0\0\0", 0x0C, b"\0\0\0", PART, total - PART)
    mbr[510:512] = b"\x55\xAA"
    img[0:512] = mbr
    vbr = bytearray(512)
    vbr[0:3] = b"\xEB\x58\x90"
    struct.pack_into("<HBHBHHBHHHII", vbr, 11, 512, SPC, RSVD, NFATS, 0, 0, 0xF8, 0, 63, 255, PART, total - PART)
    struct.pack_into("<IHHI", vbr, 36, FATSZ, 0, 0, 2)
    vbr[0x42] = 0x29
    struct.pack_into("<I", vbr, 0x43, VOL_SER)
    vbr[510:512] = b"\x55\xAA"
    img[PART * 512:PART * 512 + 512] = vbr
    fatb = b"".join(struct.pack("<I", v) for v in fat)
    for k in range(NFATS):
        o = (PART + RSVD + k * FATSZ) * 512
        img[o:o + len(fatb)] = fatb
    for cl, d in data.items():
        o = (DATA_LBA + (cl - 2) * SPC) * 512
        img[o:o + len(d)] = d
    with open(os.path.join(HERE, "disk.img"), "wb") as f:
        f.write(img)
    return len(img)


def small_wav(rate, n):
    pcm = b"".join(struct.pack("<hh", (i * 211) % 30000 - 15000, -((i * 77) % 20000)) for i in range(n))
    fmt = struct.pack("<HHIIHH", 1, 2, rate, rate * 4, 4, 16)
    w = b"WAVE" + b"fmt " + struct.pack("<I", 16) + fmt + b"data" + struct.pack("<I", len(pcm)) + pcm
    return b"RIFF" + struct.pack("<I", len(w)) + w


def main_folder(use_cfg):
    """分类文件夹镜像: 根目录有 IMG / MUSIC / SUB 文件夹 (和不应再使用的旧文件), 可选 PLAY.CFG 播放列表"""
    imgs = {                                   # 文件名 -> (宽, 高, 图案种子)
        "IMG01": (160, 100, 1), "IMG02": (96, 60, 2), "IMG03": (200, 125, 3), "IMG05": (120, 75, 5),
    }
    cfg = ("# 演示播放列表: 图片编号 显示秒数\r\n"
           "03 5\r\n"
           "IMG01.BMP 8   # 文件名写法\r\n"
           "02\r\n"                            # 省略秒数 = 默认
           "07 3\r\n"                          # 卡上没有 IMG07: 该位置按损坏处理
           "01 9\r\n"                          # 编号重复: 忽略
           "\r\n"
           "05 12").encode()                   # 最后一行没有换行
    root = [2]
    next_free[0] = 3
    d_img, d_mus, d_sub = alloc(1), alloc(1), alloc(1)
    files = {}
    for n, (w, h, sd) in imgs.items():
        b = bmp(pat(w, h, sd), w, h)
        files[n] = (b, alloc(nclus(len(b))))
        store(b, files[n][1])
    old = bmp(pat(64, 40, 9), 64, 40)                       # 根目录旧图片 (有 IMG 文件夹时不用)
    cl_old = alloc(nclus(len(old))); store(old, cl_old)
    wav_old = small_wav(8000, 400); cl_wo = alloc(1); store(wav_old, cl_wo)
    wav = small_wav(16000, 600); cl_w = alloc(1); store(wav, cl_w)
    txt_old = b"old subtitle"; cl_to = alloc(1); store(txt_old, cl_to)
    txt = "Folder SUB ok ".encode() + bytes([0x80, 0x81]) + b" !"
    cl_t = alloc(1); store(txt, cl_t)
    fnt = bytes((i * 13 + 5) & 0xFF for i in range(2048)); cl_f = alloc(1); store(fnt, cl_f)
    cl_cfg = alloc(1); store(cfg, cl_cfg)
    root.append(next_free[0] + 2)                           # 根目录第 2 簇, 不连续
    next_free[0] += 3

    ents = [dirent("TFCARD", "", 0x08, 0, 0),
            dirent("IMG_OLD", "BMP", 0x20, cl_old[0], len(old)),
            dirent("OLD", "WAV", 0x20, cl_wo[0], len(wav_old)),
            dirent("OLD", "TXT", 0x20, cl_to[0], len(txt_old)),
            dirent("IMGX", "", 0x10, d_sub[0], 0),          # 名字不对的文件夹: 忽略
            lfn(0x41, "img"),
            dirent("IMG", "", 0x10, d_img[0], 0)]
    while len(ents) < 130:                                  # 后面的项在根目录第 2 簇
        ents.append(dirent("DELETED", "TMP", 0x20, 0, 0, first=0xE5))
    ents += [dirent("MUSIC", "", 0x10, d_mus[0], 0),
             dirent("SUB", "", 0x10, d_sub[0], 0)]
    if use_cfg:
        ents.append(dirent("PLAY", "CFG", 0x20, cl_cfg[0], len(cfg)))
    ents.append(bytes(32))
    store(b"".join(ents), root)

    dot = [dirent(".", "", 0x10, 0, 0), dirent("..", "", 0x10, 0, 0)]
    order = ["IMG02", "IMG05", "IMG01", "IMG03"]            # 目录顺序与编号不同
    e = dot + [dirent(n, "BMP", 0x20, files[n][1][0], len(files[n][0])) for n in order[:2]]
    e += [dirent("NOTE", "TXT", 0x20, cl_to[0], len(txt_old)),   # IMG 文件夹里的 TXT: 不用
          dirent("IMG04", "BMP", 0x20, cl_old[0], len(old), first=0xE5)]   # 已删除
    e += [dirent(n, "BMP", 0x20, files[n][1][0], len(files[n][0])) for n in order[2:]] + [bytes(32)]
    store(b"".join(e), d_img)
    store(b"".join(dot + [dirent("MUSIC", "WAV", 0x20, cl_w[0], len(wav)), bytes(32)]), d_mus)
    store(b"".join(dot + [dirent("SUB", "TXT", 0x20, cl_t[0], len(txt)),
                          dirent("SUB", "FNT", 0x20, cl_f[0], len(fnt)), bytes(32)]), d_sub)
    assert next_free[0] < NCLUS, next_free[0]
    nbytes = write_disk(NCLUS)

    # 期望: 播放位置 -> (文件名, 秒数); 文件不存在时文件名为 None
    if use_cfg:
        plist = [("IMG03", 5), ("IMG01", 8), ("IMG02", 0), (None, 3), ("IMG05", 12)]
    else:
        plist = [(n, 0) for n in order]
    exp = []
    for n, dsec in plist:
        if n is None:
            exp.append((0, dsec, 0, " " * 8, 0, 0))
        else:
            w, h, sd = imgs[n]
            exp.append((1, dsec, frame_hash(pat(w, h, sd), w, h), n.ljust(8), w, h))
    with open(os.path.join(HERE, "expect.vh"), "w") as f:
        f.write(f"localparam integer DISK_BYTES = {nbytes};\n")
        f.write(f"localparam integer FOLD_N = {len(exp)};\n")
        f.write("localparam [31:0] HASH_IMG0 = 0;\nlocalparam [31:0] HASH_IMG2 = 0;\n")
        f.write(f"localparam integer WAV_N = 600;\nlocalparam integer WAV_RATE = 16000;\n")
        f.write(f"localparam integer TXT_N = {len(txt)};\n")
        f.write(f"localparam integer VBR_OFF = {PART * 512};\nlocalparam integer DIRC_OFF = 0;\n")
        f.write(f"localparam [31:0] VOL_SER = 32'h{VOL_SER:08X};\n")
        names = "".join(x[3] for x in exp)
        f.write(f'localparam [8*8*{len(exp)}-1:0] FOLD_NAMES = "{names}";\n')
        res = "".join(f"{x[4]}x{x[5]}".ljust(9) if x[0] else " " * 9 for x in exp)
        f.write(f'localparam [8*9*{len(exp)}-1:0] FOLD_RES = "{res}";\n')
    with open(os.path.join(HERE, "fold_exp.hex"), "w") as f:
        f.write("\n".join(f"{ok:X}{dsec:02X}{hv:08X}" for ok, dsec, hv, *_ in exp) + "\n")
    with open(os.path.join(HERE, "txt_exp.hex"), "w") as f:
        f.write("\n".join(f"{b:02X}" for b in txt) + "\n")
    with open(os.path.join(HERE, "fnt_exp.hex"), "w") as f:
        f.write("\n".join(f"{b:02X}" for b in fnt) + "\n")
    smp = [((i * 211) % 30000 - 15000) & 0xFFFF for i in range(600)]
    smr = [(-((i * 77) % 20000)) & 0xFFFF for i in range(600)]
    with open(os.path.join(HERE, "wav_exp.hex"), "w") as f:      # MUSIC 文件夹中 MUSIC.WAV 的样本 (不是根目录 OLD.WAV)
        f.write("\n".join(f"{(l << 16) | r:08X}" for l, r in zip(smp, smr)) + "\n")
    print(f"disk.img {nbytes} bytes (folder, cfg={use_cfg}), {len(exp)} positions:")
    for i, x in enumerate(exp):
        print(f"  pos {i}: {x[3]} ok={x[0]} dur={x[1]}")


if __name__ == "__main__":
    if FIT:
        main_fit()
    elif FOLDER:
        main_folder(use_cfg=("--nocfg" not in sys.argv))
    else:
        main()
