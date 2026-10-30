#!/bin/sh
# 板卡端设备探测：舵机总线串口 + 摄像头节点，并给出可直接粘贴到 config/env 的建议值。
# 用法： sh scripts/a1_detect.sh
set -u

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$REPO_DIR/config/env" ] && . "$REPO_DIR/config/env"
LEROBOT_DIR=${LEROBOT_DIR:-$HOME/lerobot}
PY="$LEROBOT_DIR/.venv/bin/python"

step() { printf '\n\033[36m== %s ==\033[0m\n' "$1"; }

step "1. 舵机总线串口（期望只有一个 /dev/ttyACM*）"
if ls -l /dev/ttyACM* 2>/dev/null; then
    :
else
    echo "  (无 /dev/ttyACM*) —— 检查舵机转接板 USB 与底盘供电"
fi
echo "  USB 设备线索："
if command -v lsusb >/dev/null 2>&1; then
    lsusb 2>/dev/null | grep -iE 'qinheng|ch34|1a86|feetech' || echo "    (未匹配到 CH34x / 飞特设备)"
else
    echo "    (没有 lsusb 命令)"
fi

step "2. 视频节点（by-id 别名）"
if ls -l /dev/v4l/by-id/ 2>/dev/null; then
    :
else
    echo "  (无 /dev/v4l/by-id/) —— 摄像头未插好，或系统没装 v4l-utils"
fi

step "3. 逐个试开 /dev/video*（判断哪个真能出图）"
if [ -x "$PY" ]; then
    "$PY" - <<'PYEOF'
import glob
try:
    import cv2
except Exception as exc:  # noqa: BLE001
    print(f"  (无法 import cv2: {exc})")
    raise SystemExit(0)

for path in sorted(glob.glob("/dev/video*")):
    cap = cv2.VideoCapture(path)
    ok = cap.isOpened()
    frame_ok = False
    if ok:
        ret, _ = cap.read()
        frame_ok = bool(ret)
    cap.release()
    tag = "可采集" if frame_ok else ("能打开但读不到帧" if ok else "打不开")
    print(f"  {path}: {tag}")
PYEOF
else
    echo "  (未找到 $PY) —— 先跑 sh scripts/a1_bootstrap.sh"
fi

step "4. 建议写入 config/env 的值"
echo "  ROBOT_PORT=/dev/ttyACM0        # 若上面列出的编号不同，按实际改"
echo "  CAMERA_WRIST=<下面 by-id 里能出图的那个>"
echo
echo "  提示：优先用 /dev/v4l/by-id/ 下的别名，不要用 /dev/videoN ——"
echo "        板载 ISP/管理节点常占用 video0/video1（能打开却读不到帧），且重启后编号可能变。"
