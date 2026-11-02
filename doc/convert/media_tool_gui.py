# -*- coding: utf-8 -*-
"""
FPGA 多媒体播放器 素材工具 (图形界面)

把同目录下几个命令行脚本的功能集中到一个窗口里:
  图片   : 任意图片 -> 24bit BMP (默认 640x400, 输出分辨率可自定义; 拉伸 / 裁剪铺满 / 补黑边), 可调整播放顺序
           (FPGA 放大成 1280x800 输出, 16:10 显示器全屏无黑边)
           每次转换输出到新的子目录 output_bmp/<宽x高>_<日期_时间>/, 文件名 01_原名_<宽x高>.bmp, 不覆盖以前的结果
  音乐   : 任意 WAV (装有 ffmpeg 时也可 mp3/flac) -> 16bit PCM WAV, 可试听
           输出到 output_wav/<原名>_<采样率>Hz_<单声道|立体声>.wav, 重名时加 _2 _3 ..., 不覆盖; 写卡时改名为 MUSIC.WAV
  字幕   : UTF-8 文本 -> SUB.TXT + SUB.FNT, 按 FPGA 显示效果实时预览
  写入TF卡: 清空 TF 卡并写入 IMG01~16.BMP / MUSIC.WAV / SUB.TXT / SUB.FNT

只依赖 Python 3.8+ 自带的 tkinter 和 Pillow (pip install Pillow).
用法: python media_tool_gui.py   (Windows 下也可双击 media_tool_gui.bat)
"""
import os
import re
import sys
import time
import queue
import string
import threading
import traceback

import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from tkinter.scrolledtext import ScrolledText

try:
    from PIL import Image, ImageTk
except ImportError:
    tk.Tk().withdraw()
    messagebox.showerror("缺少依赖", "需要 Pillow, 请先执行:\n\npip install Pillow")
    sys.exit(1)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import convert_images_to_bmp as cimg      # noqa: E402
import convert_wav as cwav                # noqa: E402
import make_subtitle as msub              # noqa: E402
import sync_to_sd as ssd                  # noqa: E402

try:
    import winsound
except ImportError:
    winsound = None

FONT_ROM = os.path.join(HERE, "..", "..", "src", "user_source", "hdl_source", "player", "osd_font_rom.v")
IMG_TYPES = [("图片", " ".join("*" + e for e in cimg.SUPPORTED_FORMATS)), ("所有文件", "*.*")]
RATES = ["48000", "44100", "32000", "22050", "16000", "11025", "8000", "保持原采样率"]
KEEP_RATE = RATES[-1]
FIT_NAMES = {"stretch": "拉伸铺满 (可能变形)", "crop": "等比放大, 居中裁剪", "pad": "等比缩小, 补黑边"}
FIT_SHORT = {"stretch": "拉伸", "crop": "裁剪铺满", "pad": "补黑边"}


def latest_dir(root):
    """root 下最近修改的含 BMP 的子目录 (每次图片转换一个); 没有时返回 root 本身 (兼容旧版直接输出的 BMP)"""
    try:
        subs = [os.path.join(root, n) for n in os.listdir(root)]
        subs = [d for d in subs if os.path.isdir(d) and any(x.lower().endswith(".bmp") for x in os.listdir(d))]
    except OSError:
        return root
    return max(subs, key=os.path.getmtime) if subs else root


def latest_file(root, ext, fallback):
    """root 下最近修改的 ext 文件; 没有时返回 fallback"""
    try:
        fs = [os.path.join(root, n) for n in os.listdir(root) if n.lower().endswith(ext)]
    except OSError:
        fs = []
    return max(fs, key=os.path.getmtime) if fs else fallback


def unique_path(p):
    """p 已存在时在扩展名前加 _2, _3 ..., 不覆盖已有文件 / 目录"""
    base, ext = os.path.splitext(p)
    n = 2
    while os.path.exists(p):
        p = f"{base}_{n}{ext}"
        n += 1
    return p


def human(n):
    if n >= 1048576:
        return f"{n / 1048576:.1f} MB"
    return f"{n / 1024:.0f} KB" if n >= 1024 else f"{n} B"


EXTRA_FONTS = ["simkai.ttf", "simfang.ttf", "Deng.ttf", "Dengb.ttf", "msyhbd.ttc", "STSONG.TTF", "STKAITI.TTF"]


def load_ascii_rom(log):
    """从 osd_font_rom.v 读取 FPGA 内置 ASCII 字库, 返回 128 个 16 行字模; 读不到时用 Pillow 默认字体近似"""
    glyphs = [bytearray(16) for _ in range(128)]
    try:
        with open(FONT_ROM, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"\s*13'h([0-9a-fA-F]+):\s*q\s*<=\s*8'h([0-9a-fA-F]+);", line)
                if m:
                    a = int(m.group(1), 16)
                    if a < 128 * 16:
                        glyphs[a >> 4][a & 15] = int(m.group(2), 16)
        return glyphs
    except OSError:
        log(f"[提示] 找不到 {os.path.normpath(FONT_ROM)}, ASCII 预览使用近似字体")
    from PIL import ImageDraw, ImageFont
    font = ImageFont.load_default()
    for c in range(0x21, 0x7F):
        im = Image.new("1", (8, 16), 0)
        ImageDraw.Draw(im).text((1, 2), chr(c), fill=1, font=font)
        glyphs[c] = bytearray(sum(0x80 >> x for x in range(8) if im.getpixel((x, r))) for r in range(16))
    return glyphs


