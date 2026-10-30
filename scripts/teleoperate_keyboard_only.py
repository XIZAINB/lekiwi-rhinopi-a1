#!/usr/bin/env python
# Copyright 2025 The HuggingFace Inc. team. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# 衍生自 lerobot `examples/lekiwi/teleoperate.py` 的纯键盘版本：
#   1. 不接 leader 臂，把观测到的舵机位置原样回写，机械臂保持原地
#   2. host 地址 / id 改为读 config/env
#
# 注意：动作里必须同时带 6 个 arm_*.pos 键 + 3 个底盘速度键，
#       缺机械臂键会让服务端 sync_write 收到空字典而报错。

"""LeKiwi 纯键盘遥操作（无 leader 遥控臂）。"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _env import cfg  # noqa: E402

from lerobot.robots.lekiwi import LeKiwiClient, LeKiwiClientConfig  # noqa: E402
from lerobot.teleoperators.keyboard.teleop_keyboard import (  # noqa: E402
    KeyboardTeleop,
    KeyboardTeleopConfig,
)
from lerobot.utils.errors import DeviceNotConnectedError  # noqa: E402
from lerobot.utils.robot_utils import precise_sleep  # noqa: E402

FPS = 30


def main() -> int:
    robot_config = LeKiwiClientConfig(
        remote_ip=cfg("BOARD_IP"),
        id=cfg("CLIENT_ID", "my_lekiwi"),
        port_zmq_cmd=int(cfg("ZMQ_CMD_PORT", "5555")),
        port_zmq_observations=int(cfg("ZMQ_OBS_PORT", "5556")),
    )
    keyboard_config = KeyboardTeleopConfig(id="my_laptop_keyboard")

    robot = LeKiwiClient(robot_config)
    keyboard = KeyboardTeleop(keyboard_config)

    print(f"连接 host: tcp://{robot_config.remote_ip}:{robot_config.port_zmq_cmd}")
    robot.connect()
    keyboard.connect()

    if not robot.is_connected or not keyboard.is_connected:
        raise ValueError("Robot or keyboard is not connected!")

    print("已连接。w/s 前后，a/d 左右，z/x 旋转，r/f 调速，Ctrl+C 退出。")
    print(f"当前速度档位：{robot.speed_levels[robot.speed_index]}")

    last_speed_index = robot.speed_index
    try:
        while True:
            t0 = time.perf_counter()

            observation = robot.get_observation()

            # 没有 leader 臂：把机械臂当前位姿原样发回去，保持原地
            arm_hold = {k: v for k, v in observation.items() if k.endswith(".pos")}
            if len(arm_hold) == 0:
                precise_sleep(0.1)
                continue

            keyboard_keys = keyboard.get_action()
            base_action = robot._from_keyboard_to_base_action(keyboard_keys)

            action = {**arm_hold, **base_action}
            robot.send_action(action)

            if robot.speed_index != last_speed_index:
                last_speed_index = robot.speed_index
                print(f"速度档位：{robot.speed_levels[robot.speed_index]}")

            precise_sleep(max(1.0 / FPS - (time.perf_counter() - t0), 0.0))
    except (KeyboardInterrupt, DeviceNotConnectedError):
        print("\n退出中…")
    finally:
        # 先判断连接状态再 disconnect，避免二次 disconnect 抛异常
        if robot.is_connected:
            robot.disconnect()
        if keyboard.is_connected:
            keyboard.disconnect()
        print("已断开。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
