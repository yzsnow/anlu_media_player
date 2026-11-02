# 功能仿真

需要 Icarus Verilog (11 以上) 和 Python 3 + Pillow。运行:

```bash
sh run_sim.sh            # 除 stress 外全部
sh run_sim.sh loader     # 只跑 TF 卡加载器, 约 40 分钟
sh run_sim.sh video      # 只跑视频合成, 约 20 分钟
sh run_sim.sh scale      # 640x400 -> 1280x800 放大 (video_scale2x), 约 1 分钟
sh run_sim.sh menu       # SW3 参数菜单 / 亮度对比度 / 音量, 约 12 分钟
sh run_sim.sh sdram      # 只跑 SDRAM 仲裁与行刷新, 约 5 分钟
sh run_sim.sh stress     # 加载器压力测试 (实际 TF 卡时序 + 48 kHz 音频), 约 45 分钟
sh run_sim.sh fit        # 任意分辨率图片: 等比缩放 + 黑边逐张核对哈希, 随机写反压, 约 5 分钟 (不在 all 中)
sh run_sim.sh audio      # 音频通路 (WAV FIFO + 播放器), 约 3 分钟, 需要 numpy
```

工具不在 PATH 里时, 可以用 `IVERILOG=... VVP=... PYTHON=... sh run_sim.sh` 指定.

## 1. TF 卡加载器 `tb_loader.v`

| 文件 | 作用 |
|------|------|
| `mkdisk.py` | 生成 3 MB 的 FAT32 镜像 `disk.img` 和期望值 (`expect.vh`, `*_exp.hex`) |
| `sd_card_top_stub.v` | `sd_card_top` 的行为模型, 扇区内容来自 `disk.img`. 读时序与原 SPI 驱动一致, 可以模拟拔卡 |
| `tb_loader.v` | 自检 testbench. 包含 SDRAM 帧写口、WAV FIFO、文本/字库 RAM 的模型 |

镜像里专门放了以下情形:

- MBR 分区
- 根目录跨两个不连续的簇
- 卷标、长文件名、已删除项、子目录
- 过小的 BMP
- 32 bpp 的"损坏" BMP
- 簇链碎片化的 BMP
- `fmt` 与 `data` 之间夹着奇数长度 `LIST` 块的 WAV

检查项:

1. 扫描结果
   - 状态 READY, 图片数 3, 文件名依次为 `IMG_A` `BAD` `IMG_C`
   - 字幕与字库内容逐字节一致
2. 写入 SDRAM 的整帧数据 (307200 个像素) 的 FNV-1a 哈希与 Python 计算值一致, 碎片化文件也要一致
3. 损坏图片返回 `ack_ok = 0`
4. 已缓存的图片再次请求时, 应答延迟小于 2000 周期 (实测 19 周期, 即零等待切换)
5. WAV 样本序列逐个比对, 并且至少循环一次. 采样率 22050 Hz, rate code 为 4
6. 瞬时读超时: 卡停止响应 400 ms 后恢复 (超过 250 ms 单扇区超时).
   - 加载器只复位 TF 卡控制器并重读该扇区
   - 状态一直保持 READY
   - WAV 样本序列接着原位置继续, 不从头开始, 且没有错位
   - 图片缓存仍然命中
7. 拔卡: 重读仍失败, 约 1.75 s 后报 NOCARD (250 ms 超时 + 1.5 s 重新初始化超时). 插回后重新扫描, 并能重新加载图片

最近一次结果 (`tb_loader.log`):