def glyph_rows(code, fnt, ascii_rom):
    """与 video_compositor 一致: <0x20 显示空格, 0x20~0x7F 内置字库, 0x80~0xFF 用户字库"""
    if code >= 0x80:
        return fnt[(code - 0x80) * 16:(code - 0x80) * 16 + 16]
    if code < 0x20:
        return ascii_rom[0x20]
    return ascii_rom[code]


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("FPGA 多媒体播放器 素材工具")
        self.k = max(1.0, self.winfo_fpixels("1i") / 96.0)     # 高分屏缩放系数
        sw, sh = self.winfo_screenwidth(), self.winfo_screenheight()
        self.geometry(f"{min(int(1000 * self.k), sw - 40)}x{min(int(860 * self.k), sh - 80)}")
        self.minsize(min(int(860 * self.k), sw - 40), min(int(520 * self.k), sh - 80))
        self.msgq = queue.Queue()
        self.busy = False

        # 各页面的输出位置 (每次转换生成新的子目录 / 文件, 不覆盖); 写入 TF 卡页面默认取最近一次的结果
        self.img_out = tk.StringVar(value=os.path.join(HERE, "output_bmp"))
        self.wav_dir = tk.StringVar(value=os.path.join(HERE, "output_wav"))
        self.sd_img = tk.StringVar(value=latest_dir(self.img_out.get()))
        self.sd_wav = tk.StringVar(value=latest_file(self.wav_dir.get(), ".wav", os.path.join(HERE, "MUSIC.WAV")))
        self.sub_out = tk.StringVar(value=HERE)

        style = ttk.Style(self)
        if "vista" in style.theme_names():
            style.theme_use("vista")
        style.configure("Big.TButton", padding=(14, 6))
        style.configure("Hint.TLabel", foreground="#666")
        style.configure("Treeview", rowheight=int(22 * self.k))

        pw = ttk.PanedWindow(self, orient=tk.VERTICAL)
        pw.pack(fill=tk.BOTH, expand=True, padx=6, pady=6)
        self.nb = ttk.Notebook(pw)
        pw.add(self.nb, weight=1)
        logf = ttk.LabelFrame(pw, text="日志 (拖动上边框可调高度)")
        pw.add(logf, weight=0)                  # 日志保持 4 行高, 窗口变大时多出的空间都给页面
        self.log_box = ScrolledText(logf, height=4, state=tk.DISABLED, font=("Consolas", 9))
        self.log_box.pack(fill=tk.BOTH, expand=True)
        self.status = tk.StringVar(value="就绪")
        bar = ttk.Frame(self)
        bar.pack(fill=tk.X, padx=6, pady=(0, 4))
        ttk.Label(bar, textvariable=self.status).pack(side=tk.LEFT)
        self.prog = ttk.Progressbar(bar, length=220, mode="determinate")
        self.prog.pack(side=tk.RIGHT)

        self.build_image_tab()
        self.build_music_tab()
        self.build_sub_tab()
        self.build_sync_tab()
        self.after(100, self.poll)
        self.log("TF 卡要求: FAT32; 图片 / 音乐 / 字幕分别放 IMG / MUSIC / SUB 文件夹, 根目录 PLAY.CFG 为播放顺序和每张秒数 "
                 "(“写入TF卡”页自动生成; 旧版全部放根目录也可). BMP 任意分辨率 16~4096, 最多 16 张, 640x400 加载最快")

    # ------------------------------------------------------------------ 公共
    def page(self, text, padding):
        """新建一个可上下滚动的页面, 返回放内容的 Frame.
        内容比可见区域矮时撑满 (列表等仍可随窗口伸缩), 比可见区域高时出现滚动条, 鼠标滚轮滚动页面"""
        outer = ttk.Frame(self.nb)
        self.nb.add(outer, text=text)
        cv = tk.Canvas(outer, highlightthickness=0, borderwidth=0)
        sb = ttk.Scrollbar(outer, orient=tk.VERTICAL, command=cv.yview)
        cv.configure(yscrollcommand=sb.set)
        cv.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        inner = ttk.Frame(cv, padding=padding)
        win = cv.create_window(0, 0, anchor=tk.NW, window=inner)

        def fit(_e=None):
            need = inner.winfo_reqheight()
            h = max(need, cv.winfo_height())
            cv.itemconfigure(win, width=cv.winfo_width(), height=h)
            cv.configure(scrollregion=(0, 0, cv.winfo_width(), h))
            if need > cv.winfo_height() + 1:
                if not sb.winfo_ismapped():
                    sb.pack(side=tk.RIGHT, fill=tk.Y, before=cv)
            elif sb.winfo_ismapped():
                sb.pack_forget()
                cv.yview_moveto(0)
        cv.bind("<Configure>", fit)
        inner.bind("<Configure>", fit)

        def wheel(e):
            w = self.winfo_containing(e.x_root, e.y_root)
            if w is None or not sb.winfo_ismapped() or not str(w).startswith(str(outer)):
                return
            if w.winfo_class() in ("Listbox", "Text", "Treeview", "Canvas") and w is not cv:
                return                      # 列表 / 文本 / 预览图自己处理滚轮
            cv.yview_scroll(int(-e.delta / 120) or (-1 if e.delta > 0 else 1), "units")
        self.bind_all("<MouseWheel>", wheel, add="+")
        return inner

    def log(self, msg):
        """可在任意线程调用"""
        self.msgq.put(("log", str(msg)))

    def poll(self):
        try:
            while True:
                kind, val = self.msgq.get_nowait()
                if kind == "log":
                    self.log_box.configure(state=tk.NORMAL)
                    self.log_box.insert(tk.END, val + "\n")
                    self.log_box.see(tk.END)
                    self.log_box.configure(state=tk.DISABLED)
                elif kind == "prog":
                    self.prog.configure(value=val)
                elif kind == "call":
                    val()
        except queue.Empty:
            pass
        self.after(80, self.poll)

    def run_bg(self, title, func, done=None):
        """在后台线程执行 func(); 完成后在界面线程调用 done(result)"""
        if self.busy:
            messagebox.showinfo("请稍候", "上一个任务还在进行中")
            return
        self.busy = True
        self.status.set(title + " ...")
        self.prog.configure(value=0)

        def work():
            res, err = None, None
            try:
                res = func()
            except Exception as e:  # 在日志中报告, 不让线程静默退出
                err = e
                self.log(f"[错误] {e}")
                if not isinstance(e, (ValueError, OSError)):
                    self.log(traceback.format_exc())

            def fin():
                self.busy = False
                self.status.set(f"{title}: " + ("失败" if err else "完成"))
                self.prog.configure(value=0 if err else 100)
                if err:
                    messagebox.showerror(title, str(err))
                elif done:
                    done(res)
            self.msgq.put(("call", fin))
        threading.Thread(target=work, daemon=True).start()

    @staticmethod
    def path_row(parent, row, label, var, browse):
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky=tk.W, padx=4, pady=3)
        ttk.Entry(parent, textvariable=var).grid(row=row, column=1, sticky=tk.EW, padx=4, pady=3)
        ttk.Button(parent, text="浏览...", command=browse).grid(row=row, column=2, padx=4, pady=3)

    # ------------------------------------------------------------------ 图片
    # 每张图的转换参数 = 默认设置 (self.img_glob), 或该图的单独设置 (self.img_over[路径]).
    # 右侧面板编辑哪一份由 "单独设置选中的图片" 决定: 勾选时修改选中的图, 不勾选时修改默认设置.
    def build_image_tab(self):
        f = self.page("  图片  ", 8)
        self.img_files = []
        self.img_fit = tk.StringVar(value="crop")
        self.img_prev_tk = None
        self.img_sharp = tk.DoubleVar(value=cimg.SHARPEN_DEFAULT)
        self.img_prev_job = None
        self.img_size = tk.StringVar(value=cimg.res_label(cimg.TARGET_W, cimg.TARGET_H, "默认"))  # 输出分辨率
        self.img_size_note = tk.StringVar()
        self.img_res_group = tk.StringVar(value="全部")
        self.img_glob = {"size": (cimg.TARGET_W, cimg.TARGET_H), "fit": "crop", "sharp": cimg.SHARPEN_DEFAULT,
                         "dur": ssd.DUR_DEFAULT}
        self.img_dur = tk.StringVar(value=str(ssd.DUR_DEFAULT))
        self.img_over = {}                                   # 路径 -> {size, fit, sharp, crop}
        self.img_own = tk.BooleanVar(value=False)
        self.img_edit = []                                   # 单独设置时正在编辑的图片路径
        self.img_scope = tk.StringVar()
        self.img_loading = False                             # 切换选中图片时装载面板, 不回写

        left = ttk.Frame(f)
        left.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        ttk.Label(left, text="待转换图片 (列表顺序 = 播放顺序, 最多 16 张):").pack(anchor=tk.W)
        lf = ttk.Frame(left)
        lf.pack(fill=tk.BOTH, expand=True, pady=4)
        self.img_list = tk.Listbox(lf, selectmode=tk.EXTENDED, activestyle="none", font=("Microsoft YaHei UI", 9))
        sb = ttk.Scrollbar(lf, command=self.img_list.yview)
        self.img_list.configure(yscrollcommand=sb.set)
        self.img_list.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        sb.pack(side=tk.LEFT, fill=tk.Y)
        self.img_list.bind("<<ListboxSelect>>", lambda e: self.img_select())
        self.img_list.bind("<Double-Button-1>", lambda e: self.img_edit_crop())

        btns = ttk.Frame(left)
        btns.pack(fill=tk.X)
        for text, cmd in (("添加图片...", self.img_add_files), ("添加文件夹...", self.img_add_dir),
                          ("上移", lambda: self.img_move(-1)), ("下移", lambda: self.img_move(1)),
                          ("移除", self.img_remove), ("清空", self.img_clear)):
            ttk.Button(btns, text=text, command=cmd).pack(side=tk.LEFT, padx=2)

        right = ttk.Frame(f)
        right.pack(side=tk.LEFT, fill=tk.Y, padx=(10, 0))
        self.img_prev_title = tk.StringVar()
        ttk.Label(right, textvariable=self.img_prev_title).pack(anchor=tk.W)
        self.pw, self.ph = int(320 * self.k), int(200 * self.k)
        self.img_canvas = tk.Canvas(right, width=self.pw, height=self.ph, bg="#202020", highlightthickness=1,
                                    highlightbackground="#888")
        self.img_canvas.pack(pady=4)
        self.img_info = tk.StringVar(value="选择左侧图片查看效果")
        ttk.Label(right, textvariable=self.img_info, style="Hint.TLabel").pack(anchor=tk.W)

        scf = ttk.LabelFrame(right, text="设置对象", padding=6)
        scf.pack(fill=tk.X, pady=(6, 0))
        scr = ttk.Frame(scf)
        scr.pack(fill=tk.X)
        ttk.Checkbutton(scr, text="单独设置选中的图片", variable=self.img_own,
                        command=self.img_own_toggled).pack(side=tk.LEFT)
        ttk.Button(scr, text="全部恢复默认", command=self.img_reset_all).pack(side=tk.RIGHT)
        ttk.Label(scf, textvariable=self.img_scope, style="Hint.TLabel", justify=tk.LEFT,
                  wraplength=int(330 * self.k)).pack(anchor=tk.W, pady=(4, 0))

        szf = ttk.LabelFrame(right, text="输出分辨率", padding=6)
        szf.pack(fill=tk.X, pady=(6, 0))
        szr = ttk.Frame(szf)
        szr.pack(fill=tk.X)
        groups = ["全部"] + [g for g, _ in cimg.RES_GROUPS]
        gcb = ttk.Combobox(szr, textvariable=self.img_res_group, values=groups, width=11, state="readonly")
        gcb.pack(side=tk.LEFT)
        gcb.bind("<<ComboboxSelected>>", lambda e: self.img_group_changed())
        self.img_size_cb = cb = ttk.Combobox(szr, textvariable=self.img_size, values=cimg.RES_PRESETS,
                                             width=24, height=20)
        cb.pack(side=tk.LEFT, padx=4)
        cb.bind("<<ComboboxSelected>>", lambda e: self.img_size_changed())
        cb.bind("<Return>", lambda e: self.img_size_changed())
        cb.bind("<FocusOut>", lambda e: self.img_size_changed())
        ttk.Button(szr, text="横竖互换", command=self.img_size_swap).pack(side=tk.LEFT)
        ttk.Label(szf, text=f"左边选分类, 右边选分辨率; 也可直接输入 宽x高 后回车 ({cimg.SIZE_MIN}~{cimg.SIZE_MAX})",
                  style="Hint.TLabel").pack(anchor=tk.W, pady=(4, 0))
        ttk.Label(szf, textvariable=self.img_size_note, style="Hint.TLabel", justify=tk.LEFT,
                  wraplength=int(330 * self.k)).pack(anchor=tk.W, pady=(4, 0))

        fitf = ttk.LabelFrame(right, text="缩放方式", padding=6)
        fitf.pack(fill=tk.X, pady=6)
        for k, v in FIT_NAMES.items():
            ttk.Radiobutton(fitf, text=v, value=k, variable=self.img_fit,
                            command=self.img_fit_changed).pack(anchor=tk.W)
        cf = ttk.Frame(fitf)
        cf.pack(fill=tk.X, pady=(4, 0))
        ttk.Button(cf, text="自定义裁剪框...", command=self.img_edit_crop).pack(side=tk.LEFT)
        ttk.Button(cf, text="恢复居中", command=self.img_reset_crop).pack(side=tk.LEFT, padx=4)
        ttk.Label(fitf, text="双击列表中的图片也可打开; 拖动裁剪框, 右侧实时预览 (自动变为该图的单独设置)",
                  style="Hint.TLabel").pack(anchor=tk.W)
        shf = ttk.Frame(fitf)
        shf.pack(fill=tk.X, pady=(4, 0))
        ttk.Label(shf, text="锐化").pack(side=tk.LEFT)
        self.img_sharp_txt = tk.StringVar(value=f"{cimg.SHARPEN_DEFAULT}%")
        ttk.Scale(shf, from_=0, to=cimg.SHARPEN_MAX, variable=self.img_sharp, length=int(150 * self.k),
                  command=lambda v: self.img_sharp_changed()).pack(side=tk.LEFT, padx=4)
        ttk.Label(shf, textvariable=self.img_sharp_txt, width=5).pack(side=tk.LEFT)

        plf = ttk.LabelFrame(right, text="播放", padding=6)
        plf.pack(fill=tk.X, pady=(0, 6))
        ttk.Label(plf, text="显示时长").pack(side=tk.LEFT)
        dsp = ttk.Spinbox(plf, from_=1, to=ssd.DUR_MAX, width=5, textvariable=self.img_dur,
                          command=self.img_dur_changed)
        dsp.pack(side=tk.LEFT, padx=4)
        dsp.bind("<Return>", lambda e: self.img_dur_changed())
        dsp.bind("<FocusOut>", lambda e: self.img_dur_changed())
        ttk.Label(plf, text="秒  (自动轮播时停留的时间, 写入 TF 卡播放列表 PLAY.CFG)",
                  style="Hint.TLabel").pack(side=tk.LEFT)

        of = ttk.Frame(right)
        of.pack(fill=tk.X, pady=4)
        of.columnconfigure(1, weight=1)
        self.path_row(of, 0, "输出目录", self.img_out, self.img_pick_out)
        ttk.Button(right, text="开始转换", style="Big.TButton", command=self.img_convert).pack(pady=8)
        ttk.Label(right, text="每次转换输出到新的子目录 <宽x高>_<日期_时间> (各图分辨率不同时为 混合分辨率_<日期_时间>),\n"
                              "不覆盖以前的结果; 文件名为 01_原名_<宽x高>.bmp, 02_原名_<宽x高>.bmp ...\n"
                              "写入 TF 卡时默认用最近一次的子目录, 按此顺序命名为 IMG01~IMG16.BMP",
                  style="Hint.TLabel", justify=tk.LEFT, wraplength=int(460 * self.k)).pack(anchor=tk.W)
        self.img_size_changed(log=False)
        self.img_select()

    # ---- 参数 ----
    def img_cfg(self, p):
        """该图的转换参数 {size, fit, sharp, crop}"""
        o = self.img_over.get(p)
        return o if o else dict(self.img_glob, crop=None)

    def img_params(self, p):
        """((宽, 高), 缩放方式, 裁剪框, 锐化); 裁剪框只在 "居中裁剪" 方式下生效"""
        c = self.img_cfg(p)
        return c["size"], c["fit"], (c["crop"] if c["fit"] == "crop" else None), c["sharp"]

    def img_desc(self, c):
        w, h = c["size"]
        s = f"{w}x{h} · {FIT_SHORT[c['fit']]} · 锐化 {c['sharp']}% · {c['dur']} 秒"
        return s + (" · 自定义裁剪框" if c.get("crop") and c["fit"] == "crop" else "")

    def img_panel(self):
        """面板上当前的设置; 分辨率无效时返回 None"""
        t = self.img_target()
        if t is None:
            return None
        return {"size": t, "fit": self.img_fit.get(), "sharp": int(round(float(self.img_sharp.get()))),
                "dur": self.img_dur_val()}

    def img_dur_val(self):
        try:
            return max(1, min(ssd.DUR_MAX, int(float(self.img_dur.get()))))
        except ValueError:
            return self.img_glob["dur"]

    def img_dur_changed(self):
        self.img_dur.set(str(self.img_dur_val()))
        self.img_store()
        self.img_preview()

    def img_store(self):
        """把面板设置写回: 单独设置时写入正在编辑的图, 否则写入默认设置"""
        if self.img_loading:
            return
        cur = self.img_panel()
        if cur is None:
            return
        if self.img_own.get() and self.img_edit:
            for p in self.img_edit:
                self.img_over.setdefault(p, dict(self.img_glob, crop=None)).update(cur)
        else:
            self.img_glob = cur
        self.img_refresh(keep=True)
        self.img_scope_update()

    def img_load(self, c):
        """把一份设置装进面板 (不回写)"""
        self.img_loading = True
        try:
            self.img_size.set(f"{c['size'][0]}x{c['size'][1]}")
            self.img_size_changed(log=False)
            self.img_fit.set(c["fit"])
            self.img_sharp.set(c["sharp"])
            self.img_sharp_txt.set(f"{c['sharp']}%")
            self.img_dur.set(str(c["dur"]))
        finally:
            self.img_loading = False

    def img_scope_update(self):
        n_own = sum(1 for p in self.img_files if p in self.img_over)
        g = self.img_desc(dict(self.img_glob, crop=None))
        if self.img_own.get() and self.img_edit:
            who = (os.path.basename(self.img_edit[0]) if len(self.img_edit) == 1
                   else f"选中的 {len(self.img_edit)} 张图片")
            self.img_scope.set(f"正在修改: {who} (单独设置)\n默认: {g}")
        else:
            self.img_scope.set(f"正在修改: 默认设置 (作用于 {len(self.img_files) - n_own} 张图片)\n"
                               f"默认: {g}  |  单独设置 {n_own} 张")

    def img_select(self):
        """切换选中图片: 有单独设置的图显示它自己的设置, 否则显示默认设置"""
        sel = self.img_sel()
        self.img_edit = [self.img_files[i] for i in sel]
        own = bool(sel) and self.img_files[sel[0]] in self.img_over
        self.img_own.set(own)
        self.img_load(self.img_over[self.img_files[sel[0]]] if own else self.img_glob)
        self.img_scope_update()
        self.img_preview()

    def img_own_toggled(self):
        sel = self.img_sel()
        if not sel:
            self.img_own.set(False)
            messagebox.showinfo("单独设置", "请先在左侧选中要单独设置的图片 (可按住 Ctrl / Shift 多选)")
            return
        self.img_edit = [self.img_files[i] for i in sel]
        if self.img_own.get():
            cur = self.img_panel() or dict(self.img_glob)
            for p in self.img_edit:
                self.img_over[p] = dict(cur, crop=None)
            self.log(f"{len(self.img_edit)} 张图片改为单独设置, 之后修改的分辨率 / 缩放 / 锐化只作用于它们")
        else:
            for p in self.img_edit:
                self.img_over.pop(p, None)
            self.img_load(self.img_glob)
            self.log(f"{len(self.img_edit)} 张图片恢复为默认设置")
        self.img_refresh(keep=True)
        self.img_scope_update()
        self.img_preview()

    def img_reset_all(self):
        if not self.img_over:
            return
        if not messagebox.askyesno("全部恢复默认", f"清除 {len(self.img_over)} 张图片的单独设置 (含自定义裁剪框)?"):
            return
        self.img_over = {}
        self.img_refresh(keep=True)
        self.img_select()
        self.log("已清除所有图片的单独设置")

    # ---- 列表 ----
    def img_refresh(self, keep=False):
        sel = self.img_sel() if keep else []
        self.img_list.delete(0, tk.END)
        for i, p in enumerate(self.img_files):
            mark = "" if i < ssd.MAX_IMG else "   (超过 16 张, 不会写入 TF 卡)"
            own = f"   [单独: {self.img_desc(self.img_over[p])}]" if p in self.img_over else ""
            self.img_list.insert(tk.END, f"{i + 1:2d}. {os.path.basename(p)}{own}{mark}")
        for i in sel:
            if i < len(self.img_files):
                self.img_list.selection_set(i)

    def img_add(self, paths):
        new = [p for p in paths if p.lower().endswith(cimg.SUPPORTED_FORMATS) and p not in self.img_files]
        self.img_files += new
        self.img_refresh()
        if new:
            self.img_list.selection_clear(0, tk.END)
            self.img_list.selection_set(len(self.img_files) - len(new))
        self.img_select()
        self.log(f"添加 {len(new)} 张图片, 共 {len(self.img_files)} 张")

    def img_add_files(self):
        self.img_add(list(filedialog.askopenfilenames(title="选择图片", filetypes=IMG_TYPES)))

    def img_add_dir(self):
        d = filedialog.askdirectory(title="选择图片文件夹")
        if d:
            self.img_add([os.path.join(d, n) for n in sorted(os.listdir(d))])

    def img_sel(self):
        return list(self.img_list.curselection())

    def img_move(self, step):
        sel = self.img_sel()
        if not sel:
            return
        order = sel if step < 0 else sel[::-1]
        if (step < 0 and order[0] == 0) or (step > 0 and order[0] == len(self.img_files) - 1):
            return
        for i in order:
            self.img_files[i], self.img_files[i + step] = self.img_files[i + step], self.img_files[i]
        self.img_refresh()
        for i in sel:
            self.img_list.selection_set(i + step)

    def img_remove(self):
        for i in reversed(self.img_sel()):
            self.img_over.pop(self.img_files[i], None)
            del self.img_files[i]
        self.img_refresh()
        self.img_select()

    def img_clear(self):
        self.img_files = []
        self.img_over = {}
        self.img_refresh()
        self.img_select()

    def img_pick_out(self):
        d = filedialog.askdirectory(title="选择输出目录", initialdir=self.img_out.get())
        if d:
            self.img_out.set(os.path.normpath(d))

    # ---- 面板控件 ----
    def img_target(self):
        """面板上的输出分辨率 (w, h); 输入无效时返回 None"""
        try:
            return cimg.parse_size(self.img_size.get())
        except ValueError:
            return None

    def img_group_changed(self):
        g = self.img_res_group.get()
        rs = [r for gn, lst in cimg.RES_GROUPS if g in ("全部", gn) for r in lst]
        self.img_size_cb.configure(values=[cimg.res_label(*r) for r in rs])
        if rs:
            self.img_size.set(cimg.res_label(*rs[0]))
            self.img_size_changed()

    def img_size_swap(self):
        t = self.img_target()
        if t:
            self.img_size.set(f"{t[1]}x{t[0]}")
            self.img_size_changed()

    def img_size_changed(self, log=True):
        try:
            w, h = cimg.parse_size(self.img_size.get())
        except ValueError as e:
            self.img_size_note.set(f"[无效] {e}")
            self.img_prev_title.set("转换效果预览:")
            return
        # 手动输入的尺寸如果在常用列表里, 补上名称
        if self.img_size.get().strip() == f"{w}x{h}":
            for _, lst in cimg.RES_GROUPS:
                hit = [r for r in lst if r[:2] == (w, h)]
                if hit:
                    self.img_size.set(cimg.res_label(*hit[0]))
                    break
        self.img_prev_title.set(f"转换效果预览 ({w}x{h} 缩小显示):")
        mb = ((w * 3 + 3) // 4 * 4 * h + 54) / 1048576
        self.img_size_note.set(f"{w}x{h}, 宽高比 {cimg.aspect_text(w, h)}, {'横屏' if w >= h else '竖屏'}, "
                               f"24 位 BMP 每张约 {mb:.2f} MB")
        if log and not self.img_loading:
            old = self.img_over[self.img_edit[0]]["size"] if (self.img_own.get() and self.img_edit) \
                else self.img_glob["size"]
            self.img_store()
            if old != (w, h):
                who = f"{len(self.img_edit)} 张选中图片" if self.img_own.get() and self.img_edit else "默认设置"
                self.log(f"图片输出分辨率 ({who}): {w}x{h} ({cimg.aspect_text(w, h)})")
            self.img_preview()

    def img_fit_changed(self):
        self.img_store()
        self.img_preview()

    def img_sharp_changed(self):
        self.img_sharp_txt.set(f"{int(round(float(self.img_sharp.get())))}%")
        self.img_store()
        if self.img_prev_job:
            self.after_cancel(self.img_prev_job)
        self.img_prev_job = self.after(200, self.img_preview)

    def img_edit_crop(self):
        sel = self.img_sel()
        if not sel:
            messagebox.showinfo("自定义裁剪", "请先在左侧选中一张图片")
            return
        i = sel[0]
        p = self.img_files[i]
        c = self.img_cfg(p)
        try:
            with Image.open(p) as im:
                src = cimg.prepare(im)
        except Exception as e:
            messagebox.showerror("自定义裁剪", f"无法打开: {e}")
            return
        res = cimg.CropDialog(self, src, c.get("crop"), c["sharp"], f"自定义裁剪 - {os.path.basename(p)}",
                              *c["size"]).result
        if res is None:
            return
        o = self.img_over.setdefault(p, dict(c))
        o.update(fit="crop", crop=res[0], sharp=res[1])
        self.img_refresh()
        self.img_list.selection_set(i)
        self.img_select()
        self.log(f"{os.path.basename(p)}: 自定义裁剪 {cimg.crop_text(*res)} (该图改为单独设置)")

    def img_reset_crop(self):
        sel = self.img_sel()
        for i in sel:
            o = self.img_over.get(self.img_files[i])
            if o:
                o["crop"] = None
        self.img_refresh(keep=True)
        self.img_preview()

    def img_preview(self):
        self.img_prev_job = None
        self.img_canvas.delete("all")
        sel = self.img_sel()
        if not sel:
            self.img_info.set("选择左侧图片查看效果")
            return
        p = self.img_files[sel[0]]
        if self.img_target() is None:
            self.img_info.set("输出分辨率无效")
            return
        (tw, th), mode, crop, sharp = self.img_params(p)
        try:
            with Image.open(p) as im:
                size = im.size
                out = cimg.fit_image(im, tw, th, mode, crop=crop, sharpen=sharp)
        except Exception as e:
            self.img_info.set(f"无法打开: {e}")
            return
        # 按输出比例放进预览框 (比例不是 16:10 时上下或左右留空)
        s = min(self.pw / tw, self.ph / th)
        dw, dh = max(1, round(tw * s)), max(1, round(th * s))
        self.img_prev_tk = ImageTk.PhotoImage(out.resize((dw, dh), Image.Resampling.BILINEAR))
        self.img_canvas.create_image((self.pw - dw) // 2, (self.ph - dh) // 2, anchor=tk.NW, image=self.img_prev_tk)
        self.img_prev_title.set(f"转换效果预览 ({tw}x{th} 缩小显示):")
        kind = "单独设置" if p in self.img_over else "默认设置"
        cut = "  自定义裁剪" if crop else ""
        self.img_info.set(f"{os.path.basename(p)}  原始 {size[0]}x{size[1]} -> {tw}x{th}  "
                          f"{FIT_SHORT[mode]}{cut}  锐化 {sharp}%  {self.img_cfg(p)['dur']} 秒  ({kind})")

    def img_convert(self):
        files = list(self.img_files)
        if not files:
            messagebox.showinfo("图片", "请先添加图片")
            return
        if self.img_target() is None:
            messagebox.showerror("图片", "输出分辨率无效, 请先改正 (格式 宽x高, 例如 1280x800)")
            return
        self.img_store()
        params = {p: self.img_params(p) for p in files}
        durs = {p: self.img_cfg(p)["dur"] for p in files}
        sizes = sorted({v[0] for v in params.values()})
        tag = f"{sizes[0][0]}x{sizes[0][1]}" if len(sizes) == 1 else "混合分辨率"
        out = unique_path(os.path.join(self.img_out.get(), f"{tag}_{time.strftime('%Y%m%d_%H%M%S')}"))
        n_own = sum(1 for p in files if p in self.img_over)
        self.log(f"开始转换 {len(files)} 张图片, 输出 {', '.join(f'{w}x{h}' for w, h in sizes)}"
                 f" (单独设置 {n_own} 张)")
        if len(files) > ssd.MAX_IMG:
            self.log(f"[提示] 共 {len(files)} 张, FPGA 只读取前 {ssd.MAX_IMG} 张")

        def work():
            os.makedirs(out, exist_ok=True)
            ok = 0
            items = []
            for i, p in enumerate(files):
                (tw, th), mode, crop, sharp = params[p]
                base = os.path.splitext(os.path.basename(p))[0]
                dst = os.path.join(out, f"{i + 1:02d}_{base}_{tw}x{th}.bmp")
                try:
                    with Image.open(p) as im:
                        cimg.fit_image(im, tw, th, mode, crop=crop, sharpen=sharp).save(dst, "BMP")
                    ok += 1
                    items.append((ok, durs[p], os.path.basename(dst)))
                    self.log(f"[成功] {os.path.basename(p)} -> {os.path.basename(dst)}  ({FIT_SHORT[mode]}, 锐化 {sharp}%)")
                except Exception as e:
                    self.log(f"[失败] {os.path.basename(p)}: {e}")
                self.msgq.put(("prog", (i + 1) * 100 / len(files)))
            if items:                           # 播放顺序 / 时长, 写入 TF 卡页面默认沿用
                with open(os.path.join(out, ssd.CFG_NAME), "w", encoding="utf-8", newline="") as f:
                    f.write(ssd.cfg_text(items))
            self.log(f"图片转换完成: {ok}/{len(files)} 张, 输出到 {out}")
            return ok

        def done(ok):
            if ok:
                self.sd_img.set(out)            # 写入 TF 卡页面改用这一次的结果
        self.run_bg("图片转换", work, done)

    # ------------------------------------------------------------------ 音乐
    def build_music_tab(self):
        f = self.page("  音乐  ", 10)
        f.columnconfigure(1, weight=1)
        self.wav_in = tk.StringVar()
        self.wav_rate = tk.StringVar(value=RATES[0])
        self.wav_mono = tk.BooleanVar(value=True)
        self.wav_secs = tk.StringVar()
        self.wav_gain = tk.DoubleVar(value=1.0)
        self.wav_norm = tk.BooleanVar(value=False)
        self.wav_src = None             # 输入文件的 wav_info

        self.path_row(f, 0, "输入音频", self.wav_in, self.wav_pick_in)
        self.wav_info_s = tk.StringVar(value="支持 WAV (8/16/24/32 bit 整数, 32/64 bit 浮点); 装有 ffmpeg 时也支持 mp3/flac 等")
        ttk.Label(f, textvariable=self.wav_info_s, style="Hint.TLabel").grid(row=1, column=1, columnspan=2,
                                                                             sticky=tk.W, padx=4)

        opt = ttk.LabelFrame(f, text="转换选项", padding=8)
        opt.grid(row=2, column=0, columnspan=3, sticky=tk.EW, pady=8)
        ttk.Label(opt, text="采样率").grid(row=0, column=0, sticky=tk.W)
        ttk.Combobox(opt, textvariable=self.wav_rate, values=RATES, width=14, state="readonly").grid(
            row=0, column=1, sticky=tk.W, padx=6)
        ttk.Label(opt, text="推荐 48000: 电脑端高质量重采样, FPGA 按 48k 原样输出;\n"
                  "其他采样率由 FPGA 线性插值到 48k (保持原采样率时, 超出 8k~48k 的转为 48000)", style="Hint.TLabel").grid(
            row=0, column=2, columnspan=3, sticky=tk.W)
        ttk.Checkbutton(opt, text="混成单声道 (推荐: TF 卡带宽减半, 不易断音, 图片加载更快)", variable=self.wav_mono).grid(
            row=1, column=0, columnspan=3, sticky=tk.W, pady=4)
        ttk.Label(opt, text="只保留前").grid(row=2, column=0, sticky=tk.W)
        ttk.Entry(opt, textvariable=self.wav_secs, width=8).grid(row=2, column=1, sticky=tk.W, padx=6)
        ttk.Label(opt, text="秒 (留空 = 全部)").grid(row=2, column=2, sticky=tk.W)
        ttk.Label(opt, text="音量倍数").grid(row=3, column=0, sticky=tk.W, pady=4)
        ttk.Scale(opt, from_=0.1, to=4.0, variable=self.wav_gain, length=int(240 * self.k),
                  command=lambda v: self.wav_gain_s.set(f"x {float(v):.2f}")).grid(row=3, column=1, columnspan=2,
                                                                                   sticky=tk.W, padx=6)
        self.wav_gain_s = tk.StringVar(value="x 1.00")
        ttk.Label(opt, textvariable=self.wav_gain_s, width=7).grid(row=3, column=3, sticky=tk.W)
        ttk.Button(opt, text="复位", width=5, command=lambda: (self.wav_gain.set(1.0), self.wav_gain_s.set("x 1.00"))
                   ).grid(row=3, column=4, sticky=tk.W)
        ttk.Checkbutton(opt, text="响度归一化 (峰值调到 98% 后再乘音量倍数)", variable=self.wav_norm).grid(
            row=4, column=0, columnspan=4, sticky=tk.W)

        self.path_row(f, 3, "输出目录", self.wav_dir, self.wav_pick_out)
        self.wav_est = tk.StringVar()
        ttk.Label(f, textvariable=self.wav_est, style="Hint.TLabel").grid(row=4, column=1, columnspan=2,
                                                                          sticky=tk.W, padx=4)
        for v in (self.wav_rate, self.wav_mono, self.wav_secs):
            v.trace_add("write", lambda *a: self.wav_estimate())

        bf = ttk.Frame(f)
        bf.grid(row=5, column=0, columnspan=3, pady=12)
        ttk.Button(bf, text="开始转换", style="Big.TButton", command=self.wav_convert).pack(side=tk.LEFT, padx=6)
        state = tk.NORMAL if winsound else tk.DISABLED
        ttk.Button(bf, text="试听原文件", state=state, command=lambda: self.wav_play(self.wav_in.get())).pack(
            side=tk.LEFT, padx=6)
        ttk.Button(bf, text="试听输出", state=state, command=lambda: self.wav_play(self.sd_wav.get())).pack(
            side=tk.LEFT, padx=6)
        ttk.Button(bf, text="停止", state=state, command=self.wav_stop).pack(side=tk.LEFT, padx=6)

        ttk.Label(f, justify=tk.LEFT, style="Hint.TLabel", text=(
            "FPGA 播放 TF 卡根目录中的第一个 WAV (PCM 8/16 bit, 单/双声道, 8000~48000 Hz), 播完自动循环.\n"
            "声音经 HDMI 以 48 kHz 输出. 推荐 48000 Hz 单声道 (96 KB/s, 与第十一讲相同).\n"
            "双声道 48 kHz 需 192 KB/s 的 TF 卡带宽, 音频与图片共享 SPI 读卡带宽, 卡慢时可能欠载断音.")).grid(
            row=6, column=0, columnspan=3, sticky=tk.W, pady=6)

    def wav_pick_in(self):
        p = filedialog.askopenfilename(title="选择音频", filetypes=[
            ("音频", "*.wav *.mp3 *.flac *.ogg *.m4a *.aac *.wma"), ("所有文件", "*.*")])
        if not p:
            return
        self.wav_in.set(os.path.normpath(p))
        try:
            i = cwav.wav_info(p)
            self.wav_src = i
            self.wav_info_s.set(f"{i['tag_name']}, {i['bits']} bit, {i['chans']} 声道, {i['rate']} Hz, "
                                f"{i['seconds']:.1f} 秒, {human(os.path.getsize(p))}"
                                + ("  (FPGA 可直接播放)" if i["fpga_ok"] else "  (需要转换)"))
        except Exception as e:
            self.wav_src = None
            self.wav_info_s.set(f"不是可直接解析的 WAV ({e}), 转换时将尝试调用 ffmpeg")
        self.wav_estimate()

    def wav_pick_out(self):
        d = filedialog.askdirectory(title="选择输出目录", initialdir=self.wav_dir.get())
        if d:
            self.wav_dir.set(os.path.normpath(d))

    def wav_params(self):
        r = self.wav_rate.get()
        force = None if r == KEEP_RATE else int(r)
        secs = self.wav_secs.get().strip()
        secs = float(secs) if secs else None
        if secs is not None and secs <= 0:
            raise ValueError("秒数需大于 0")
        return force, secs

    def wav_estimate(self):
        i = self.wav_src
        if not i:
            self.wav_est.set("")
            return
        try:
            force, secs = self.wav_params()
        except ValueError:
            self.wav_est.set("秒数格式不对")
            return
        rate = force or (i["rate"] if cwav.RATE_MIN <= i["rate"] <= cwav.RATE_MAX else 48000)
        ch = 1 if self.wav_mono.get() else 2
        dur = min(secs, i["seconds"]) if secs else i["seconds"]
        note = "" if rate == 48000 else ", FPGA 线性插值到 48k"
        self.wav_est.set(f"预计输出: {rate} Hz, {ch} 声道, 16 bit, {dur:.1f} 秒, 约 {human(44 + dur * rate * ch * 2)}, "
                         f"读卡带宽 {rate * ch * 2 / 1024:.0f} KB/s{note}")

    def wav_play(self, p):
        if not p or not os.path.isfile(p):
            messagebox.showinfo("试听", "文件不存在")
            return
        try:
            winsound.PlaySound(p, winsound.SND_FILENAME | winsound.SND_ASYNC | winsound.SND_NODEFAULT)
            self.log(f"试听 {p}")
        except RuntimeError as e:
            self.log(f"[提示] 无法播放 {os.path.basename(p)} ({e}), 系统只能播放标准 WAV")

    def wav_stop(self):
        if winsound:
            winsound.PlaySound(None, 0)

    def wav_convert(self):
        src, d = self.wav_in.get(), self.wav_dir.get()
        if not src or not os.path.isfile(src):
            messagebox.showinfo("音乐", "请先选择输入音频")
            return
        try:
            force, secs = self.wav_params()
        except ValueError as e:
            messagebox.showerror("音乐", f"参数错误: {e}")
            return
        self.wav_stop()
        mono, gain, norm = self.wav_mono.get(), self.wav_gain.get(), self.wav_norm.get()

        def work():
            # 采样率 / 声道数要转换后才确定 (保持原采样率, ffmpeg 解码): 先写临时文件, 再按结果命名
            os.makedirs(d, exist_ok=True)
            tmp = os.path.join(d, "~converting.wav")
            try:
                info = cwav.convert(src, tmp, 48000, force, mono, secs, gain, norm, log=self.log,
                                    keep_rate=force is None)
            except Exception:
                if os.path.exists(tmp):
                    os.remove(tmp)
                raise
            base = os.path.splitext(os.path.basename(src))[0]
            ch = "单声道" if info["chans"] == 1 else "立体声"
            out = unique_path(os.path.join(d, f"{base}_{info['rate']}Hz_{ch}.wav"))
            os.replace(tmp, out)
            self.log(f"[成功] 输出 {out} (写入 TF 卡时命名为 MUSIC.WAV)")
            return out

        def done(out):
            self.sd_wav.set(out)                # 试听输出 / 写入 TF 卡改用这一次的结果
        self.run_bg("音乐转换", work, done)

    # ------------------------------------------------------------------ 字幕
    def build_sub_tab(self):
        f = self.page("  字幕  ", 8)
        self.ascii_rom = load_ascii_rom(self.log)
        fonts = [p for p in msub.DEFAULT_FONTS + [os.path.join(msub.WIN_FONTS, n) for n in EXTRA_FONTS]
                 if os.path.exists(p)]
        self.sub_font = tk.StringVar(value=fonts[0] if fonts else "")
        self.sub_size = tk.IntVar(value=16)
        self.sub_thr = tk.IntVar(value=110)
        self.sub_result = None
        self.sub_job = None
        self.sub_prev_tk = None

        top = ttk.Frame(f)
        top.pack(fill=tk.X)
        ttk.Label(top, text="字幕内容 (换行会变成空格; 英文数字用内置字库, 汉字用下方字体生成点阵):").pack(side=tk.LEFT)
        for text, cmd in (("示例", self.sub_sample), ("清空", lambda: self.sub_text.delete("1.0", tk.END)),
                          ("打开文本...", self.sub_open)):
            ttk.Button(top, text=text, command=cmd).pack(side=tk.RIGHT, padx=2)
        self.sub_text = tk.Text(f, height=5, wrap=tk.WORD, font=("Microsoft YaHei UI", 11), undo=True)
        self.sub_text.pack(fill=tk.X, pady=4)
        self.sub_text.bind("<<Modified>>", self.sub_modified)

        opt = ttk.Frame(f)
        opt.pack(fill=tk.X, pady=2)
        opt.columnconfigure(1, weight=1)
        ttk.Label(opt, text="字体").grid(row=0, column=0, sticky=tk.W)
        cb = ttk.Combobox(opt, textvariable=self.sub_font, values=fonts)
        cb.grid(row=0, column=1, sticky=tk.EW, padx=4)
        cb.bind("<<ComboboxSelected>>", lambda e: self.sub_schedule())
        ttk.Button(opt, text="浏览...", command=self.sub_pick_font).grid(row=0, column=2, padx=4)
        ttk.Label(opt, text="字号").grid(row=0, column=3, padx=(10, 0))
        ttk.Spinbox(opt, from_=10, to=20, width=4, textvariable=self.sub_size,
                    command=self.sub_schedule).grid(row=0, column=4, padx=4)
        ttk.Label(opt, text="笔画粗细 (阈值)").grid(row=0, column=5, padx=(10, 0))
        ttk.Scale(opt, from_=220, to=30, variable=self.sub_thr, length=int(140 * self.k),
                  command=lambda v: self.sub_schedule()).grid(row=0, column=6, padx=4)

        self.sub_stat = tk.StringVar()
        self.sub_stat_l = ttk.Label(f, textvariable=self.sub_stat)
        self.sub_stat_l.pack(anchor=tk.W, pady=(6, 0))

        pf = ttk.LabelFrame(f, text="FPGA 显示效果预览 (红线为一屏宽度 640 像素, 可左右拖动滚动条)")
        pf.pack(fill=tk.BOTH, expand=True, pady=6)
        self.sz = max(2, round(2 * self.k))            # 整条预览放大倍数
        self.zc = max(6, round(6 * self.k))            # 点阵放大图每点像素
        self.sub_canvas = tk.Canvas(pf, height=self.sz * 16 + 16, bg="#101018", highlightthickness=0)
        hs = ttk.Scrollbar(pf, orient=tk.HORIZONTAL, command=self.sub_canvas.xview)
        self.sub_canvas.configure(xscrollcommand=hs.set)
        self.sub_canvas.pack(fill=tk.X, padx=4, pady=4)
        hs.pack(fill=tk.X, padx=4)
        ttk.Label(pf, text="下方为汉字的 16x16 点阵放大图, 笔画粘连或缺笔时可调整字体/字号/笔画粗细",
                  style="Hint.TLabel").pack(anchor=tk.W, padx=4)
        self.sub_zoom = tk.Canvas(pf, height=self.zc * 16 + 8, bg="#101018", highlightthickness=0)
        self.sub_zoom.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)
        self.sub_zoom.bind("<Configure>", lambda e: self.sub_draw_zoom())

        of = ttk.Frame(f)
        of.pack(fill=tk.X)
        of.columnconfigure(1, weight=1)
        self.path_row(of, 0, "输出目录", self.sub_out, self.sub_pick_out)
        ttk.Button(f, text="生成 SUB.TXT / SUB.FNT", style="Big.TButton", command=self.sub_save).pack(pady=6)
        self.sub_sample()

    def sub_sample(self):
        self.sub_text.delete("1.0", tk.END)
        self.sub_text.insert("1.0", "欢迎使用安路 FPGA 多媒体播放器 -- HX4S20C 开发板, HDMI 1280x800, "
                                    "支持图片轮播、转场特效、OSD 字幕与 WAV 音乐播放!")

    def sub_open(self):
        p = filedialog.askopenfilename(title="打开字幕文本", filetypes=[("文本", "*.txt"), ("所有文件", "*.*")])
        if not p:
            return
        raw = open(p, "rb").read()
        for enc in ("utf-8-sig", "gbk"):
            try:
                text = raw.decode(enc)
                break
            except UnicodeDecodeError:
                continue
        else:
            messagebox.showerror("字幕", "无法识别文本编码 (支持 UTF-8 / GBK)")
            return
        self.sub_text.delete("1.0", tk.END)
        self.sub_text.insert("1.0", text.strip())

    def sub_pick_font(self):
        p = filedialog.askopenfilename(title="选择字体", initialdir=msub.WIN_FONTS,
                                       filetypes=[("字体", "*.ttf *.ttc *.otf"), ("所有文件", "*.*")])
        if p:
            self.sub_font.set(os.path.normpath(p))
            self.sub_schedule()

    def sub_pick_out(self):
        d = filedialog.askdirectory(title="选择输出目录 (可直接选 TF 卡根目录)", initialdir=self.sub_out.get())
        if d:
            self.sub_out.set(os.path.normpath(d))

    def sub_modified(self, _e=None):
        if self.sub_text.edit_modified():
            self.sub_text.edit_modified(False)
            self.sub_schedule()

    def sub_schedule(self):
        if self.sub_job:
            self.after_cancel(self.sub_job)
        self.sub_job = self.after(250, self.sub_update)

    def sub_build(self):
        text = self.sub_text.get("1.0", tk.END).strip()
        notes = []
        try:
            size = int(self.sub_size.get())
        except (tk.TclError, ValueError):
            size = 16
        font = self.sub_font.get().strip() or None
        if font and not os.path.exists(font):
            font = None
        codes, fnt, wide = msub.build(text, font, size, int(self.sub_thr.get()), log=notes.append)
        return text, codes, fnt, wide, notes

    def sub_update(self):
        self.sub_job = None
        try:
            text, codes, fnt, wide, notes = self.sub_build()
        except Exception as e:
            self.sub_result = None
            self.sub_stat.set(f"无法生成: {e}")
            self.sub_stat_l.configure(foreground="#c00")
            self.sub_canvas.delete("all")
            self.sub_zoom.delete("all")
            return
        self.sub_result = (codes, fnt, wide)
        loop = (len(codes) * 8 + 640) / 60.0
        s = (f"{len(codes)}/{msub.TXT_MAX} 字节    汉字 {len(wide)}/{msub.MAX_WIDE} 个    "
             f"滚动一遍约 {loop:.0f} 秒")
        if notes:
            s += "    " + "  ".join(n.replace("[提示] ", "") for n in notes)
        self.sub_stat.set(s)
        self.sub_stat_l.configure(foreground="#c00" if notes else "#060")

        # 整条字幕: 与 video_compositor 相同的 8x16 字符格, 颜色 FFE060
        w = max(len(codes) * 8, 640)
        im = Image.new("RGB", (w, 16), (16, 16, 24))
        px = im.load()
        for i, c in enumerate(codes):
            rows = glyph_rows(c, fnt, self.ascii_rom)
            for r in range(16):
                v = rows[r]
                for b in range(8):
                    if v & (0x80 >> b):
                        px[i * 8 + b, r] = (255, 224, 96)
        z = self.sz
        big = im.resize((w * z, 16 * z), Image.Resampling.NEAREST)
        self.sub_prev_tk = ImageTk.PhotoImage(big)
        cv = self.sub_canvas
        cv.delete("all")
        cv.create_image(0, 8, anchor=tk.NW, image=self.sub_prev_tk)
        for x in range(640 * z, w * z + 1, 640 * z):
            cv.create_line(x, 0, x, 16 * z + 16, fill="#f33", dash=(4, 3))
        cv.configure(scrollregion=(0, 0, w * z, 16 * z + 16))
        self.sub_draw_zoom()

    def sub_draw_zoom(self):
        """汉字 16x16 点阵放大图, 按画布大小自动换行"""
        zc = self.sub_zoom
        zc.delete("all")
        if not self.sub_result:
            return
        _, fnt, wide = self.sub_result
        d = self.zc
        cw, ch = zc.winfo_width(), zc.winfo_height()
        x0, y0 = 4, 4
        for _, k in sorted(wide.items(), key=lambda t: t[1]):
            if x0 + 16 * d > cw:
                x0, y0 = 4, y0 + 16 * d + 8
            if y0 + 16 * d > ch:
                break
            for half in (0, 1):
                base = (2 * k + half) * 16
                for r in range(16):
                    v = fnt[base + r]
                    for b in range(8):
                        if v & (0x80 >> b):
                            x = x0 + (half * 8 + b) * d
                            zc.create_rectangle(x, y0 + r * d, x + d - 1, y0 + r * d + d - 1,
                                                fill="#ffe060", outline="")
            x0 += 16 * d + 10

    def sub_save(self):
        if self.sub_job:
            self.after_cancel(self.sub_job)
        self.sub_update()
        if not self.sub_result:
            messagebox.showerror("字幕", self.sub_stat.get())
            return
        codes, fnt, wide = self.sub_result
        if not codes:
            messagebox.showinfo("字幕", "字幕内容为空")
            return
        out = self.sub_out.get()
        try:
            os.makedirs(out, exist_ok=True)
            with open(os.path.join(out, "SUB.TXT"), "wb") as fp:
                fp.write(codes)
            self.log(f"SUB.TXT : {len(codes)} 字节 -> {out}")
            fpath = os.path.join(out, "SUB.FNT")
            if wide:
                with open(fpath, "wb") as fp:
                    fp.write(fnt)
                self.log(f"SUB.FNT : 2048 字节, {len(wide)} 个汉字")
            elif os.path.exists(fpath):
                os.remove(fpath)        # 旧字库已无用, 避免写入 TF 卡时混淆
                self.log("纯 ASCII 字幕, 已删除旧的 SUB.FNT")
            else:
                self.log("纯 ASCII 字幕, 不需要 SUB.FNT")
        except OSError as e:
            messagebox.showerror("字幕", str(e))
            return
        self.status.set("字幕已生成")

    # ------------------------------------------------------------------ 写入 TF 卡
    def build_sync_tab(self):
        f = self.page("  写入TF卡  ", 10)
        f.columnconfigure(1, weight=1)
        self.sd_drive = tk.StringVar()
        self.sd_keep = tk.BooleanVar(value=False)
        self.sd_folder = tk.BooleanVar(value=True)
        self.sd_list, self.sd_list_dir = [], None            # 播放列表 [[BMP 路径, 秒数]], 来自哪个图片目录
        self.sd_dur = tk.StringVar(value=str(ssd.DUR_DEFAULT))
        self.sd_use = {k: tk.BooleanVar(value=True) for k in ("img", "wav", "txt", "fnt")}
        self.sd_txt = tk.StringVar(value=os.path.join(HERE, "SUB.TXT"))
        self.sd_fnt = tk.StringVar(value=os.path.join(HERE, "SUB.FNT"))
        self.sub_out.trace_add("write", lambda *a: (self.sd_txt.set(os.path.join(self.sub_out.get(), "SUB.TXT")),
                                                    self.sd_fnt.set(os.path.join(self.sub_out.get(), "SUB.FNT"))))

        ttk.Label(f, text="TF 卡").grid(row=0, column=0, sticky=tk.W, padx=4)
        self.sd_combo = ttk.Combobox(f, textvariable=self.sd_drive)
        self.sd_combo.grid(row=0, column=1, sticky=tk.EW, padx=4)
        self.sd_combo.bind("<<ComboboxSelected>>", lambda e: self.sd_check())
        bf = ttk.Frame(f)
        bf.grid(row=0, column=2, sticky=tk.W)
        ttk.Button(bf, text="刷新", command=self.sd_refresh).pack(side=tk.LEFT, padx=2)
        ttk.Button(bf, text="浏览...", command=self.sd_pick).pack(side=tk.LEFT, padx=2)
        self.sd_drv_info = tk.StringVar()
        self.sd_drv_l = ttk.Label(f, textvariable=self.sd_drv_info, wraplength=int(700 * self.k))
        self.sd_drv_l.grid(row=1, column=1, columnspan=2, sticky=tk.W, padx=4)

        src = ttk.LabelFrame(f, text="要写入的内容 (默认取前面几页最近一次的输出, 可点“浏览...”换成以前的结果)", padding=8)
        src.grid(row=2, column=0, columnspan=3, sticky=tk.EW, pady=8)
        src.columnconfigure(2, weight=1)
        rows = (("img", "图片目录", self.sd_img, lambda: self.sd_pick_path(self.sd_img, True)),
                ("wav", "背景音乐", self.sd_wav, lambda: self.sd_pick_path(self.sd_wav, False)),
                ("txt", "字幕 SUB.TXT", self.sd_txt, lambda: self.sd_pick_path(self.sd_txt, False)),
                ("fnt", "字库 SUB.FNT", self.sd_fnt, lambda: self.sd_pick_path(self.sd_fnt, False)))
        for r, (k, label, var, cmd) in enumerate(rows):
            ttk.Checkbutton(src, variable=self.sd_use[k], command=self.sd_check).grid(row=r, column=0)
            ttk.Label(src, text=label).grid(row=r, column=1, sticky=tk.W, padx=4, pady=2)
            ttk.Entry(src, textvariable=var).grid(row=r, column=2, sticky=tk.EW, padx=4, pady=2)
            ttk.Button(src, text="浏览...", command=cmd).grid(row=r, column=3, padx=4, pady=2)

        opt = ttk.Frame(f)
        opt.grid(row=3, column=0, columnspan=3, sticky=tk.W)
        ttk.Checkbutton(opt, text="按文件夹分类写入: IMG\\ 图片, MUSIC\\ 音乐, SUB\\ 字幕, 根目录 PLAY.CFG 播放列表 (推荐)",
                        variable=self.sd_folder, command=self.sd_check).pack(anchor=tk.W)
        ttk.Checkbutton(opt, text="保留 TF 卡上原有文件 (不勾选则先清空根目录, System Volume Information 除外)",
                        variable=self.sd_keep).pack(anchor=tk.W)

        plf = ttk.LabelFrame(f, text="播放列表 (列表顺序 = 播放顺序; 时长 = 自动轮播时每张停留的秒数)", padding=6)
        plf.grid(row=4, column=0, columnspan=3, sticky=tk.NSEW, pady=(6, 0))
        plf.columnconfigure(0, weight=1)
        ptv = ttk.Treeview(plf, columns=("no", "name", "res", "dur"), show="headings", height=6, selectmode="extended")
        for c, t, w in (("no", "顺序", 50), ("name", "图片", 420), ("res", "分辨率", 100), ("dur", "时长 (秒)", 80)):
            ptv.heading(c, text=t)
            ptv.column(c, width=int(w * self.k), stretch=(c == "name"), anchor=tk.W if c == "name" else tk.CENTER)
        ptv.grid(row=0, column=0, sticky=tk.NSEW)
        psb = ttk.Scrollbar(plf, command=ptv.yview)
        ptv.configure(yscrollcommand=psb.set)
        psb.grid(row=0, column=1, sticky=tk.NS)
        self.sd_ptree = ptv
        pb = ttk.Frame(plf)
        pb.grid(row=1, column=0, columnspan=2, sticky=tk.W, pady=(4, 0))
        ttk.Button(pb, text="上移", command=lambda: self.sd_move(-1)).pack(side=tk.LEFT, padx=2)
        ttk.Button(pb, text="下移", command=lambda: self.sd_move(1)).pack(side=tk.LEFT, padx=2)
        ttk.Label(pb, text="   时长").pack(side=tk.LEFT)
        ttk.Spinbox(pb, from_=1, to=ssd.DUR_MAX, width=5, textvariable=self.sd_dur).pack(side=tk.LEFT, padx=4)
        ttk.Label(pb, text="秒").pack(side=tk.LEFT)
        ttk.Button(pb, text="设给选中", command=lambda: self.sd_set_dur(False)).pack(side=tk.LEFT, padx=(8, 2))
        ttk.Button(pb, text="设给全部", command=lambda: self.sd_set_dur(True)).pack(side=tk.LEFT, padx=2)
        ttk.Button(pb, text="恢复 (按图片页转换结果)", command=lambda: self.sd_load_list(True)).pack(side=tk.LEFT, padx=(8, 2))

        tv = ttk.Treeview(f, columns=("dst", "src", "size", "st"), show="headings", height=7)
        for c, t, w in (("dst", "TF 卡文件", 110), ("src", "来源", 420), ("size", "大小", 80), ("st", "状态", 200)):
            tv.heading(c, text=t)
            tv.column(c, width=int(w * self.k), stretch=(c == "src"))
        tv.grid(row=5, column=0, columnspan=3, sticky=tk.NSEW, pady=6)
        f.rowconfigure(5, weight=1)
        self.sd_tree = tv
        self.sd_sum = tk.StringVar()
        ttk.Label(f, textvariable=self.sd_sum).grid(row=6, column=0, columnspan=3, sticky=tk.W)

        bb = ttk.Frame(f)
        bb.grid(row=7, column=0, columnspan=3, pady=8)
        ttk.Button(bb, text="检查", command=self.sd_check).pack(side=tk.LEFT, padx=6)
        ttk.Button(bb, text="写入 TF 卡", style="Big.TButton", command=self.sd_write).pack(side=tk.LEFT, padx=6)
        ttk.Button(bb, text="打开 TF 卡", command=self.sd_open).pack(side=tk.LEFT, padx=6)
        ttk.Label(f, style="Hint.TLabel", justify=tk.LEFT, wraplength=int(900 * self.k), text=(
            "TF 卡需为 FAT32 (32 GB 及以下默认即是), 最多 16 张图片. 分类写入时 FPGA 读 IMG / MUSIC / SUB 文件夹, "
            "按 PLAY.CFG 的顺序和秒数播放 (PLAY.CFG 可以用记事本直接改: 调换行的顺序 = 改播放顺序); "
            "不分类时全部放根目录, 按目录顺序每张 4 秒, 保留原文件时卡上已有的其他 WAV/TXT/FNT 可能被优先使用. "
            "写完请先安全弹出再拔卡.")).grid(row=8, column=0, columnspan=3, sticky=tk.W)
        self.nb.bind("<<NotebookTabChanged>>", lambda e: self.sd_on_tab())
        self.sd_refresh()

    def sd_on_tab(self):
        if self.nb.index("current") == 3:
            self.sd_check()

    def sd_refresh(self):
        drives = list_drives()
        old = getattr(self, "sd_drives", {})
        self.sd_combo.configure(values=[d[1] for d in drives])
        self.sd_drives = {d[1]: d[0] for d in drives}
        cur = self.sd_drive.get().strip()
        # 没选过, 或原来选的可移动磁盘已拔出时, 默认选第一个; 手动浏览的目录保持不变
        if drives and (not cur or (cur in old and cur not in self.sd_drives)):
            self.sd_drive.set(drives[0][1])
        if not drives:
            self.sd_drv_info.set("未发现可移动磁盘, 请插入读卡器, 或点“浏览...”手动选择")
        self.sd_check()

    def sd_target(self):
        v = self.sd_drive.get().strip()
        v = getattr(self, "sd_drives", {}).get(v, v)
        if len(v) == 2 and v[1] == ":":
            v += os.sep
        return v

    def sd_pick(self):
        d = filedialog.askdirectory(title="选择 TF 卡根目录")
        if d:
            self.sd_drive.set(os.path.normpath(d))
            self.sd_check()

    def sd_pick_path(self, var, is_dir):
        if is_dir:
            p = filedialog.askdirectory(initialdir=var.get())
        else:
            p = filedialog.askopenfilename(initialdir=os.path.dirname(var.get()))
        if p:
            var.set(os.path.normpath(p))
            self.sd_check()

    def sd_open(self):
        t = self.sd_target()
        if t and os.path.isdir(t) and hasattr(os, "startfile"):
            os.startfile(t)

    def sd_load_list(self, force=False):
        """图片目录变了 (或点 "恢复") 时重新生成播放列表: 可用的 BMP 按文件名排序,
        秒数取该目录中 PLAY.CFG (图片页转换时写入) 的设置, 没有则为默认"""
        d = self.sd_img.get()
        if d == self.sd_list_dir and not force:
            return
        self.sd_list_dir = d
        names = sorted(n for n in os.listdir(d) if n.lower().endswith(".bmp")) if os.path.isdir(d) else []
        good = [os.path.join(d, n) for n in names if ssd.bmp_ok(os.path.join(d, n))][:ssd.MAX_IMG]
        durs = {}
        cfg = ssd.read_cfg(os.path.join(d, ssd.CFG_NAME)) if os.path.isdir(d) else []
        base = [os.path.basename(p) for p in good]
        order = []
        for n, dsec, note in cfg:
            p = good[base.index(note)] if note in base else (good[n - 1] if n <= len(good) else None)
            if p and p not in durs:
                durs[p] = dsec or ssd.DUR_DEFAULT
                order.append(p)
        order += [p for p in good if p not in durs]
        self.sd_list = [[p, durs.get(p, ssd.DUR_DEFAULT)] for p in order]
        self.sd_ptree_fill()

    def sd_ptree_fill(self, sel=()):
        tv = self.sd_ptree
        tv.delete(*tv.get_children())
        for i, (p, dsec) in enumerate(self.sd_list):
            try:
                with Image.open(p) as im:
                    res = f"{im.size[0]}x{im.size[1]}"
            except Exception:
                res = "?"
            iid = tv.insert("", tk.END, values=(f"{i + 1:02d}", os.path.basename(p), res, dsec))
            if i in sel:
                tv.selection_add(iid)

    def sd_psel(self):
        kids = self.sd_ptree.get_children()
        return sorted(kids.index(i) for i in self.sd_ptree.selection())

    def sd_move(self, step):
        sel = self.sd_psel()
        if not sel or (step < 0 and sel[0] == 0) or (step > 0 and sel[-1] == len(self.sd_list) - 1):
            return
        for i in (sel if step < 0 else sel[::-1]):
            self.sd_list[i], self.sd_list[i + step] = self.sd_list[i + step], self.sd_list[i]
        self.sd_ptree_fill([i + step for i in sel])
        self.sd_check()

    def sd_set_dur(self, all_):
        try:
            v = max(1, min(ssd.DUR_MAX, int(float(self.sd_dur.get()))))
        except ValueError:
            messagebox.showerror("时长", f"请输入 1~{ssd.DUR_MAX} 的秒数")
            return
        self.sd_dur.set(str(v))
        sel = range(len(self.sd_list)) if all_ else self.sd_psel()
        if not sel:
            messagebox.showinfo("时长", "请先在播放列表中选中图片 (可按住 Ctrl / Shift 多选)")
            return
        for i in sel:
            self.sd_list[i][1] = v
        self.sd_ptree_fill([] if all_ else list(sel))
        self.sd_check()

    def sd_plan(self):
        """返回 (写入计划 [(目标名, 来源, 大小, 状态, 可用)], 选中的 bmp 列表)"""
        plan, bmps = [], []
        fd = self.sd_folder.get()
        pre = {"img": "IMG\\" if fd else "", "wav": "MUSIC\\" if fd else "", "sub": "SUB\\" if fd else ""}
        if self.sd_use["img"].get():
            d = self.sd_img.get()
            self.sd_load_list()
            if os.path.isdir(d):
                allb = sorted(set(n for n in os.listdir(d) if n.lower().endswith(".bmp")))
                for n in allb:
                    p = os.path.join(d, n)
                    if not ssd.bmp_ok(p):
                        plan.append(("-", p, os.path.getsize(p), "跳过: 不支持的 BMP (宽高 16~4096, 24/32bit 非压缩)", False))
                    elif p not in [q for q, _ in self.sd_list]:
                        plan.append(("-", p, os.path.getsize(p), "跳过: 超过 16 张", False))
            for p, dsec in self.sd_list:
                bmps.append(p)
                st = f"OK  第 {len(bmps)} 张, {dsec} 秒" if fd else "OK"
                plan.append((f"{pre['img']}IMG{len(bmps):02d}.BMP", p, os.path.getsize(p), st, True))
            if not bmps:
                plan.append(("IMG??.BMP", d, 0, "没有可用图片, 请先在“图片”页转换", False))
            elif fd:
                plan.append((ssd.CFG_NAME, "播放列表 (顺序与时长见上方)", 0, f"OK  {len(bmps)} 行", True))
        for k, name, var in (("wav", f"{pre['wav']}MUSIC.WAV", self.sd_wav), ("txt", f"{pre['sub']}SUB.TXT", self.sd_txt),
                             ("fnt", f"{pre['sub']}SUB.FNT", self.sd_fnt)):
            if not self.sd_use[k].get():
                continue
            p = var.get()
            if not os.path.isfile(p):
                st = "不存在, 将跳过" if k == "fnt" else "不存在, 将跳过 (请先生成)"
                plan.append((name, p, 0, st, False))
                continue
            size, st, ok = os.path.getsize(p), "OK", True
            if k == "wav":
                try:
                    i = cwav.wav_info(p)
                    st = f"OK  {i['rate']} Hz {i['chans']} 声道 {i['seconds']:.{0 if i['seconds'] >= 10 else 1}f} 秒"
                    if not i["fpga_ok"]:
                        st, ok = "格式不支持, 请先在“音乐”页转换", False
                except Exception as e:
                    st, ok = f"无法解析: {e}", False
            elif k == "fnt" and size != 2048:
                st, ok = "大小应为 2048 字节", False
            elif k == "txt" and size > msub.TXT_MAX:
                st = f"OK (只显示前 {msub.TXT_MAX} 字节)"
            plan.append((name, p, size, st, ok))
        return plan, bmps

    def sd_check(self):
        t = self.sd_target()
        info = drive_info(t) if t else None
        warn = False
        if not t:
            msg = "请选择 TF 卡"
        elif not os.path.isdir(t):
            msg, warn = f"找不到 {t}", True
        elif info:
            label, fs, total, free = info
            msg = f"卷标 [{label or '无'}]  {fs}  容量 {human(total)}  可用 {human(free)}"
            if fs.upper() != "FAT32":
                msg += "\n⚠ 不是 FAT32, FPGA 无法读取, 请先格式化为 FAT32"
                warn = True
            if ssd.is_system_root(t):
                msg += "\n⚠ 这是系统盘!"
                warn = True
        else:
            msg = t
        self.sd_drv_info.set(msg)
        self.sd_drv_l.configure(foreground="#c00" if warn else "#060")

        plan, _ = self.sd_plan()
        self.sd_tree.delete(*self.sd_tree.get_children())
        total = 0
        for dst, src, size, st, ok in plan:
            self.sd_tree.insert("", tk.END, values=(dst, src, human(size) if size else "", st))
            total += size if ok else 0
        n_ok = sum(1 for p in plan if p[4])
        s = f"将写入 {n_ok} 个文件, 共 {human(total)}"
        if info and total > info[3] and self.sd_keep.get():
            s += "    ⚠ TF 卡剩余空间不足"
        self.sd_sum.set(s)
        return plan

    def sd_write(self):
        t = self.sd_target()
        if not t or not os.path.isdir(t):
            messagebox.showerror("写入 TF 卡", "请先选择 TF 卡 (盘符或根目录)")
            return
        plan = self.sd_check()
        _, bmps = self.sd_plan()
        files = {name.split("\\")[-1]: src for name, src, _, _, ok in plan if ok}
        if not files:
            messagebox.showerror("写入 TF 卡", "没有可写入的文件")
            return
        info = drive_info(t)
        if ssd.is_system_root(t) and not messagebox.askyesno(
                "危险", f"{t} 是系统盘根目录!\n确定要继续吗?", icon="warning", default="no"):
            return
        if info and info[1].upper() != "FAT32" and not messagebox.askyesno(
                "文件系统", f"{t} 的文件系统是 {info[1]}, 不是 FAT32, FPGA 读不到.\n仍然写入?", icon="warning"):
            return
        keep = self.sd_keep.get()
        fd = self.sd_folder.get()
        durs = [d for _, d in self.sd_list][:len(bmps)]
        q = f"写入 {t}:\n\n  图片 {len(bmps)} 张" + (" (IMG 文件夹, 播放列表 PLAY.CFG)\n" if fd else " (根目录)\n")
        q += "".join(f"  {n}\n" for n in ("MUSIC.WAV", "SUB.TXT", "SUB.FNT") if n in files)
        q += ("\n保留卡上原有文件" + (" (IMG / MUSIC / SUB 文件夹会先清空)." if fd else ".")) if keep \
            else f"\n⚠ 将先删除 {t} 根目录下的所有文件和文件夹!"
        if not messagebox.askyesno("确认写入", q, icon="warning" if not keep else "question"):
            return
        n_total = len(bmps) + sum(1 for n in ("MUSIC.WAV", "SUB.TXT", "SUB.FNT") if n in files)
        count = [0]

        def log(m):
            self.log(m)
            if "->" in m:
                count[0] += 1
                self.msgq.put(("prog", count[0] * 100 / n_total))

        def work():
            ssd.sync(t, bmps, files.get("MUSIC.WAV"), files.get("SUB.TXT"), files.get("SUB.FNT"), keep, log,
                     folder=fd, durs=durs)
        self.run_bg("写入 TF 卡", work, done=lambda r: (self.sd_check(), messagebox.showinfo(
            "写入 TF 卡", "写入完成.\n请在系统托盘中“安全弹出”后再拔卡, 插入开发板上电即可.")))


# ---------------------------------------------------------------------- 磁盘信息
def list_drives():
    """返回 [(根目录, 显示文字)], 仅列出可移动磁盘 (Windows)"""
    if os.name != "nt":
        return []
    import ctypes
    k32 = ctypes.windll.kernel32
    mask = k32.GetLogicalDrives()
    out = []
    for i, letter in enumerate(string.ascii_uppercase):
        if not mask & (1 << i):
            continue
        root = f"{letter}:\\"
        if k32.GetDriveTypeW(root) != 2:        # DRIVE_REMOVABLE
            continue
        info = drive_info(root)
        if info:
            label, fs, total, _ = info
            out.append((root, f"{letter}:  [{label or '可移动磁盘'}]  {fs}  {human(total)}"))
        else:
            out.append((root, f"{letter}:  (未插卡)"))
    return out


def drive_info(root):
    """返回 (卷标, 文件系统, 总容量, 可用空间) 或 None"""
    if os.name != "nt" or not os.path.isdir(root):
        return None
    import ctypes
    k32 = ctypes.windll.kernel32
    drv = os.path.splitdrive(os.path.abspath(root))[0] + "\\"
    label = ctypes.create_unicode_buffer(261)
    fs = ctypes.create_unicode_buffer(261)
    old = k32.SetErrorMode(1)                   # 读卡器无卡时不弹系统对话框
    try:
        if not k32.GetVolumeInformationW(drv, label, 261, None, None, None, fs, 261):
            return None
        free, total = ctypes.c_ulonglong(0), ctypes.c_ulonglong(0)
        k32.GetDiskFreeSpaceExW(drv, ctypes.byref(free), ctypes.byref(total), None)
        return label.value, fs.value, total.value, free.value
    finally:
        k32.SetErrorMode(old)


def main():
    if os.name == "nt":
        try:                                    # 高分屏下字体清晰
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except Exception:
            pass
    app = App()
    app.mainloop()


if __name__ == "__main__":
    main()

