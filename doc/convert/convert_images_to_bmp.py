import os
import re
import sys
import json
import math
import argparse
from PIL import Image, ImageOps, ImageFilter

SUPPORTED_FORMATS = ('.png', '.jpg', '.jpeg', '.bmp', '.webp', '.gif', '.tif', '.tiff')

# FPGA 按 640x400 (16:10) 合成画面, 再 2x2 放大成 1280x800 HDMI 输出,
# 1920x1200 显示器等比放大 1.5 倍铺满, 没有黑边
TARGET_W, TARGET_H = 640, 400
# 输出分辨率可自定义: --size WxH, 或 media_tool_gui 中的常用分辨率列表 (也可直接输入任意宽x高)
SIZE_MIN, SIZE_MAX = 16, 8192

# 常用分辨率 (按宽高比分组): (组名, [(宽, 高, 名称), ...])
RES_GROUPS = [
    ('16:10', [(640, 400, '默认'), (320, 200, 'CGA'), (1280, 800, 'WXGA'), (1440, 900, 'WXGA+'),
               (1680, 1050, 'WSXGA+'), (1920, 1200, 'WUXGA'), (2304, 1440, ''), (2560, 1600, 'WQXGA'),
               (2880, 1800, ''), (3072, 1920, ''), (3840, 2400, 'WQUXGA')]),
    ('16:9', [(640, 360, 'nHD'), (854, 480, 'FWVGA'), (960, 540, 'qHD'), (1024, 576, ''),
              (1280, 720, '720p HD'), (1366, 768, 'WXGA'), (1600, 900, 'HD+'), (1920, 1080, '1080p FHD'),
              (2560, 1440, '1440p QHD / 2K'), (3200, 1800, 'QHD+'), (3840, 2160, '2160p UHD / 4K'),
              (5120, 2880, '5K'), (7680, 4320, '8K')]),
    ('4:3', [(320, 240, 'QVGA'), (640, 480, 'VGA'), (800, 600, 'SVGA'), (1024, 768, 'XGA'),
             (1152, 864, 'XGA+'), (1280, 960, 'SXGA-'), (1400, 1050, 'SXGA+'), (1600, 1200, 'UXGA'),
             (2048, 1536, 'QXGA'), (3200, 2400, 'QUXGA')]),
    ('5:4', [(1280, 1024, 'SXGA'), (2560, 2048, 'QSXGA')]),
    ('3:2', [(480, 320, 'HVGA'), (720, 480, 'NTSC DVD'), (1152, 768, ''), (1440, 960, ''),
             (2160, 1440, ''), (3000, 2000, '')]),
    ('21:9 带鱼屏', [(2560, 1080, 'UW-FHD'), (3440, 1440, 'UW-QHD'), (3840, 1600, 'UW-QHD+'),
                    (5120, 2160, 'UW5K')]),
    ('32:9 超宽', [(3840, 1080, 'DFHD'), (5120, 1440, 'DQHD')]),
    ('小屏 / 嵌入式', [(128, 64, 'OLED 0.96"'), (128, 128, '1.44"'), (160, 128, '1.8"'), (240, 240, '1.3"'),
                    (320, 172, '1.47"'), (320, 240, '2.8" / 3.2"'), (480, 272, '4.3"'), (480, 320, '3.5"'),
                    (800, 480, 'WVGA 5" / 7"'), (1024, 600, 'WSVGA 7" / 10"'), (1280, 400, '条形屏')]),
    ('电视 / 视频', [(720, 576, 'PAL'), (720, 480, 'NTSC'), (1280, 720, '720p'), (1920, 1080, '1080p'),
                   (2048, 1080, 'DCI 2K'), (3840, 2160, 'UHD 4K'), (4096, 2160, 'DCI 4K')]),
    ('手机竖屏', [(720, 1280, '720p'), (1080, 1920, '1080p'), (1080, 2340, '19.5:9'), (1080, 2400, '20:9'),
                (1170, 2532, 'iPhone'), (1290, 2796, 'iPhone Pro Max'), (1440, 3200, '2K 20:9')]),
    ('平板', [(1536, 2048, 'iPad 竖屏'), (2048, 1536, 'iPad 横屏'), (1668, 2388, 'iPad Pro 11"'),
            (2048, 2732, 'iPad Pro 12.9"'), (1600, 2560, '安卓平板 16:10')]),
    ('正方形', [(256, 256, ''), (512, 512, ''), (800, 800, ''), (1024, 1024, ''), (1080, 1080, '社交平台'),
              (2048, 2048, '')]),
]


