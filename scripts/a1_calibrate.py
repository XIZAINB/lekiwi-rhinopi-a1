"""[板卡端] follower 校准（交互式，必须在终端里跑）。

相比 `lerobot-calibrate` 的两个改进：
  1. cameras={}：不连接相机 —— 上游默认配置会连 /dev/video0、/dev/video2，
     在 A1 上这两个常是 ISP 管理节点，打不开就直接报错，导致校准根本进不去。
  2. 不依赖 uv 的入口脚本（部分环境 `uv run lerobot-calibrate` 会 Failed to spawn）。

用法：
  sh scripts/a1_calibrate.sh                # 已校准且匹配 → 直接退出
  sh scripts/a1_calibrate.sh --recalibrate  # 强制重新校准
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _env import cfg  # noqa: E402

from lerobot.robots.lekiwi import LeKiwi, LeKiwiConfig  # noqa: E402


def main() -> int:
    force = "--recalibrate" in sys.argv

    robot_cfg = LeKiwiConfig(
        id=cfg("ROBOT_ID", "my_kiwi"),
        port=cfg("ROBOT_PORT", "/dev/ttyACM0"),
        cameras={},
    )
    robot = LeKiwi(robot_cfg)
    print(f"机器人: id={robot_cfg.id} port={robot_cfg.port}")
    print(f"校准文件: {robot.calibration_fpath}")

    robot.bus.connect()
    try:
        if force or not robot.is_calibrated:
            robot.calibrate()  # 内部会 input() 提示摆位
        else:
            print("已校准且与舵机一致，无需重校（要强制重校加 --recalibrate）")
        robot.configure()
    except KeyboardInterrupt:
        print("\n已中断，未保存")
        return 130
    finally:
        try:
            robot.disconnect()
        except Exception:  # noqa: BLE001
            pass

    if robot.calibration_fpath.is_file():
        print(f"OK 校准文件: {robot.calibration_fpath}")
        return 0
    print("! 没有生成校准文件，请检查上面的输出")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