```text
scan done: status=2 img_count=3 ... (413.4 us)
request img 0 -> ok=1 slot=0 latency=4330772 cycles (43307.7 us)
request img 1 -> ok=0 ...
request img 2 -> ok=1 slot=1 ... img2 frame hash OK (fragmented cluster chain)
request img 0 -> ok=1 slot=0 latency=19 cycles (0.2 us)
wav: 21881 samples written, 14 loops, 0 errors, rate code 4
transient stall 400 ms: 1 controller resets, status left READY 0 cycles, wav +20000 samples, 0 errors
request img 0 -> ok=1 slot=0 latency=233 cycles (2.3 us)
card removed -> status=3 after 1750.0 ms
card inserted -> status=2 img_count=3 after 0.4 ms
request img 2 -> ok=1 slot=0 latency=4734882 cycles (47348.8 us)
sd sector reads: 6667
==== tb_loader PASS ====
```

仿真里行为模型的 SD 读取速度比实际快. 实际 SPI 时钟为 25 MHz 时, 读一张 640×480 图片约需 0.5~1 s.

### 任意分辨率模式 `sh run_sim.sh fit` (约 5 分钟, 不在 all 中)

- `mkdisk.py --fit` 生成只含 12 张图片的镜像: 800×500、1000×333、301×500 (每行补 1 字节)、160×100、
  202×150 自上而下存储、123×77 32 bit、17×900、4096×16, 以及 RLE 压缩 / 截断 / 15×15 / 4097 宽 4 张应拒绝的图
- 参考模型 `fit_frame` (等比缩放最近邻 + 黑边居中, 与 `bmp_fit_scaler` 的 DDA 完全一致) 给出每张图期望的 256000 字哈希, 写入 `fit_exp.hex`
- 逐张请求: 核对应答 ok、整帧哈希、垂直翻转标志; 写 FIFO afull 随机拉高约 3/8 的周期, 并监视缩放器行缓存不溢出
- 跑完自动恢复默认镜像

### 压力模式 `sh run_sim.sh stress` (约 45 分钟, 不在 all 中)

用来检查 "加载图片时音乐是否断续". 编译时加 `-DREAL_SD`:

- 桩模型改用接近实际 TF 卡的时序:
  - 每字节 36 周期 (25 MHz SPI)
  - 命令到数据的访问延迟: 紧接上一扇区 0.1 ms, 跳址 1 ms
  - 每 1000 次读插入一次 40 ms 的长延迟 (模拟卡内部整理)
- `mkdisk.py --stress` 生成 48 kHz 立体声 16 bit 的 WAV (最大码率, 每秒需要 375 个扇区)
- testbench 按 48 kHz 实时消费 FIFO. 在首图加载、切到第二张 (都要读整张图) 和两次缓存命中切换期间, 统计 FIFO 读空的次数
- 另加 `-DOLD_FIFO` 可以按改进前的 2048 深 FIFO 连接, 用于对比

结果 (WAV 在首图加载完成后开始播放, 之后读第二张图时两者争用 SD 带宽):

| 版本 | 首图 (无音乐) | 第二张图 (同时放音乐) | 欠载次数 |
|------|---------|---------|---------|
| 改进后 (8192 FIFO + 水位滞回连续读) | 1.06 s | 1.40 s | 0 |
| 改进前 (2048 FIFO, 与图片逐扇区交替) | 1.06 s | 3 s 仿真结束时仍未读完 (> 1.9 s) | 未统计 (超时退出) |

改进前 WAV 每读一个扇区就和图片交替一次, 每次切换都要付出一次跳址延迟, 所以读图明显变慢.
这是行为模型的结果, 实际卡的延迟分布因卡而异, 以板上音频位小数点 (欠载指示) 为准.

## 2. 视频合成 `tb_video.v`

`video_timing_data` 产生 640×400 内容时序 (`VIDEO_640_400_2X`, 硬件上再由 `video_scale2x` 放大成 1280×800), 驱动 `video_compositor`. A、B 两路帧数据由图案发生器提供: A 为渐变, B 为棋盘格.

testbench 依次设置以下状态, 并各导出一帧:

1. 开机画面: 扫描中、加载中
2. 8 种转场: 7 种固定特效取 p = 128, 黑场过渡取 p = 64 和 192
3. 转场结束
4. 普通显示
5. 加载中
6. 损坏图片
7. 信息栏隐藏

