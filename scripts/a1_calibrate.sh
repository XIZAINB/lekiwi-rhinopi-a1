#!/bin/sh
# 板卡端：follower 臂 + 底盘 校准（交互式，必须在终端里跑）。
# 用法： sh scripts/a1_calibrate.sh [--recalibrate]
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO_DIR/config/env"
LEROBOT_DIR=${LEROBOT_DIR:-$HOME/lerobot}
ROBOT_PORT=${ROBOT_PORT:-/dev/ttyACM0}
ROBOT_ID=${ROBOT_ID:-my_kiwi}
PY="$LEROBOT_DIR/.venv/bin/python"

[ -e "$ROBOT_PORT" ] || {
    printf '\033[31m[x]\033[0m 找不到 %s\n' "$ROBOT_PORT"
    printf '    先跑 sh scripts/a1_detect.sh 确认真实串口，并检查底盘供电\n'
    exit 1
}

cat <<'TIPS'
==========================================================
follower 校准流程（必须人在旁边操作）
==========================================================
1) 若已有校准文件，会先问：回车=复用旧文件，输入 c 回车=重新校准
   → 首次装配请输 c

2) 【中间位姿】把机械臂各关节先推到两端硬限位，再回到行程中间
   → 然后才按回车（这一步决定零点，别偷懒）

3) 【扫行程】除 wrist_roll 和轮子外，每个关节都要
   两个方向都推到硬限位；夹爪完全闭合 ↔ 完全张开
   → 然后才按回车结束记录

4) 只推一个方向 / 记录被打断 → 会报
   "Some motors have the same min and max values"
   → 老老实实手按回车，不要用脚本代按（会残留换行导致记录立即结束）

5) 轮子不需要摆，脚本会自动给整圈范围
==========================================================
TIPS
printf '\n准备好了按回车继续（Ctrl+C 放弃）... '
read -r _ || true

[ -x "$PY" ] || {
    printf '\033[31m[x]\033[0m 没找到 %s，先跑 sh scripts/a1_bootstrap.sh\n' "$PY"
    exit 1
}

cd "$LEROBOT_DIR"
"$PY" "$REPO_DIR/scripts/a1_calibrate.py" "$@"

CALIB="$HOME/.cache/huggingface/lerobot/calibration/robots/lekiwi/$ROBOT_ID.json"
printf '\n'
if [ -f "$CALIB" ]; then
    printf '\033[32m[ok]\033[0m 校准文件: %s\n' "$CALIB"
    printf '     下一步：到电脑端跑 scripts\\zero_align.ps1 做零点对齐\n'
else
    printf '\033[33m[!]\033[0m 没找到校准文件 %s，校准可能没保存成功\n' "$CALIB"
fi