def res_label(w, h, name=''):
    return f"{w}x{h}" + (f"  {name}" if name else '')


RES_PRESETS = [res_label(*r) for _, rs in RES_GROUPS for r in rs]


def aspect_text(w, h):
    """宽高比文字, 例如 1920x1080 -> '16:9', 1366x768 -> '683:384 (约 16:9)'"""
    g = math.gcd(w, h)
    a, b = w // g, h // g
    if (a, b) in ((8, 5), (5, 8)):          # 习惯写作 16:10
        a, b = a * 2, b * 2
    if a <= 32 and b <= 32:
        return f"{a}:{b}"
    r = w / h
    for x, y in ((16, 9), (16, 10), (4, 3), (5, 4), (3, 2), (21, 9), (32, 9), (1, 1), (9, 16), (3, 4)):
        if abs(r - x / y) < 0.01 * r:
            return f"{a}:{b} (约 {x}:{y})"
    return f"{r:.3f}:1"
# 缩放方式:
#   stretch  直接拉伸到 640x400 (可能变形)
#   crop     保持比例放大后裁剪 (铺满画面); 默认居中, 可用 --crop / --edit 自定义裁剪框
#   pad      保持比例缩小后居中, 四周补黑边 (完整显示)
FIT_MODES = ('stretch', 'crop', 'pad')

# 缩小后 USM 锐化强度 (%): 640x400 最终还要放大 3 倍显示, 适当锐化后边缘和文字更清楚; 0 = 不锐化
SHARPEN_DEFAULT = 50
SHARPEN_MAX = 150
ZOOM_MAX = 8.0                      # 自定义裁剪框最大放大倍数
SETTINGS_NAME = 'crop_settings.json'  # 批量模式: 每张图的裁剪框 / 锐化, 保存在输入目录中


def prepare(img, bg=(0, 0, 0)):
    """按手机拍照方向旋正, 去掉透明通道 (透明处填 bg), 返回 RGB 图像"""
    img = ImageOps.exif_transpose(img)
    if img.mode in ('RGBA', 'LA') or (img.mode == 'P' and 'transparency' in img.info):
        rgba = img.convert('RGBA')
        base = Image.new('RGB', rgba.size, bg)
        base.paste(rgba, mask=rgba.split()[3])
        return base
    return img.convert('RGB')


def crop_box(size, crop=None, target_width=TARGET_W, target_height=TARGET_H):
    """自定义裁剪框. crop = (cx, cy, zoom): 框中心 (相对原图宽 / 高, 0~1) 与放大倍数
    (1 = 原图内能放下的最大 16:10 框, 2 = 框边长减半 ...); None 为居中、zoom 1 (与默认 crop 相同).
    框超出原图时自动推回图内. 返回 ((x0, y0, x1, y1), 规范化后的 crop)"""
    w, h = size
    cx, cy, zoom = crop if crop else (0.5, 0.5, 1.0)
    zoom = min(max(float(zoom), 1.0), ZOOM_MAX)
    a = target_width / target_height
    bw, bh = (h * a, h) if w / h > a else (w, w / a)
    bw, bh = bw / zoom, bh / zoom
    x0 = min(max(cx * w - bw / 2, 0.0), w - bw)
    y0 = min(max(cy * h - bh / 2, 0.0), h - bh)
    return (x0, y0, x0 + bw, y0 + bh), ((x0 + bw / 2) / w, (y0 + bh / 2) / h, zoom)


def sharpen_image(img, amount):
    if amount <= 0:
        return img
    return img.filter(ImageFilter.UnsharpMask(radius=1.0, percent=int(amount), threshold=2))


