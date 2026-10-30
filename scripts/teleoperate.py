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

# 衍生自 lerobot `examples/lekiwi/teleoperate.py`（commit 53feaef），改动：
#   1. remote_ip / leader 串口 / id 改为读 config/env（上游写死在 main() 里，无 CLI 参数）
#   2. rerun 可视化降频到 LOG_FPS（上游 30fps 推 480x640 图像会吃满 1 GiB gRPC 缓存上限）
# 其余逻辑与上游一致。

"""LeKiwi 遥操作：leader 臂控机械臂 + 键盘控底盘。"""

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
from lerobot.teleoperators.so_leader import SO100Leader, SO100LeaderConfig  # noqa: E402
from lerobot.utils.robot_utils import precise_sleep  # noqa: E402
from lerobot.utils.visualization_utils import init_rerun, log_rerun_data  # noqa: E402

FPS = 30
LOG_FPS = 5
LOG_EVERY = max(1, FPS // LOG_FPS)


def main():
    robot_config = LeKiwiClientConfig(
        remote_ip=cfg("BOARD_IP"),
        id=cfg("CLIENT_ID", "my_lekiwi"),
        port_zmq_cmd=int(cfg("ZMQ_CMD_PORT", "5555")),
        port_zmq_observations=int(cfg("ZMQ_OBS_PORT", "5556")),
    )
    teleop_arm_config = SO100LeaderConfig(
        port=cfg("LEADER_PORT", "COM11"),
        id=cfg("LEADER_ID", "my_awesome_leader_arm"),
    )
    keyboard_config = KeyboardTeleopConfig(id="my_laptop_keyboard")

    robot = LeKiwiClient(robot_config)
    leader_arm = SO100Leader(teleop_arm_config)
    keyboard = KeyboardTeleop(keyboard_config)

    print(f"连接 host: tcp://{robot_config.remote_ip}:{robot_config.port_zmq_cmd}")
    print(f"leader 串口: {teleop_arm_config.port}")
    robot.connect()
    leader_arm.connect()
    keyboard.connect()

    init_rerun(session_name="lekiwi_teleop")

    if not robot.is_connected or not leader_arm.is_connected or not keyboard.is_connected:
        raise ValueError("Robot or teleop is not connected!")

    print("Starting teleop loop...")
    frame_idx = 0
    while True:
        t0 = time.perf_counter()

        observation = robot.get_observation()

        arm_action = leader_arm.get_action()
        arm_action = {f"arm_{k}": v for k, v in arm_action.items()}

        keyboard_keys = keyboard.get_action()
        base_action = robot._from_keyboard_to_base_action(keyboard_keys)

        action = {**arm_action, **base_action} if len(base_action) > 0 else arm_action

        _ = robot.send_action(action)

        if frame_idx % LOG_EVERY == 0:
            log_rerun_data(observation=observation, action=action)
        frame_idx += 1

        precise_sleep(max(1.0 / FPS - (time.perf_counter() - t0), 0.0))


if __name__ == "__main__":
    main()