`check_video.py` 负责后处理:

- 把各帧转成 `frames/fNN.png`, 并拼成总览图 `frames/overview.png`
- 在第 28~367 行 (OSD 区域以外) 逐像素核对混合结果 `A + (B-A)*q/256`. 其中 q 按各特效公式独立计算
  (纵向擦除 p×1.5625, 圆形展开以 (320, 200) 为中心、半径 p×1.5)
- 全部一致时打印 `check_video PASS`

## 2.1 1280×800 放大 `tb_scale2x.v` (`sh run_sim.sh scale`)

`video_timing_data` (640×400 内容时序, video_clk = pix_clk / 4) → 模拟合成器 (9 拍流水线, 像素值编码 x / y / 帧号)
→ `video_scale2x` → 在 pix_clk 域逐像素检查:

- 每个输出像素 (fx, fy) 等于内容像素 (fx/2, fy/2), 同一输出帧的像素来自同一内容帧, 帧号逐帧 +1
- 每行 1280 个有效像素, 每帧 800 行, 行周期 1520, HS 正极性 32 拍且在有效区结束后 48 拍开始, VS 负极性 6 行

从第 2 个 VS 开始检查 (上电后第一帧内输出计数器会被帧对齐装载一次). 最近一次结果:

```text
frames checked=2 pixels=2227574 errors=0
==== tb_scale2x PASS ====
```

## 2.2 参数菜单 `tb_menu.v` (`sh run_sim.sh menu`)

`player_ctrl` 的 SW3 菜单按键逻辑 (选项 / +1 / 长按 -1 连发 / 复位 / 关菜单后按键恢复)、`video_compositor` 的亮度对比度
(`check_menu.py` 按第十四讲公式逐像素核对, 含帧中途改参数只在下一帧生效)、`audio_i2s_player` 的 17 级音量增益.
画面为 640×400, 菜单框 y 104~295.

## 2.3 应急报警 `tb_alarm.v` (`sh run_sim.sh alarm`, 约 55 分钟; `vvp -n tb_alarm.vvp +audio_only` 只跑音频部分, 约 2 分钟)

- `player_ctrl`: SW1 = 0 时 KEY3 不触发; SW1 = 1 时触发并锁存 (松开 KEY3 不解除), 报警中 KEY1/KEY2 与 SW3 菜单不响应,
  `amode = 3`; 计时 BCD 进位 (09:59 → 10:00) 与 99:59 封顶; SW1 拨回 0 解除, 按键恢复.
- 画面 (`check_alarm.py`): 按 `alarm_screen.v` 的算法 (点阵 ROM、三角、斜纹、脉动底、计时数字) 逐像素计算期望画面,
  整帧必须完全一致 (报警中打开 SW2 也不叠加频谱); 在第 100 行触发时本帧整帧正常、下一帧整帧报警 (帧边界硬切);
  解除后恢复原图; 开机画面上也能报警. `+video_only` 只跑画面部分.
- 音频: 按过零点测警笛频率 (起点约 650 Hz → 1 s 处约 1480 Hz → 2 s 处约 620 Hz), 蜂鸣器同频; 幅度 ±16383, 音量 0 时照常输出;
  报警期间不读 WAV FIFO, 解除后第一次取样正好接着断点 (样本序号连续).

```text
a02 alarm_first      alarm fc=7  t=00:05  mismatch 0  OK
a03 alarm_sw3        alarm fc=12 t=00:21  mismatch 0  OK
check_alarm PASS
  wav resumed: 1999 -> 2000 (no skip)
==== tb_alarm PASS ====
```

## 3. SDRAM 仲裁与行刷新 `tb_sdram_arb.v`

`frame_dual_read_write` 接 SDRAM 行为模型 (读延迟 7 拍), 同时进行:
- A、B 两路显示读 (转场状态)
- 一整帧的写入

