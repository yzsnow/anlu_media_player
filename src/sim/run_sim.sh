#!/bin/sh
# 功能仿真 (Icarus Verilog 11+, Python 3 + Pillow)
#   sh run_sim.sh          两个仿真都跑
#   sh run_sim.sh loader   只跑 TF 卡加载器 (约 40 分钟)
#   sh run_sim.sh video    只跑视频合成 (约 25 分钟)
#   sh run_sim.sh sdram    只跑 SDRAM 仲裁 + 行刷新 (约 5 分钟)
#   sh run_sim.sh scale    只跑 640x400 -> 1280x800 放大 (video_scale2x, 约 1 分钟)
#   sh run_sim.sh menu     只跑 SW3 参数菜单 / 亮度对比度 / 音量 (约 12 分钟)
#   sh run_sim.sh spec     只跑 SW2 音频频谱: FFT 单元逐位核对 (约 1 分钟) + 画面 (约 10 分钟)
#   sh run_sim.sh alarm    只跑 SW1/KEY3 应急报警: 控制 + 报警画面逐像素核对 + 警笛/蜂鸣器/WAV 续播 (约 15 分钟)
#   sh run_sim.sh term     只跑第二屏运维终端: 矩阵键盘命令行 / 终端命令控制播放器 / 日志 / 状态刷新, 显存与整帧逐像素核对, TMDS 解码与时序 (约 10 分钟)
#   sh run_sim.sh audio    只跑音频通路 WAV FIFO + 播放器 (约 3 分钟, 需要 numpy)
#   sh run_sim.sh folder   加载器分类文件夹 IMG / MUSIC / SUB + 播放列表 PLAY.CFG (有 / 无播放列表各一次, 不在 all 中)
#   sh run_sim.sh fit      加载器任意分辨率图片: 等比缩放 + 黑边逐张核对哈希, 随机写反压 (不在 all 中)
#   sh run_sim.sh hotplug  加载器空闲心跳 / 空闲拔卡 / 快速换卡 (约 10 分钟, 不在 all 中)
#   sh run_sim.sh stress   加载器压力测试 (约 45 分钟): 接近实际 TF 卡的读延迟 + 48kHz 立体声 WAV,
#                          统计加载图片期间的音频 FIFO 欠载 (不在 all 中)
cd "$(dirname "$0")"
H=../user_source/hdl_source
IV=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
PY=${PYTHON:-python}
what=${1:-all}
rc=0

if [ "$what" = all ] || [ "$what" = loader ]; then
    $PY mkdisk.py || exit 1
    $IV -g2005 -I . -I $H/player -o tb_loader.vvp \
        tb_loader.v sd_card_top_stub.v $H/player/sd_media_loader.v $H/player/bmp_fit_scaler.v || exit 1
    $VVP -n tb_loader.vvp | tee tb_loader.log
    grep -q "tb_loader PASS" tb_loader.log || rc=1
fi

if [ "$what" = folder ]; then
    for v in "" --nocfg; do
        $PY mkdisk.py --folder $v || exit 1
        $IV -g2005 -DFOLDER -I . -I $H/player -o tb_folder.vvp \
            tb_loader.v sd_card_top_stub.v $H/player/sd_media_loader.v $H/player/bmp_fit_scaler.v || exit 1
        $VVP -n tb_folder.vvp | tee tb_folder$v.log
        grep -q "FOLDER PASS" tb_folder$v.log || rc=1
    done
fi
if [ "$what" = fit ]; then
    $PY mkdisk.py --fit || exit 1
    $IV -g2005 -DFIT -I . -I $H/player -o tb_fit.vvp \
        tb_loader.v sd_card_top_stub.v $H/player/sd_media_loader.v $H/player/bmp_fit_scaler.v || exit 1
    $VVP -n tb_fit.vvp | tee tb_fit.log
    grep -q "FIT PASS" tb_fit.log || rc=1
    $PY mkdisk.py > /dev/null     # 恢复功能仿真用的镜像
