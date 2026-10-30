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
#   3. 【新增】回写死区 + EMA 平滑：避免把读取噪声/坏包当成目标值来回写，
#      否则机械臂会持续抖动（实测 shoulder_pan 单帧可跳 3.8°）
#   4. 【新增】可选 rerun 可视化：--rerun 或 SHOW_RERUN=1
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
from lerobot.utils.visualization_utils import init_rerun, log_rerun_data  # noqa: E402

FPS = 30
LOG_FPS = 5
LOG_EVERY = max(1, FPS // LOG_FPS)


def _cfg_float(key: str, default: float) -> float:
    try:
        return float(cfg(key, str(default)))
    except ValueError:
        return default


def main() -> int:
    show_rerun = "--rerun" in sys.argv or cfg("SHOW_RERUN", "0").strip() == "1"
    deadband = _cfg_float("ARM_HOLD_DEADBAND", 0.5)   # 度：小于该变化就不更新目标
    alpha = _cfg_float("ARM_HOLD_ALPHA", 0.6)         # EMA 平滑系数 0~1
    alpha = min(max(alpha, 0.05), 1.0)
    max_jump = _cfg_float("ARM_HOLD_MAX_JUMP", 10.0)  # 度：单帧跳变超过此值视为坏包

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
    print(f"机械臂保持滤波：deadband={deadband}° alpha={alpha} 跳变阈值={max_jump}°（config/env 可调）")
    print(f"可视化窗口：{'开' if show_rerun else '关（加 --rerun 或 SHOW_RERUN=1 打开）'}")

    if show_rerun:
        init_rerun(session_name="lekiwi_keyboard")

    # 机械臂“保持”目标：初始化后只在变化超过 deadband 时才更新，
    # 避免把单帧读取噪声（坏包）当成新目标反复下发。
    hold: dict[str, float] = {}
    raw_prev: dict[str, float] = {}
    rejected = 0
    last_speed_index = robot.speed_index
    frame_idx = 0
    try:
        while True:
            t0 = time.perf_counter()

            observation = robot.get_observation()

            raw_hold = {k: v for k, v in observation.items() if k.endswith(".pos")}
            if len(raw_hold) == 0:
                precise_sleep(0.1)
                continue

            for key, value in raw_hold.items():
                prev_raw = raw_prev.get(key)
                raw_prev[key] = value
                if prev_raw is not None and abs(value - prev_raw) > max_jump:
                    # 飞特总线偶发坏包：单帧跳变过大，当帧忽略（否则会被当成新目标下发）
                    rejected += 1
                    continue
                prev = hold.get(key)
                if prev is None:
                    hold[key] = value
                    continue
                filtered = prev + alpha * (value - prev)
                if abs(filtered - prev) >= deadband:
                    hold[key] = filtered

            keyboard_keys = keyboard.get_action()
            base_action = robot._from_keyboard_to_base_action(keyboard_keys)

            action = {**hold, **base_action}
            robot.send_action(action)

            if show_rerun and frame_idx % LOG_EVERY == 0:
                log_rerun_data(observation=observation, action=action)
            frame_idx += 1

            if robot.speed_index != last_speed_index:
                last_speed_index = robot.speed_index
                print(f"速度档位：{robot.speed_levels[robot.speed_index]}")

            precise_sleep(max(1.0 / FPS - (time.perf_counter() - t0), 0.0))
    except (KeyboardInterrupt, DeviceNotConnectedError):
        print("\n退出中…")
    finally:
        if rejected:
            print(f"本次共忽略 {rejected} 个跳变样本（总线坏包）")
        # 先判断连接状态再 disconnect，避免二次 disconnect 抛异常
        if robot.is_connected:
            robot.disconnect()
        if keyboard.is_connected:
            keyboard.disconnect()
        print("已断开。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
