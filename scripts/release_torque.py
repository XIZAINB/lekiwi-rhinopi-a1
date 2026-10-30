"""板卡端：释放全部舵机扭矩，便于手动摆动机械臂。

用途：零点对齐前把 follower 与 leader 摆成同一姿势。

注意：必须先停掉 host（串口被占用时会连不上）。
     sh scripts/a1_host.sh stop
     sh scripts/a1_host.sh release-torque
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _env import cfg  # noqa: E402

from lerobot.robots.lekiwi import LeKiwi, LeKiwiConfig  # noqa: E402


def main() -> int:
    # cameras={} : 释放扭矩不需要相机，避免相机没插时报错
    robot_cfg = LeKiwiConfig(
        id=cfg("ROBOT_ID", "my_kiwi"),
        port=cfg("ROBOT_PORT", "/dev/ttyACM0"),
        cameras={},
    )
    robot = LeKiwi(robot_cfg)
    try:
        robot.connect(calibrate=False)
        robot.bus.disable_torque()
    finally:
        # disconnect() 时 disable_torque_on_disconnect=True，断开后手臂是松的
        robot.disconnect()
    print("TORQUE_RELEASED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
