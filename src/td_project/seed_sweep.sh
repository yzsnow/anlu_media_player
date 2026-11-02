#!/bin/sh
# 依次尝试布局种子, 直到 BUILD_OK 且 sd_card_clk / pix_clk / hdmi_5x_clk / video_clk / term_clk / term_5x_clk 的 SWNS 都不小于 0
#   sh seed_sweep.sh 5 11 12 3 2
cd "$(dirname "$0")"
TD=/d/APP/TD6.2.1/bin/td_commands_prompt.exe
# 命令行编译用 cli_build.al (TD 图形界面只会改写 HDMI1.4b_Transmitter_v1.0.al);
# 编译前核对 files.tcl 中的 player/ 源文件都在 cli_build.al 里且未被排除
AL=cli_build.al
bad=0
for f in $(grep -o 'player/[A-Za-z0-9_]*\.v' ../build/files.tcl); do
    if ! grep -q "hdl_source/$f\"" $AL; then echo "ERROR: $AL 中缺少 $f"; bad=1; fi
done
if grep -B3 'AutoExcluded" Val="true' $AL | grep -q 'hdl_source/player/'; then
    echo "ERROR: $AL 中有 player/ 文件被标记为 AutoExcluded:"; grep -B3 'AutoExcluded" Val="true' $AL | grep 'player/'; bad=1
fi
if [ $bad = 1 ]; then echo "cli_build.al 与 files.tcl 不一致, 请先补齐"; exit 2; fi
for s in "$@"; do
    echo "=== seed $s ==="
    TD_SEED=$s $TD cli_build.tcl > cli_build_seed$s.log 2>&1
    if ! grep -a -q "^BUILD_OK" cli_build_seed$s.log; then
        echo "seed $s: BUILD_FAIL ($(grep -a -m1 'ERROR' cli_build_seed$s.log | cut -c1-100))"
        continue
    fi
    # 按时钟名取 SWNS (Clock Summary 中 clkN 与名字的对应关系每次可能不同)
    awk '
        /Clock-Id:/ {cs=1; next}
        cs && /^ +clk[0-9]+:/ {id=$1; sub(":","",id); name[id]=$4; n++; next}
        cs && /^-+$/ && n>0 {cs=0}
        /^       clk[0-9]+ / && ($1 in name) {print name[$1], $9}
    ' cli_out/player_pr.timing > seed$s.swns
    cat seed$s.swns
    bad=$(awk '($1=="sd_card_clk"||$1=="pix_clk"||$1=="hdmi_5x_clk"||$1=="video_clk"||$1=="term_clk"||$1=="term_5x_clk") && $2+0 < 0' seed$s.swns)
    if [ -z "$bad" ]; then
        echo "seed $s: PASS"
        exit 0
    fi
    echo "seed $s: timing fail: $bad"
done
exit 1