模型记录每一行 (row + bank, 共 8192 行) 最近一次被激活的时间.

检查项:

1. A、B 两路显示数据逐像素正确: FIFO 不欠载, 行刷新读回的数据不进 FIFO
2. 写入帧 (带垂直翻转) 内容正确
3. 读、写从不同时发起
4. 从 17 ms 起, 每一行在过去 17 ms 内都被访问过 (SDRAM 要求 64 ms)

最近一次结果:

```text
frames checked: 1 (426916 pixels), A errors 0, B errors 0
write frame: finished=1, errors 0
rd/wr collisions: 0
scrub reads: 21004, worst row idle time 15.99 ms, rows idle > 17 ms: 0
==== tb_sdram_arb PASS ====
```

## 4. 音频通路 `tb_audio.v` (`sh run_sim.sh audio`)

与顶层相同的连接: `async_fifo` (WAV FIFO) → `audio_i2s_player` → `I2S_receiver`, 三个时钟域 (写侧 / audio_mclk 12.295 MHz / video_clk) 各自独立.

| 文件 | 作用 |
|------|------|
| `check_audio.py gen RATE N` | 生成 `audio_in.hex`: 左声道 1000 Hz (0.9 满幅), 右声道 440 Hz (0.5 满幅) |
| `tb_audio.v` | 写侧按加载器的方式补数 (低于 5/8 开始, 按 128 样本一个扇区成块写, 接近满停止); `SUP` 参数限制供数速度模拟 TF 卡跟不上; 逐个核对 FIFO 读出与写入顺序; 把 I2S 接收到的每个 48k 帧写入 `audio_out.txt` |
| `check_audio.py check RATE` | FFT 测输出频率 (音调) 与幅度, 统计断续 (相邻样本差超过正弦最大斜率) |
| `check_audio.py starve RATE` | 欠载情形: 先去掉暂停期间保持不变的帧, 剩下的必须仍是连续、频率正确的正弦 |

`run_sim.sh` 把 FIFO 缩小到 1024 深 (`AW=10`), 指针很快回绕. 最近一次结果:

```text
32k 充足供数:  4665 samples read from FIFO, 0 data errors;  left 1000.10 Hz amp 0.8970, right 439.98 Hz amp 0.4997, discontinuities 0  PASS
48k 充足供数:  6998 samples read from FIFO, 0 data errors;  left 1000.09 Hz amp 0.8996, right 439.98 Hz amp 0.5000, discontinuities 0  PASS
32k 供数 85%:  3590 samples read from FIFO, 0 data errors;  paused frames 710 in 1 pauses;
               left 999.86 Hz amp 0.8968, right 440.11 Hz amp 0.5004, discontinuities 0  PASS
```

与改进前对比 (同一 testbench):

| 情形 | 改进前 | 改进后 |
|------|------|------|
| 实际深度 (AW=13), 48k, 20000 帧 | 读出停在第 16384 个样本 (写指针回绕后满标志误报, 之后的写入全被丢弃), 3598 帧重复/静音, FAIL | 19984 个样本逐个正确, 1000/440 Hz, 无断续, PASS |
| AW=10, 32k, 旧 FIFO + 旧播放器 | 7000 帧期间写侧送出 9000 个样本 (正常约 4700, 多出的在 FIFO 满误报时被丢弃, 即跳段), 左声道幅度 0.67, FAIL | PASS |
| AW=10, 32k 供数 85%, 新 FIFO + 旧播放器 | 欠载时对旧样本继续插值, 时间轴错乱: 左 1063 Hz / 右 374 Hz (变调), FAIL | 暂停 1 次后从断点继续, 999.86 / 440.11 Hz, PASS |

对比时用 `-DOLD_PLAYER` 按旧播放器端口连接; 旧 FIFO 需要自行换回旧版 `async_fifo.v`.