def fit_image(img, target_width=TARGET_W, target_height=TARGET_H, mode='crop', bg=(0, 0, 0),
              crop=None, sharpen=0):
    """旋正 / 去透明后按 mode 缩放到目标尺寸 (LANCZOS), 再按 sharpen 锐化, 返回 RGB 图像.
    crop 只在 mode == 'crop' 时生效, 见 crop_box"""
    img = prepare(img, bg)
    size = (target_width, target_height)
    if mode == 'crop':
        box, _ = crop_box(img.size, crop, target_width, target_height)
        out = img.resize(size, Image.Resampling.LANCZOS, box=box)
    elif mode == 'pad':
        out = ImageOps.pad(img, size, Image.Resampling.LANCZOS, color=bg)
    else:
        out = img.resize(size, Image.Resampling.LANCZOS)
    return sharpen_image(out, sharpen)


def parse_size(text):
    """'1280x800' (也接受 '1280*800' / '1280 800' / 全角 × / 列表项 '1920x1080  1080p FHD') -> (宽, 高)"""
    m = re.match(r'\s*(\d+)\s*[xX×*,，\s]\s*(\d+)', str(text))
    if not m:
        raise ValueError(f"分辨率格式应为 宽x高, 例如 1280x800 (收到 '{text}')")
    w, h = int(m.group(1)), int(m.group(2))
    if not (SIZE_MIN <= w <= SIZE_MAX and SIZE_MIN <= h <= SIZE_MAX):
        raise ValueError(f"宽高须在 {SIZE_MIN}~{SIZE_MAX} 之间, 收到 {w}x{h}")
    return w, h


def size_arg(text):
    try:
        return parse_size(text)
    except ValueError as e:
        raise argparse.ArgumentTypeError(str(e))


def parse_crop(text):
    """'cx,cy,zoom' -> (cx, cy, zoom), 例如 0.5,0.3,1.5"""
    try:
        v = [float(t) for t in text.split(',')]
        if len(v) == 2:
            v.append(1.0)
        if len(v) != 3:
            raise ValueError
        return tuple(v)
    except ValueError:
        raise argparse.ArgumentTypeError("格式为 cx,cy[,zoom], 例如 0.5,0.3,1.5")


def crop_text(crop, sharpen):
    return f"--crop {crop[0]:.3f},{crop[1]:.3f},{crop[2]:.2f} --sharpen {sharpen}"


