"""零点对齐：把 leader 各关节零点对齐到 follower（两边需处于同一物理姿势）。

原理
    DEGREES 模式下 leader 角度 = (raw - mid) * 360/4095，
    改写舵机 homing_offset 就能让 raw 平移，从而让角度平移。
    脚本会实测校验符号（old-delta / old+delta 取误差更小的那个），不靠猜。

前置
    1) follower 松扭矩，并把 leader 与 follower 摆成**完全一样**的姿势
       （底座朝前、大臂竖直、小臂水平、腕部水平、夹爪半开）
    2) 板端 host 已启动（torque 已使能，会保持该姿势）

用法
    python scripts/align_leader_to_follower.py --dry-run   # 只测差，不写入
    python scripts/align_leader_to_follower.py             # 测差 + 对齐 + 复测

一般通过 scripts/zero_align.ps1 调用（它会自动完成"停 host → 松扭矩 → 摆姿势 → 起 host"）。
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _env import cfg  # noqa: E402

from lerobot.robots.lekiwi import LeKiwiClient, LeKiwiClientConfig  # noqa: E402
from lerobot.teleoperators.so_leader import SO100Leader, SO100LeaderConfig  # noqa: E402

JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]
K = 360.0 / 4095.0
SAMPLES = 6
TOLERANCE_DEG = 1.0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="leader 零点对齐到 follower")
    ap.add_argument("-n", "--dry-run", action="store_true", help="只测差，不写入校准文件")
    args = ap.parse_args(argv)

    robot_cfg = LeKiwiClientConfig(
        remote_ip=cfg("BOARD_IP"),
        id=cfg("CLIENT_ID", "my_lekiwi"),
        port_zmq_cmd=int(cfg("ZMQ_CMD_PORT", "5555")),
        port_zmq_observations=int(cfg("ZMQ_OBS_PORT", "5556")),
    )
    leader_cfg = SO100LeaderConfig(
        port=cfg("LEADER_PORT", "COM11"),
        id=cfg("LEADER_ID", "my_awesome_leader_arm"),
    )

    print(f"连接 host: tcp://{robot_cfg.remote_ip}:{robot_cfg.port_zmq_cmd}")
    robot = LeKiwiClient(robot_cfg)
    robot.connect()
    f_acc = dict.fromkeys(JOINTS, 0.0)
    for _ in range(SAMPLES):
        obs = robot.get_observation()
        for j in JOINTS:
            f_acc[j] += obs[f"arm_{j}.pos"]
        time.sleep(0.05)
    robot.disconnect()
    f_val = {j: f_acc[j] / SAMPLES for j in JOINTS}

    leader = SO100Leader(SO100LeaderConfig(port=leader_cfg.port, id=leader_cfg.id))
    leader.connect(calibrate=False)
    bus = leader.bus
    l_val = {j: leader.get_action()[f"{j}.pos"] for j in JOINTS}

    print(f"\n{'joint':<15}{'leader':>10}{'follower':>10}{'delta':>10}{'delta_raw':>11}")
    print("-" * 56)
    plan = {}
    for j in JOINTS:
        delta_deg = f_val[j] - l_val[j]
        delta_raw = round(delta_deg / K)
        old = leader.calibration[j].homing_offset
        plan[j] = {"old": old, "delta_raw": delta_raw}
        print(f"{j:<15}{l_val[j]:>10.2f}{f_val[j]:>10.2f}{delta_deg:>10.2f}{delta_raw:>11}")

    worst = max(abs(f_val[j] - l_val[j]) for j in JOINTS)
    if args.dry_run:
        bus.disconnect()
        print(f"\n[dry-run] 最大偏差 {worst:.2f}°，未写入。去掉 --dry-run 即执行对齐。")
        return 0

    def apply(sign: int) -> float:
        for j in JOINTS:
            p = plan[j]
            bus.write("Homing_Offset", j, p["old"] - sign * p["delta_raw"])
        time.sleep(0.3)
        return sum(abs(f_val[j] - leader.get_action()[f"{j}.pos"]) for j in JOINTS)

    err_minus = apply(1)
    err_plus = apply(-1)
    use_sign = 1 if err_minus <= err_plus else -1
    apply(use_sign)
    print(
        f"\n符号校验：old-delta={err_minus:.2f}，old+delta={err_plus:.2f}"
        f" → 采用 {'old-delta' if use_sign == 1 else 'old+delta'}"
    )

    l_new = leader.get_action()
    print(f"\n{'joint':<15}{'leader(新)':>12}{'follower':>10}{'残差':>9}")
    print("-" * 46)
    residual_max = 0.0
    for j in JOINTS:
        cal = leader.calibration[j]
        leader.calibration[j] = type(cal)(
            id=cal.id,
            drive_mode=cal.drive_mode,
            homing_offset=int(plan[j]["old"] - use_sign * plan[j]["delta_raw"]),
            range_min=cal.range_min,
            range_max=cal.range_max,
        )
        residual = f_val[j] - l_new[f"{j}.pos"]
        residual_max = max(residual_max, abs(residual))
        print(f"{j:<15}{l_new[f'{j}.pos']:>12.2f}{f_val[j]:>10.2f}{residual:>9.2f}")

    bus.write_calibration(leader.calibration)
    leader._save_calibration()
    bus.disconnect()
    print(f"\n已保存: {leader.calibration_fpath}")

    if residual_max > TOLERANCE_DEG:
        print(f"[!] 最大残差 {residual_max:.2f}° 超过 {TOLERANCE_DEG}°，建议重摆姿势再跑一次")
        return 1
    print(f"[ok] 最大残差 {residual_max:.2f}° ≤ {TOLERANCE_DEG}°")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