fi

if [ "$what" = hotplug ]; then
    $PY mkdisk.py || exit 1
    $IV -g2005 -DHOTPLUG -I . -I $H/player -o tb_hotplug.vvp \
        tb_loader.v sd_card_top_stub.v $H/player/sd_media_loader.v $H/player/bmp_fit_scaler.v || exit 1
    $VVP -n tb_hotplug.vvp | tee tb_hotplug.log
    grep -q "HOTPLUG PASS" tb_hotplug.log || rc=1
fi

if [ "$what" = stress ]; then
    $PY mkdisk.py --stress || exit 1
    $IV -g2005 -DREAL_SD -I . -I $H/player -o tb_stress.vvp \
        tb_loader.v sd_card_top_stub.v $H/player/sd_media_loader.v $H/player/bmp_fit_scaler.v || exit 1
    $VVP -n tb_stress.vvp | tee tb_stress.log
    grep -q "STRESS PASS" tb_stress.log || rc=1
    $PY mkdisk.py > /dev/null     # 恢复功能仿真用的镜像
fi

if [ "$what" = all ] || [ "$what" = video ]; then
    mkdir -p frames
    $IV -g2005 -I . -I $H/player -I $H/SD -o tb_video.vvp \
        tb_video.v $H/SD/video_timing_data.v $H/SD/color_bar.v \
        $H/player/video_compositor.v $H/player/audio_spectrum_osd.v $H/player/alarm_screen.v $H/player/alarm_rom.v $H/player/color_lut_gen.v $H/player/gamma_rom.v $H/player/osd_font_rom.v $H/player/osd_str_rom.v || exit 1
    $VVP -n tb_video.vvp | tee tb_video.log
    $PY check_video.py || rc=1
fi
if [ "$what" = all ] || [ "$what" = scale ]; then
    $IV -g2005 -I $H/SD -o tb_scale2x.vvp         tb_scale2x.v $H/SD/video_timing_data.v $H/SD/color_bar.v $H/player/video_scale2x.v || exit 1
    $VVP -n tb_scale2x.vvp | tee tb_scale2x.log
    grep -q "tb_scale2x PASS" tb_scale2x.log || rc=1
fi
if [ "$what" = all ] || [ "$what" = menu ]; then
    mkdir -p frames
    $IV -g2005 -I . -I $H/player -I $H/SD -o tb_menu.vvp         tb_menu.v $H/SD/video_timing_data.v $H/SD/color_bar.v $H/player/video_compositor.v $H/player/audio_spectrum_osd.v $H/player/alarm_screen.v $H/player/alarm_rom.v $H/player/color_lut_gen.v $H/player/gamma_rom.v         $H/player/osd_font_rom.v $H/player/osd_str_rom.v $H/player/player_ctrl.v         $H/player/audio_i2s_player.v $H/player/sync_2ff.v || exit 1
    $VVP -n tb_menu.vvp | tee tb_menu.log
    grep -q "tb_menu PASS" tb_menu.log || rc=1
    $PY check_menu.py || rc=1
fi
if [ "$what" = all ] || [ "$what" = alarm ]; then
    mkdir -p frames
    $IV -g2005 -I . -I $H/player -I $H/SD -o tb_alarm.vvp tb_alarm.v $H/SD/video_timing_data.v $H/SD/color_bar.v         $H/player/video_compositor.v $H/player/audio_spectrum_osd.v $H/player/alarm_screen.v $H/player/alarm_rom.v $H/player/color_lut_gen.v $H/player/gamma_rom.v         $H/player/osd_font_rom.v $H/player/osd_str_rom.v $H/player/player_ctrl.v $H/player/audio_i2s_player.v || exit 1
    $VVP -n tb_alarm.vvp | tee tb_alarm.log
    grep -q "tb_alarm PASS" tb_alarm.log || rc=1
    $PY check_alarm.py || rc=1