def load_settings(folder):
    try:
        with open(os.path.join(folder, SETTINGS_NAME), encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_settings(folder, settings):
    with open(os.path.join(folder, SETTINGS_NAME), 'w', encoding='utf-8') as f:
        json.dump(settings, f, ensure_ascii=False, indent=1)


#---------------------------------------------------------------------------
# 交互式裁剪窗口 (media_tool_gui.py 也使用)
#---------------------------------------------------------------------------
def tk_root():
    """命令行模式下的隐藏主窗口 (先打开高分屏感知, 右侧预览才是真正的 1:1 像素)"""
    if os.name == 'nt':
        try:
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except Exception:
            pass
    import tkinter as tk
    root = tk.Tk()
    root.withdraw()
    return root


class CropDialog:
    """左边: 原图上的 16:10 裁剪框, 拖动移动、滚轮缩放, 框外变暗;
    右边: 实时显示转换结果 (输出分辨率放得下时按 1:1 像素, 否则等比缩小显示), 以及锐化效果.
    拖动时先用缩小的代理图快速预览, 停下 0.15 s 后按原图 LANCZOS 精确重算.
    确定后 result = ((cx, cy, zoom), sharpen), 取消为 None"""

    def __init__(self, master, img, crop=None, sharpen=SHARPEN_DEFAULT, title='自定义裁剪',
                 target_width=TARGET_W, target_height=TARGET_H, batch_hint=''):
        import tkinter as tk
        from tkinter import ttk
        from PIL import ImageTk
        self.ImageTk = ImageTk
        self.src = img
        self.tw, self.th = target_width, target_height
        self.result = None
        self.job = None
        self.drag = None
        W, H = img.size
        _, self.crop = crop_box(img.size, crop, self.tw, self.th)

        win = self.win = tk.Toplevel(master)
        win.title(title)
        k = max(1.0, win.winfo_fpixels('1i') / 96.0)

        # 右侧预览: 输出分辨率放得下时 1:1, 否则等比缩小 (宽不超过屏幕的 45%, 高留出控件位置)
        sw, sh = win.winfo_screenwidth(), win.winfo_screenheight()
        self.pvs = min(1.0, sw * 0.45 / self.tw, (sh - 330 * k) / self.th)
        self.pvw, self.pvh = max(1, round(self.tw * self.pvs)), max(1, round(self.th * self.pvs))
        # 左侧显示用的原图缩略图 (小图最多放大 4 倍), 以及变暗版本; 整个窗口不超出屏幕
        slider = int(max(160 * k, min(360 * k, self.pvw - 120 * k)))
        maxw = min(int(720 * k), sw - max(self.pvw, int(420 * k)) - int(160 * k))
        maxh = min(int(560 * k), win.winfo_screenheight() - int(160 * k))
        s = min(max(maxw, 200) / W, max(maxh, 200) / H, 4.0)
        self.ds = s
        dw, dh = max(1, round(W * s)), max(1, round(H * s))
        self.disp = img.resize((dw, dh), Image.Resampling.BILINEAR)
        self.disp_dim = Image.blend(self.disp, Image.new('RGB', (dw, dh)), 0.6)
        # 拖动时的快速预览代理图 (长边最多 2048)
        ps = min(1.0, 2048 / max(W, H))
        self.proxy = img if ps >= 1.0 else img.resize((max(1, round(W * ps)), max(1, round(H * ps))),
                                                      Image.Resampling.BILINEAR)

        top = ttk.Frame(win, padding=8)
        top.pack(fill=tk.BOTH, expand=True)
        self.cv = tk.Canvas(top, width=dw, height=dh, bg='#202020', highlightthickness=0, cursor='fleur')
        self.cv.grid(row=0, column=0, sticky=tk.N)
        self.cv_img = self.cv.create_image(0, 0, anchor=tk.NW)
        self.cv_lines = [self.cv.create_line(0, 0, 0, 0, fill='#ffffff', dash=(2, 4)) for _ in range(4)]
        self.cv_rect = self.cv.create_rectangle(0, 0, 0, 0, outline='#ffd400', width=2)

        right = ttk.Frame(top)
        right.grid(row=0, column=1, sticky=tk.N, padx=(10, 0))
        scale = '1:1 像素' if self.pvs >= 1.0 else f'缩小到 {self.pvs * 100:.0f}% 显示'
        fpga = ', 即 FPGA 合成的画面' if (self.tw, self.th) == (TARGET_W, TARGET_H) else ''
        ttk.Label(right, text=f'转换结果 {self.tw}x{self.th} ({scale}{fpga})').pack(anchor=tk.W)
        self.pv = tk.Canvas(right, width=self.pvw, height=self.pvh, bg='#000000', highlightthickness=1,
                            highlightbackground='#888888')
        self.pv.pack(pady=4)
        self.pv_img = self.pv.create_image(0, 0, anchor=tk.NW)
        self.info = tk.StringVar()
        ttk.Label(right, textvariable=self.info, justify=tk.LEFT).pack(anchor=tk.W)

        ctl = ttk.Frame(right)
        ctl.pack(fill=tk.X, pady=6)
        self.zoom_var = tk.DoubleVar(value=self.crop[2])
        self.sharp_var = tk.DoubleVar(value=sharpen)
        self.zoom_txt = tk.StringVar()
        self.sharp_txt = tk.StringVar()
        ttk.Label(ctl, text='放大').grid(row=0, column=0, sticky=tk.W)
        ttk.Scale(ctl, from_=1.0, to=ZOOM_MAX, variable=self.zoom_var, length=slider,
                  command=lambda v: self.set_zoom(float(v))).grid(row=0, column=1, padx=6)
        ttk.Label(ctl, textvariable=self.zoom_txt, width=6).grid(row=0, column=2, sticky=tk.W)
        ttk.Label(ctl, text='锐化').grid(row=1, column=0, sticky=tk.W)
        ttk.Scale(ctl, from_=0, to=SHARPEN_MAX, variable=self.sharp_var, length=slider,
                  command=lambda v: self.changed()).grid(row=1, column=1, padx=6)
        ttk.Label(ctl, textvariable=self.sharp_txt, width=6).grid(row=1, column=2, sticky=tk.W)

        pre = ttk.Frame(right)
        pre.pack(fill=tk.X, pady=2)
        ttk.Label(pre, text='对齐:').pack(side=tk.LEFT)
        for text, cx, cy in (('居中', 0.5, 0.5), ('靠上', None, 0.0), ('靠下', None, 1.0),
                             ('靠左', 0.0, None), ('靠右', 1.0, None)):
            ttk.Button(pre, text=text, width=5,
                       command=lambda cx=cx, cy=cy: self.align(cx, cy)).pack(side=tk.LEFT, padx=2)
        ttk.Button(pre, text='整幅 (重置)', command=self.reset).pack(side=tk.LEFT, padx=6)

        ttk.Label(right, text='左键拖动裁剪框, 在框外单击把框移到该处; 滚轮或 +/- 缩放;\n'
                  '方向键微调 (按住 Shift 加快); Enter 确定, Esc 取消' + batch_hint,
                  foreground='#666666', justify=tk.LEFT).pack(anchor=tk.W, pady=(6, 0))
        bf = ttk.Frame(right)
        bf.pack(anchor=tk.E, pady=8)
        ttk.Button(bf, text='确定', command=self.ok).pack(side=tk.LEFT, padx=4)
        ttk.Button(bf, text='取消', command=self.cancel).pack(side=tk.LEFT, padx=4)

        self.cv.bind('<ButtonPress-1>', self.on_press)
        self.cv.bind('<B1-Motion>', self.on_drag)
        self.cv.bind('<ButtonRelease-1>', lambda e: self.render_exact())
        self.cv.bind('<MouseWheel>', lambda e: self.set_zoom(self.crop[2] * (1.1 ** (e.delta / 120))))
        self.cv.bind('<Button-4>', lambda e: self.set_zoom(self.crop[2] * 1.1))
        self.cv.bind('<Button-5>', lambda e: self.set_zoom(self.crop[2] / 1.1))
        for key, dx, dy in (('Left', -1, 0), ('Right', 1, 0), ('Up', 0, -1), ('Down', 0, 1)):
            win.bind(f'<{key}>', lambda e, dx=dx, dy=dy: self.nudge(dx, dy, e.state & 1))
        for key, f in (('plus', 1.1), ('equal', 1.1), ('KP_Add', 1.1), ('minus', 1 / 1.1), ('KP_Subtract', 1 / 1.1)):
            win.bind(f'<{key}>', lambda e, f=f: self.set_zoom(self.crop[2] * f))
        win.bind('<Return>', lambda e: self.ok())
        win.bind('<Escape>', lambda e: self.cancel())
        win.protocol('WM_DELETE_WINDOW', self.cancel)

        self.redraw(fast=False)
        if master.winfo_viewable():
            win.transient(master)
        win.focus_force()
        win.grab_set()
        master.wait_window(win)

    # ---------------- 坐标 ----------------
    def box(self):
        box, self.crop = crop_box(self.src.size, self.crop, self.tw, self.th)
        return box

    def move_to(self, cx, cy):
        self.crop = (cx, cy, self.crop[2])
        self.changed()

    def on_press(self, e):
        x0, y0, x1, y1 = [v * self.ds for v in self.box()]
        if not (x0 <= e.x <= x1 and y0 <= e.y <= y1):
            W, H = self.src.size
            self.move_to(e.x / self.ds / W, e.y / self.ds / H)
            x0, y0, x1, y1 = [v * self.ds for v in self.box()]
        self.drag = (e.x - (x0 + x1) / 2, e.y - (y0 + y1) / 2)

    def on_drag(self, e):
        if self.drag:
            W, H = self.src.size
            self.move_to((e.x - self.drag[0]) / self.ds / W, (e.y - self.drag[1]) / self.ds / H)

    def nudge(self, dx, dy, fast):
        W, H = self.src.size
        step = (10 if fast else 1) / self.ds          # 左侧显示的 1 / 10 个像素
        self.move_to(self.crop[0] + dx * step / W, self.crop[1] + dy * step / H)

    def set_zoom(self, z):
        self.crop = (self.crop[0], self.crop[1], z)
        self.changed()

    def align(self, cx, cy):
        self.move_to(self.crop[0] if cx is None else cx, self.crop[1] if cy is None else cy)
        self.render_exact()

    def reset(self):
        self.crop = (0.5, 0.5, 1.0)
        self.changed()
        self.render_exact()

    # ---------------- 绘制 ----------------
    def changed(self):
        self.redraw(fast=True)
        if self.job:
            self.win.after_cancel(self.job)
        self.job = self.win.after(150, self.render_exact)

    def render_exact(self):
        self.job = None
        self.redraw(fast=False)

    def sharpen(self):
        return int(round(float(self.sharp_var.get())))

    def redraw(self, fast):
        box = self.box()
        W, H = self.src.size
        # 左: 框外变暗 + 三分线
        b = [int(round(v * self.ds)) for v in box]
        frame = self.disp_dim.copy()
        frame.paste(self.disp.crop(b), (b[0], b[1]))
        self.disp_tk = self.ImageTk.PhotoImage(frame)
        self.cv.itemconfigure(self.cv_img, image=self.disp_tk)
        self.cv.coords(self.cv_rect, *b)
        x0, y0, x1, y1 = b
        for i, t in enumerate((1 / 3, 2 / 3)):
            self.cv.coords(self.cv_lines[i], x0 + (x1 - x0) * t, y0, x0 + (x1 - x0) * t, y1)
            self.cv.coords(self.cv_lines[i + 2], x0, y0 + (y1 - y0) * t, x1, y0 + (y1 - y0) * t)
        # 右: 转换结果
        if fast:
            # 拖动中: 代理图直接缩到预览尺寸 (近似)
            r = self.proxy.size[0] / W
            out = self.proxy.resize((self.pvw, self.pvh), Image.Resampling.BILINEAR,
                                    box=tuple(v * r for v in box))
            out = sharpen_image(out, self.sharpen())
        else:
            # 停下后: 按输出分辨率精确转换, 再缩到预览尺寸
            out = sharpen_image(self.src.resize((self.tw, self.th), Image.Resampling.LANCZOS, box=box),
                                self.sharpen())
            if self.pvs < 1.0:
                out = out.resize((self.pvw, self.pvh), Image.Resampling.LANCZOS)
        self.pv_tk = self.ImageTk.PhotoImage(out)
        self.pv.itemconfigure(self.pv_img, image=self.pv_tk)
        # 文字
        bw, bh = box[2] - box[0], box[3] - box[1]
        ratio = bw / self.tw
        note = ('  (源像素不够, 放大显示会发糊)' if ratio < 1.0 else '')
        self.info.set(f'原图 {W}x{H}, 裁剪框 {bw:.0f}x{bh:.0f} 位于 ({box[0]:.0f}, {box[1]:.0f})\n'
                      f'每个输出像素对应 {ratio:.2f} 个源像素{note}')
        self.zoom_var.set(self.crop[2])
        self.zoom_txt.set(f'{self.crop[2]:.2f}x')
        self.sharp_txt.set(f'{self.sharpen()}%')

    def ok(self):
        self.result = (self.crop, self.sharpen())
        self.win.destroy()

    def cancel(self):
        self.result = None
        self.win.destroy()


def edit_crop(img, crop=None, sharpen=SHARPEN_DEFAULT, title='自定义裁剪', master=None, batch_hint='',
              target_width=TARGET_W, target_height=TARGET_H):
    """打开裁剪窗口 (img 为 prepare 后的 RGB 图), 返回 ((cx, cy, zoom), sharpen) 或 None"""
    root = master or tk_root()
    try:
        return CropDialog(root, img, crop, sharpen, title, target_width, target_height,
                          batch_hint=batch_hint).result
    finally:
        if master is None:
            root.destroy()


#---------------------------------------------------------------------------
# 转换
#---------------------------------------------------------------------------
def convert_single_file(input_path, output_path, target_width=TARGET_W, target_height=TARGET_H, mode='crop',
                        crop=None, sharpen=SHARPEN_DEFAULT, edit=False):
    """
    将单张图片转换为指定分辨率的无压缩 24-bit BMP 格式。
    edit=True 时先打开裁剪窗口 (强制 crop 模式), 确定后才转换。
    """
    if not os.path.exists(input_path):
        print(f"[错误] 找不到输入文件: {input_path}")
        return False

    try:
        with Image.open(input_path) as img:
            if edit:
                res = edit_crop(prepare(img), crop, sharpen, f"自定义裁剪 - {os.path.basename(input_path)}",
                                target_width=target_width, target_height=target_height)
                if res is None:
                    print("[取消] 未转换")
                    return False
                crop, sharpen = res
                mode = 'crop'
                print(f"[裁剪] 下次可直接使用: {crop_text(crop, sharpen)}")
            # 转换为 RGB 模式 (即 24-bit，无 alpha 通道) 并调整大小
            img_resized = fit_image(img, target_width, target_height, mode, crop=crop, sharpen=sharpen)

            # 确保输出后缀为 .bmp
            if not output_path.lower().endswith('.bmp'):
                output_path += '.bmp'

            # 保存为无压缩的 BMP 文件
            img_resized.save(output_path, 'BMP')

            print(f"[成功] 转换完成: {input_path} -> {output_path} ({target_width}x{target_height})")
            return True
    except Exception as e:
        print(f"[失败] 转换 {input_path} 时发生错误: {e}")
        return False


def convert_to_bmp(input_dir, output_dir, target_width=TARGET_W, target_height=TARGET_H, mode='crop',
                   sharpen=SHARPEN_DEFAULT, edit=False):
    """
    批量将图片转换为指定分辨率的无压缩 24-bit BMP 格式。
    crop 模式下使用输入目录 crop_settings.json 中每张图保存的裁剪框 / 锐化 (没有的居中);
    edit=True 时逐张打开裁剪窗口, 确定后写回 crop_settings.json, 取消则停止后续转换。
    """
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)

    files = sorted(f for f in os.listdir(input_dir) if f.lower().endswith(SUPPORTED_FORMATS))

    if not files:
        print(f"在目录 '{input_dir}' 中没有找到支持的图片文件。")
        return

    print(f"找到 {len(files)} 个图片文件，开始转换...")
    settings = load_settings(input_dir)
    if edit:
        mode = 'crop'
    root = tk_root() if edit else None
    success_count = 0

    try:
        for n, filename in enumerate(files):
            input_path = os.path.join(input_dir, filename)
            # 生成输出文件名，确保后缀为 .bmp
            base_name = os.path.splitext(filename)[0]
            output_filename = f"{base_name}_{target_width}x{target_height}.bmp"
            output_path = os.path.join(output_dir, output_filename)
            st = settings.get(filename, {})
            crop, sh = st.get('crop'), st.get('sharpen', sharpen)

            try:
                with Image.open(input_path) as img:
                    if edit:
                        res = edit_crop(prepare(img), crop, sh, f"自定义裁剪 ({n + 1}/{len(files)}) - {filename}",
                                        master=root, batch_hint='\n取消 = 停止转换后面的图片 (已转换的保留)',
                                        target_width=target_width, target_height=target_height)
                        if res is None:
                            print("[取消] 停止批量转换")
                            break
                        crop, sh = res
                        settings[filename] = {'crop': [round(v, 4) for v in crop], 'sharpen': sh}
                        save_settings(input_dir, settings)
                    # 转换为 RGB 模式 (即 24-bit，无 alpha 通道) 并调整大小 (LANCZOS)
                    img_resized = fit_image(img, target_width, target_height, mode, crop=crop, sharpen=sh)

                    # 保存为无压缩的 BMP 文件
                    img_resized.save(output_path, 'BMP')

                    note = " (自定义裁剪)" if mode == 'crop' and crop else ""
                    print(f"[成功] {filename} -> {output_filename}{note}")
                    success_count += 1
            except Exception as e:
                print(f"[失败] 转换 {filename} 时发生错误: {e}")
    finally:
        if root is not None:
            root.destroy()

    print(f"\n转换完成！共成功转换 {success_count} 个文件。")
    print(f"请将 '{output_dir}' 目录下的所有 BMP 文件复制到 TF(SD) 卡的根目录中。")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="FPGA TF卡 BMP 图片转换工具 (默认 640x400, 24位无压缩)")
    parser.add_argument('input', nargs='?', help='输入的图片文件路径 (例如: 1.jpg)')
    parser.add_argument('output', nargs='?', help='输出的BMP文件路径 (例如: 1.bmp)')
    parser.add_argument('-s', '--size', type=size_arg, default=(TARGET_W, TARGET_H), metavar='WxH',
                        help=f'输出分辨率, 例如 1920x1080 (宽高 {SIZE_MIN}~{SIZE_MAX}, 默认 {TARGET_W}x{TARGET_H}); '
                             '常用分辨率见 --list-sizes')
    parser.add_argument('--list-sizes', action='store_true', help='列出常用分辨率后退出')
    parser.add_argument('--fit', choices=FIT_MODES, default='crop',
                        help='缩放方式: crop 等比裁剪铺满 (默认) / stretch 拉伸 / pad 补黑边')
    parser.add_argument('--crop', type=parse_crop, default=None, metavar='CX,CY[,ZOOM]',
                        help='单文件: 自定义裁剪框中心 (相对宽高 0~1) 与放大倍数 (1~8), 例如 0.5,0.3,1.5')
    parser.add_argument('-e', '--edit', action='store_true',
                        help='打开裁剪窗口: 拖动裁剪框并实时预览转换效果 (批量模式逐张打开, 结果存入 '
                             f'input_images/{SETTINGS_NAME})')
    parser.add_argument('--sharpen', type=int, default=SHARPEN_DEFAULT, metavar='N',
                        help=f'缩小后 USM 锐化强度 0~{SHARPEN_MAX} (%%, 默认 {SHARPEN_DEFAULT}, 0 为不锐化)')

    args = parser.parse_args()
    if args.list_sizes:
        for group, rs in RES_GROUPS:
            print(f"[{group}]")
            for w, h, name in rs:
                print(f"  {w:>4}x{h:<5} {aspect_text(w, h):<16} {name}")
        sys.exit(0)
    tw, th = args.size

    # 如果提供了输入和输出参数，则进行单文件转换
    if args.input and args.output:
        convert_single_file(args.input, args.output, tw, th, mode=args.fit, crop=args.crop,
                            sharpen=args.sharpen, edit=args.edit)
    else:
        # 否则回退到默认的批量转换模式
        current_dir = os.path.dirname(os.path.abspath(__file__))
        default_input = os.path.join(current_dir, "input_images")
        default_output = os.path.join(current_dir, "output_bmp")

        print("=== FPGA TF卡 BMP 图片转换工具 ===")
        print(f"输出: {tw}x{th}, 24位无压缩 BMP (用 --size 宽x高 修改, --list-sizes 查看常用分辨率)")
        print("-" * 40)
        print("提示: 你也可以通过命令行参数指定单张图片进行转换，格式如下:")
        print("python convert_images_to_bmp.py <输入文件> <输出文件> [--edit]")
        print("加 --edit 逐张打开裁剪窗口, 自定义裁剪框并预览效果")
        print("-" * 40)

        # 检查默认输入目录是否存在，不存在则创建
        if not os.path.exists(default_input):
            os.makedirs(default_input)
            print(f"已创建默认输入目录: {default_input}")
            print(f"请将你需要转换的图片放入该目录中，然后重新运行本脚本。")
            sys.exit(0)

        # 运行批量转换
        convert_to_bmp(default_input, default_output, tw, th, mode=args.fit, sharpen=args.sharpen, edit=args.edit)
