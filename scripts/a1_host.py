#!/usr/bin/env python
"""LeKiwi host（机器人端）：读 config/env，构造配置后直接调用上游 lekiwi_host.main。

为什么不用 `python -m lerobot.robots.lekiwi.lekiwi_host`：
  上游的相机配置写死在 `config_lekiwi.py::lekiwi_cameras_config()` 里（不同板卡、不同
  相机型号的节点名都不一样），命令行无法覆盖。

为什么能直接传 config：
  上游 main 被 `@draccus.wrap()` 装饰，其内层实现是
      if len(args) > 0 and type(args[0]) is argtype: cfg = args[0] ...
  也就是说，把完整的 config 对象作为第一个位置参数传入就会跳过命令行解析。
  这样既不修改上游源码，也不用复制它那段 60 行的主循环。

用法（一般通过 scripts/a1_host.sh 调用）:
  python scripts/a1_host.py
"""

from __future__ import annotations

import builtins
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _env import cfg, cfg_int, cfg_optional  # noqa: E402

from lerobot.cameras.configs import Cv2Rotation  # noqa: E402
from lerobot.cameras.opencv.configuration_opencv import OpenCVCameraConfig  # noqa: E402
from lerobot.robots.lekiwi.config_lekiwi import LeKiwiConfig, LeKiwiHostConfig  # noqa: E402
from lerobot.robots.lekiwi.lekiwi import LeKiwi  # noqa: E402
from lerobot.robots.lekiwi.lekiwi_host import LeKiwiServerConfig, main as host_main  # noqa: E402

ROTATIONS = {
    0: Cv2Rotation.NO_ROTATION,
    90: Cv2Rotation.ROTATE_90,
    180: Cv2Rotation.ROTATE_180,
    270: Cv2Rotation.ROTATE_270,
}


def build_cameras() -> dict:
    """按 config/env 构造相机；CAMERA_WRIST 为空则不启用相机。"""
    wrist = cfg_optional("CAMERA_WRIST")
    if not wrist:
        return {}

    rotate = cfg_int("CAMERA_ROTATE", 90)
    if rotate not in ROTATIONS:
        print(f"[!] CAMERA_ROTATE={rotate} 不支持，改用 90")
        rotate = 90

    node = Path(wrist)
    if not node.exists():
        print(f"[x] 相机节点不存在: {node}")
        print("    查真实节点: sh scripts/a1_detect.sh")
        print("    只想先跑通底盘: 把 config/env 里 CAMERA_WRIST 留空")
        raise SystemExit(3)

    return {
        "wrist": OpenCVCameraConfig(
            index_or_path=node,
            fps=cfg_int("CAMERA_FPS", 30),
            width=cfg_int("CAMERA_WIDTH", 480),
            height=cfg_int("CAMERA_HEIGHT", 640),
            fourcc=cfg("CAMERA_FOURCC", "MJPG"),
            rotation=ROTATIONS[rotate],
        )
    }


def main() -> int:
    # 上游用 logging.info 打印关键进度（"Waiting for commands..." 等），
    # 默认 root 级别是 WARNING，后台运行时这些信息会全部丢掉，排障时很难受。
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )

    robot_cfg = LeKiwiConfig(
        id=cfg("ROBOT_ID", "my_kiwi"),
        port=cfg("ROBOT_PORT", "/dev/ttyACM0"),
        cameras=build_cameras(),
    )
    host_cfg = LeKiwiHostConfig(
        port_zmq_cmd=cfg_int("ZMQ_CMD_PORT", 5555),
        port_zmq_observations=cfg_int("ZMQ_OBS_PORT", 5556),
        connection_time_s=cfg_int("CONNECTION_TIME_S", 3600),
    )

    # 只用来算校准文件路径，不会连接硬件
    robot = LeKiwi(robot_cfg)
    if not robot.calibration_fpath.is_file():
        print(f"[x] 未找到 follower 校准文件: {robot.calibration_fpath}")
        print("    先在终端里跑一次交互式校准: sh scripts/a1_calibrate.sh")
        return 2

    if not sys.stdin.isatty():
        # 后台上跑时上游会 input() 询问"是否复用校准文件"，无 stdin 会 EOFError。
        # 这里统一回空回车 = 复用现有校准文件（也就是原本 `echo |` 做的事）。
        builtins.input = lambda *a, **k: ""  # type: ignore[assignment]
        print(f"[i] 非交互模式：复用校准文件 {robot.calibration_fpath}")

    print(
        f"[i] robot.id={robot_cfg.id} port={robot_cfg.port} "
        f"cameras={list(robot_cfg.cameras)} time_s={host_cfg.connection_time_s}"
    )
    host_main(LeKiwiServerConfig(robot=robot_cfg, host=host_cfg))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
