# lekiwi-rhinopi-a1

> 在**犀牛派 A1（AidLux / ARM64）**上运行 [LeKiwi](https://github.com/huggingface/lerobot) 主机端的完整部署方案：板卡环境、串口/相机识别、校准、零点对齐与排障。
>
> One-command setup for running the LeKiwi robot host on a Rhino Pi A1 (AidLux, ARM64), including calibration and leader-arm zero-alignment helpers.

---

## 1. 这是什么

一块新板卡 + 一台新电脑，`git clone` 之后：

| 关卡 | 做什么 | 命令 | 实测 |
| --- | --- | --- | --- |
| **T1** | 板卡环境 + 启动 host | `a1_bootstrap.sh` → `a1_host.sh start` | ✅ |
| **T2** | 电脑环境 + 键盘遥控底盘 | `win_bootstrap.ps1` → `teleop.ps1 -Keyboard` | ✅ |
| **T3** | 接 leader 臂，校准 + 零点对齐后拖臂遥操作 | `win_calibrate.ps1` → `zero_align.ps1` → `teleop.ps1` | ✅ |
| **T4** | 异常场景的可读报错（拔线 / host 未启动） | — | ⬜ |

> 实测环境：犀牛派 A1（Ubuntu 24.04.3 / aarch64）+ Windows 11 + SO100 leader 臂，2026-10-30。
> 详见第 7 节「实测版本」与 `docs/troubleshooting.md`。

## 2. 这不是什么（重要边界）

- ❌ **不包含校准文件**。`homing_offset` 是**每台机器、每次装配独有**的，无法随仓库分发。
  → 脚本负责「环境 + 配置 + 启动 + 自检」，校准走**带提示的引导流程**，人负责摆臂和按回车。
- ❌ 不包含硬件资料。BOM、3D 件、装配请看 [SIGRobotics-UIUC/LeKiwi](https://github.com/SIGRobotics-UIUC/LeKiwi)。
- ❌ 不包含舵机厂商的调试软件/PDF，请到厂商官网下载。
- ❌ 不修改 lerobot 源码。`lerobot` 按固定 commit 原样 checkout，本仓库只做配置与编排。

> 本仓库不是 fork。`scripts/teleoperate.py` 与 `scripts/teleoperate_keyboard_only.py`
> 是 lerobot `examples/lekiwi/` 的衍生文件（Apache-2.0，文件头保留原声明并标注改动）。
> 上游 `examples/lekiwi/teleoperate.py` 的 `remote_ip` / `port` 写死在 `main()` 里、没有 CLI 参数，
> 所以只能复制一份改，这是本仓库唯一复制上游代码的地方。

---

## 3. 前置条件

### 硬件

- 犀牛派 A1（实测 Ubuntu 24.04.3 LTS / aarch64；AidLux 系系统也可）
- LeKiwi 底盘 + SO100/101 follower 臂 + 9 个 Feetech STS3215（ID 1~9 已设置）
- **底盘电池已上电** —— 舵机与轮子由底盘电池供电，USB 只给转接板。
  未上电时 `FeetechMotorsBus.scan_port()` 返回空字典，host 会报 `Missing motor IDs: 1~9`
- USB 转接板（舵机总线）、USB 摄像头（腕部）
- leader 遥控臂 + CH343/CH340 USB 线（T3 才需要）

### 软件

- 板卡：`git`、`curl`、能上外网（装 `uv` 与 Python 依赖）
- 电脑：Windows 10/11 + PowerShell 5.1；会用到 `ssh`

### 网络

板卡与电脑在**同一网段**，且路由器未开 AP 隔离。板卡 IP 用 `hostname -I` 查（默认 DHCP，可能变化）。

---

## 4. 快速开始

### 第 1 步 · 板卡端（T1）

```bash
ssh <BOARD_USER>@<BOARD_IP>

git clone https://github.com/XIZAINB/lekiwi-rhinopi-a1.git ~/lekiwi-rhinopi-a1
cd ~/lekiwi-rhinopi-a1

# 一次性环境准备（可重复执行）：apt 依赖 → uv → clone lerobot@<commit> → uv sync → 瘦身 → 自检
sh scripts/a1_bootstrap.sh
```

脚本会自动生成 `config/env`（从 `env.example` 复制）。**你只需改这一个文件**：

```bash
vi config/env          # 关键项：CAMERA_WRIST（可先跑 sh scripts/a1_detect.sh 拿建议值）
sh scripts/a1_detect.sh
```

> 脚本会自动做「瘦身」：把 CUDA 版 torch 换成 CPU 版并清掉 `nvidia`/`cuda`/`triton`。
> A1 没有 NVIDIA GPU，不瘦身的话 `uv sync` 会多下 ~3.4 GB。
> 实测 venv 从 **4.7 GB → 848 MB**，遥操作不受影响。跳过瘦身：`SLIM_VENV=0 sh scripts/a1_bootstrap.sh`。

第一次必须先校准 follower（交互式，会提示你怎么摆臂）。已有校准文件时会**自动跳过**，需强制重校加 `--recalibrate`：

```bash
sh scripts/a1_calibrate.sh                # 无校准文件才会进入摆位流程
sh scripts/a1_calibrate.sh --recalibrate  # 强制重新校准
```

启动 host：

```bash
sh scripts/a1_host.sh start     # 后台启动
sh scripts/a1_host.sh status    # 看进程 + 日志尾部
sh scripts/a1_host.sh log       # tail -f
sh scripts/a1_host.sh stop      # 停止（扭矩会保持，见下）
```

看到 `[ok] host 就绪（ZMQ 端口 5555 已监听）` 即成功。

> 就绪判据用的是**端口监听**，不是日志文案 —— 上游把 `Waiting for commands...` 打在 INFO 级别，默认不输出。

> `a1_host.sh stop` 是强杀，**不会释放扭矩**，手臂仍是锁死的。
> 要手动摆臂请跑：`sh scripts/a1_host.sh release-torque`

### 第 2 步 · 电脑端（T2）

```powershell
git clone https://github.com/XIZAINB/lekiwi-rhinopi-a1.git C:\lekiwi-rhinopi-a1
cd C:\lekiwi-rhinopi-a1

# 一次性环境准备（可重复执行）：uv → clone lerobot → uv sync → 探测 COM 口 → 自检
powershell -ExecutionPolicy Bypass -File scripts\win_bootstrap.ps1
```

编辑 `config\env`，填入板卡信息：

```ini
BOARD_IP=192.168.1.100
BOARD_USER=aidlux
```

先用纯键盘验证底盘与相机（不需要 leader 臂）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\teleop.ps1 -Keyboard
```

| 按键 | 作用 |
| --- | --- |
| `w` / `s` | 前进 / 后退 |
| `a` / `d` | 左移 / 右移 |
| `z` / `x` | 原地左转 / 右转 |
| `r` / `f` | 加速 / 减速（0.1 / 0.2 / 0.3 m/s） |
| `Ctrl+C` | 退出（底盘由 host 看门狗 0.5 s 内自动停） |

> 想同时看腕部相机画面，加 `-Rerun`：`teleop.ps1 -Keyboard -Rerun`（或 `config/env` 里设 `SHOW_RERUN=1`）。
> 纯键盘模式默认**不弹**可视化窗口。

### 第 3 步 · 接 leader 臂（T3）

```powershell
# 1) leader 串口（换 USB 口会变，务必确认）
powershell -ExecutionPolicy Bypass -File scripts\win_bootstrap.ps1 -DetectOnly

# 2) leader 校准（必须手按回车，脚本会提示）
powershell -ExecutionPolicy Bypass -File scripts\win_calibrate.ps1

# 3) 零点对齐：松扭矩 → 把两臂摆成同一姿势 → 一条命令完成测差/对齐/复测
powershell -ExecutionPolicy Bypass -File scripts\zero_align.ps1

# 4) 遥操作
powershell -ExecutionPolicy Bypass -File scripts\teleop.ps1
```

> **任意一侧重新校准过，都必须重跑 `zero_align.ps1`**，否则遥操作会出现固定角度偏差。

---

## 4.1 日常命令速查（配好之后）

| 目的 | 命令 |
| --- | --- |
| 启动 host | `ssh aidlux@<IP> "cd ~/lekiwi-rhinopi-a1 && sh scripts/a1_host.sh start"` |
| 停止 host | `ssh aidlux@<IP> "cd ~/lekiwi-rhinopi-a1 && sh scripts/a1_host.sh stop"` |
| 看日志 | `ssh aidlux@<IP> "tail -f ~/host.log"` |
| 释放扭矩 | `ssh aidlux@<IP> "cd ~/lekiwi-rhinopi-a1 && sh scripts/a1_host.sh release-torque"` |
| 键盘遥控 | `powershell -ExecutionPolicy Bypass -File scripts\teleop.ps1 -Keyboard -Rerun` |
| leader 遥控 | `powershell -ExecutionPolicy Bypass -File scripts\teleop.ps1` |
| 重新对齐 | `powershell -ExecutionPolicy Bypass -File scripts\zero_align.ps1` |

---

## 5. 配置项（`config/env`）

一份文件，shell / Python / PowerShell 共用（PowerShell 通过脚本解析，不再单独维护 `env.ps1`）。

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `BOARD_IP` | — | 板卡 IP |
| `BOARD_USER` | `aidlux` | SSH 用户 |
| `BOARD_REPO` | `$HOME/lekiwi-rhinopi-a1` | 板上的本仓库路径 |
| `LEROBOT_DIR` | `$HOME/lerobot` | lerobot 代码路径 |
| `LEROBOT_COMMIT` | `53feaef` | 固定的 lerobot commit（两端必须一致） |
| `ROBOT_ID` | `my_kiwi` | follower 的校准 ID（板端） |
| `ROBOT_PORT` | `/dev/ttyACM0` | 舵机总线串口（板端） |
| `CAMERA_WRIST` | 空 | 腕部相机；**留空 = 不启用相机** |
| `CAMERA_FPS` / `CAMERA_WIDTH` / `CAMERA_HEIGHT` / `CAMERA_ROTATE` | `30 / 480 / 640 / 90` | 相机参数 |
| `ZMQ_CMD_PORT` / `ZMQ_OBS_PORT` | `5555 / 5556` | ZMQ 端口 |
| `CONNECTION_TIME_S` | `3600` | host 存活时间（默认 30 s 会自动退出） |
| `CLIENT_ID` | `my_lekiwi` | 控制端本地标识 |
| `LEADER_PORT` | `COM11` | leader 串口（电脑端） |
| `LEADER_ID` | `my_awesome_leader_arm` | leader 校准 ID |
| `SLIM_VENV` | `1` | 板端瘦身（换 CPU torch + 清 CUDA），`0` 关闭 |
| `ARM_HOLD_DEADBAND` | `0.5` | 纯键盘模式：回写死区（度），小于此变化不更新目标 |
| `ARM_HOLD_ALPHA` | `0.6` | 纯键盘模式：EMA 平滑系数（越小越稳、越迟钝） |
| `ARM_HOLD_MAX_JUMP` | `10.0` | 纯键盘模式：单帧跳变超过此值视为总线坏包并丢弃 |
| `SHOW_RERUN` | `0` | `1` = 默认弹 rerun 可视化窗口 |
| `MAX_RELATIVE_TARGET` | 空 | 单步最大变化量；留空不限 |

> 想临时覆盖某个值：直接设同名环境变量即可（如 `ROBOT_PORT=/dev/ttyACM1 sh scripts/a1_host.sh start`）。

---

## 6. 验收（发布/交付前跑一遍）

- [x] **T1**：新 A1 跑通 `a1_bootstrap.sh`，`a1_host.sh start` 报「host 就绪」，电脑端 `Test-NetConnection <BOARD_IP> -Port 5555/5556` 均为 True
- [x] **T2**：`teleop.ps1 -Keyboard` 能控底盘、`-Rerun` 有画面
- [x] **T3**：leader 校准 + 零点对齐后，拖臂无固定偏差（实测残差 0.13°）
- [ ] **T4**：抽掉相机 / 拔网线 / host 未启动，脚本给出**人能看懂的错误**而不是 traceback

> 遇到问题先看 [`docs/troubleshooting.md`](docs/troubleshooting.md)（板端 / 连接 / 校准 / 维护 四类共 20+ 条实测坑）。

---

## 7. 实测版本

| 组件 | 版本 |
| --- | --- |
| lerobot | commit `53feaef` |
| 板卡 | 犀牛派 A1（Ubuntu 24.04.3 / 内核 6.6.65-qli，aarch64） |
| Python（板端） | 3.12.3（由 `uv` 管理） |
| torch（板端） | `2.8.0+cpu`（瘦身后，`cuda_available: False`） |
| uv | 0.13.6 |
| 板端 venv 体积 | 848 MB（瘦身前 4.7 GB） |
| leader 臂 | SO100 leader + CH343（`COM11`） |
| 零点对齐实测 | 对齐前最大偏差 12.48°（`wrist_roll`）→ 对齐后**残差 0.13°** |
| 电脑端 | Windows 11 + PowerShell 5.1 |

> 版本矩阵以 `sh scripts/a1_bootstrap.sh` 末尾自检输出为准；升级 lerobot 前请先跑 T1~T4。

---

## 8. 已知限制与未验证项

- **T4 异常关未验证**：拔 USB / 拔网线 / host 未启动时脚本的报错友好度还没系统测过
- **全新 clone 的完整安装未跑**：T2 验收时复用了已有 venv（快速路径）；`win_bootstrap.ps1` 从零装 lerobot 的完整路径待验证
- **不含数据集录制/训练/评估**：上游 `record.py` / `replay.py` / `evaluate.py` 已覆盖，本仓只做到遥操作
- **只验证过单相机**：`CAMERA_WRIST` 一个；多相机需自行扩展 `a1_host.py::build_cameras()`
- **不覆盖 Windows 底盘以外的控制端**：macOS / Linux 控制端未实测
- **`uv sync` 后再跑 `a1_slim_venv.sh` 是幂等的**，但每次 `a1_bootstrap.sh` 都会重装再瘦身一次（走本地缓存，不算慢）

---

## 9. 目录结构

```
.
├── README.md
├── LICENSE                    # Apache-2.0
├── .gitattributes             # 锁 *.sh/*.py = LF，*.ps1 = CRLF
├── config/
│   ├── env.example            # 模板；bootstrap 会复制成 config/env（已 gitignore）
│   └── env                    # 本机配置（不入库）
├── scripts/
│   ├── _env.py / _env.ps1     # config/env 读取器（sh/py/ps 共用同一份）
│   ├── a1_bootstrap.sh        # 板端：apt → uv → clone lerobot@commit → sync → 瘦身 → 自检
│   ├── a1_slim_venv.sh        # 板端：CUDA torch → CPU torch，清 nvidia/cuda/triton
│   ├── a1_detect.sh           # 板端：串口 / 相机探测，输出建议配置
│   ├── a1_calibrate.sh/.py    # 板端：follower 校准引导（cameras={} 不依赖相机）
│   ├── a1_host.sh             # 板端：start / stop / status / log / release-torque
│   ├── a1_host.py             # 板端：读 config/env 启动 host（不改上游源码）
│   ├── win_bootstrap.ps1      # 电脑端：环境准备 + COM 口探测 + 自检
│   ├── win_calibrate.ps1      # 电脑端：leader 校准引导
│   ├── teleop.ps1             # 电脑端：遥操作入口（-Keyboard / -Rerun）
│   ├── zero_align.ps1         # 电脑端：零点对齐一条命令
│   ├── teleoperate.py         # 上游衍生：读 config/env + 图像降频（LOG_FPS=5）
│   ├── teleoperate_keyboard_only.py  # 上游衍生：纯键盘 + 三层滤波
│   ├── align_leader_to_follower.py   # 零点对齐算法（支持 --dry-run）
│   ├── measure_offset_once.py        # 只读测差（= align --dry-run）
│   └── release_torque.py             # 板端：释放扭矩
└── docs/
    └── troubleshooting.md     # 实测踩坑表（板端 / 连接 / 校准 / 维护）
```

---

## 10. 许可证

Apache-2.0，见 [LICENSE](LICENSE)。lerobot 为 Apache-2.0；硬件设计属于 SIGRobotics-UIUC/LeKiwi。