fi
if [ "$what" = all ] || [ "$what" = spec ]; then
    mkdir -p frames spec
    $IV -g2005 -I $H/player -o tb_spec_unit.vvp tb_spec_unit.v $H/player/audio_spectrum_osd.v || exit 1
    $VVP -n tb_spec_unit.vvp | tee tb_spec_unit.log
    $PY check_spec.py || rc=1
    $IV -g2005 -I . -I $H/player -I $H/SD -o tb_spec.vvp         tb_spec.v $H/SD/video_timing_data.v $H/SD/color_bar.v $H/player/video_compositor.v         $H/player/audio_spectrum_osd.v $H/player/alarm_screen.v $H/player/alarm_rom.v $H/player/color_lut_gen.v $H/player/gamma_rom.v $H/player/osd_font_rom.v $H/player/osd_str_rom.v || exit 1
    $VVP -n tb_spec.vvp | tee tb_spec.log
    $PY check_spec_img.py || rc=1
fi
if [ "$what" = all ] || [ "$what" = term ]; then
    mkdir -p frames
    $IV -g2005 -I $H/player -o tb_term.vvp tb_term.v $H/player/term_top.v $H/player/tmds_encoder.v         $H/player/term_prog_rom.v $H/player/term_font_rom.v $H/player/term_vram_c.v $H/player/term_vram_a.v $H/player/kb_matrix4x4.v || exit 1
    $IV -g2005 -o tb_termcmd.vvp tb_termcmd.v $H/player/player_ctrl.v || exit 1
    $VVP -n tb_termcmd.vvp | tee tb_termcmd.log
    grep -q "tb_termcmd PASS" tb_termcmd.log || rc=1
    $VVP -n tb_term.vvp | tee tb_term.log
    grep -q "tb_term PASS" tb_term.log || rc=1
    $PY check_term.py || rc=1
fi
if [ "$what" = all ] || [ "$what" = sdram ]; then
    $IV -g2005 -I $H/SD -o tb_sdram_arb.vvp         tb_sdram_arb.v $H/player/frame_dual_read_write.v $H/SD/frame_fifo_write.v         $H/SD/video_timing_data.v $H/SD/color_bar.v $H/IP/afifo_32_16_256.v $H/IP/afifo_16_32_256.v || exit 1
    $VVP -n tb_sdram_arb.vvp | tee tb_sdram_arb.log
    grep -q "tb_sdram_arb PASS" tb_sdram_arb.log || rc=1
fi

# 音频通路: FIFO 缩小到 1024 深 (AW=10) 使指针频繁回绕;
#   32k/48k 充足供数: 输出频率/幅度正确、无断续, FIFO 读出与写入逐个一致
#   32k 供数 85%: 欠载时暂停 (不重复/不跳样本), 恢复后音调不变
if [ "$what" = all ] || [ "$what" = audio ]; then
    mkdir -p audio
    arun() {    # 名称 采样率 供数% 检查模式
        ( cd audio &&
          $PY ../check_audio.py gen $2 9000 &&
          $IV -g2005 -o tb_audio.vvp -Ptb_audio.RATE=$2 -Ptb_audio.N_IN=9000 -Ptb_audio.N_OUT=7000 \
              -Ptb_audio.AW=10 -Ptb_audio.SUP=$3 ../tb_audio.v ../$H/player/async_fifo.v \
              ../$H/player/audio_i2s_player.v ../$H/I2S_receiver.v &&
          $VVP -n tb_audio.vvp > tb_audio_$1.log &&
          $PY ../check_audio.py $4 $2 >> tb_audio_$1.log )
        cat audio/tb_audio_$1.log
        grep -q " 0 data errors" audio/tb_audio_$1.log && grep -q "check_audio PASS" audio/tb_audio_$1.log || rc=1
    }
    arun 32k 32000 0 check
    arun 48k 48000 0 check
    arun starve 32000 85 starve
fi
exit $rc
