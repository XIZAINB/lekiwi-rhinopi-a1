# 排障表（实机踩过的坑）

> 排障顺序建议：先 `a1_host.sh status` 看板端日志，再 `teleop.ps1` 的连接报错，最后才怀疑硬件。

## 一、板端 host

| 现象 | 原因 / 解决 |
| --- | --- |
| `EOFError: EOF when reading a line` | 后台启动时缺 stdin，上游 `connect()` 会 `input()` 问是否复用校准文件。本仓库的 `a1_host.py` 已自动处理（非 tty 时回空回车）；若你绕过它直接跑 `python -m ...lekiwi_host`，需自己 `echo \|` 喂一行 |
| `未找到 follower 校准文件` | 先跑 `sh scripts/a1_calibrate.sh`。校准是每台机器的独有数据，不会随仓库分发 |
| `Failed to open OpenCVCamera(...)` | 采集节点不是 `video0`。跑 `sh scripts/a1_detect.sh`，用 `/dev/v4l/by-id/` 别名回填 `CAMERA_WRIST`；只想先跑底盘就把 `CAMERA_WRIST` 留空 |
| 相机"能打开但读不到帧" | 板载 ISP / 管理节点（`cam-req-mgr`、`cam_sync` 之类）占了 `video0/video1`，换到 USB 相机对应节点 |
| `Address already in use` | 5555/5556 被占用：`sh scripts/a1_host.sh stop` 再起 |
| host 起来 30 秒后自己退出 | `CONNECTION_TIME_S` 没放大（上游默认 30 秒无客户端就退出），确保 `config/env` 里是 3600 |
| SSH 执行 `pkill -f lekiwi_host` 后连接被断 | 模式匹配到了 ssh 自己的命令行。用正则 `pkill -f 'lekiwi_hos[t]'`（本仓库脚本已内置） |
| `pkill` 后机械臂推不动 | 强杀不走 `disconnect()`，扭矩没释放。跑 `sh scripts/a1_host.sh stop` 再 `release-torque` |
| `uv sync` 在 ARM 上失败 | 多为 OpenCV 轮子缺失。先看报错是哪个包；可尝试 `uv sync --locked --extra lekiwi --no-build-isolation`，或改用发行版 `python3-opencv` |
| `uv sync` 下了 3 GB 的 nvidia/cudnn | lerobot 的 pyproject 把 linux 的 torch 指向 CUDA 索引。跑 `sh scripts/a1_slim_venv.sh`（bootstrap 已默认执行），venv 从 4.7 GB 降到 848 MB |
| 删了 nvidia 包后 `import torch` 报 `libcudart.so.13: cannot open shared object file` | CUDA 版 torch 的库被删了。**不能只删**，必须换成 CPU 版：`sh scripts/a1_slim_venv.sh` |
| `a1_host.sh start` 报“未就绪”但日志已有 `No command available` | 旧版本拿 `Waiting for commands` 当唯一判据，而它是 `logging.info`、默认不输出。现改为「端口 5555 监听优先」，并已把日志级别改为 INFO |
| `uv: command not found` | `~/.local/bin` 不在 PATH：`export PATH="$HOME/.local/bin:$PATH"` |
| `No module named 'lerobot'` | 在仓库目录外跑了 python。用 `.venv/bin/python` 或先 `cd` 到 lerobot 目录（本仓库脚本已处理） |

## 二、电脑端连接

| 现象 | 原因 / 解决 |
| --- | --- |
| `Timeout waiting for LeKiwi Host to connect expired.` | host 没起 / IP 变了 / 不同网段 / 路由器开了 AP 隔离。先 `Test-NetConnection <IP> -Port 5555` |
| `could not open port 'COM11'` | 串口号变了或被串口助手占用。`win_bootstrap.ps1 -DetectOnly` 重新确认 |
| `uv run lerobot-calibrate` 报 `Failed to spawn` | 用模块方式 `uv run python -m lerobot.scripts.lerobot_calibrate ...`（本仓库脚本已用模块方式） |
| `uv run python` 退化成 conda 的 python | 在仓库目录外执行。用 `uv run --project <lerobot目录>` 或先 `cd` |
| 键盘按键没反应 | 点一下运行脚本的终端窗口获得焦点 |
| `Exceeded gRPC proxy server memory limit (1.0 GiB)` | rerun 图像日志过密。本仓库已把图像记录降到 5 FPS，可忽略 |
| 连一会儿就断 | Wi-Fi 不稳。两台设备尽量靠近同一路由，或改用有线 |

## 三、校准与零点对齐

| 现象 | 原因 / 解决 |
| --- | --- |
| `Some motors have the same min and max values` | 记录阶段被立即中断：多半是用脚本代按了回车（残留换行）。手按回车重来 |
| 校准后行程明显不对 | 某个关节只推了一个方向。每个关节都要两个方向都推到硬限位 |
| 零点整体偏移几十度 | 中间位姿没"先推到两端再回中"，记录不对称 |
| 拖 leader，follower 整体差一个固定角度 | 两侧参考位姿不一致 → 跑 `zero_align.ps1`。DEGREES 模式下 `角度=(raw-mid)*360/4095`，mid 不一致就是恒定偏移 |
| 对齐后残差仍 > 1° | 两臂姿势没摆齐（尤其 `wrist_flex`）。松扭矩后重新摆，再跑一次 |
| leader 部分舵机无响应（`missing ids: [1, 6]`） | 底座 / 夹爪那两根 3-pin 线没插到位。飞特总线两个接口并联，单个舵机不通信不会掐断下游，所以表现为"中间好、两头坏" |
| 任意一侧重新校准后出现固定偏差 | 必须重跑 `zero_align.ps1` |

## 四、维护本仓库时的注意事项

| 现象 | 原因 / 解决 |
| --- | --- |
| 改过 `.ps1` 后 PowerShell 报"字符串缺少终止符"/中文乱码 | PS 5.1 会按 ANSI 读**无 BOM 的 UTF-8** 脚本。`.ps1` 必须保存为 **UTF-8 with BOM** |
| shell 里 `. config/env` 报错或首个键名异常 | `config/env` 必须保存为 **UTF-8 无 BOM**（有 BOM 时首行会带上不可见字符） |
| 两端跑起来行为不一致 | 检查两端 `LEROBOT_COMMIT` 是否同一个值；升级时两端一起改 |
| 相机 / 串口号在别人机器上不同 | 这是设计预期：一切机器相关值都该在 `config/env`，不允许写进脚本 |
