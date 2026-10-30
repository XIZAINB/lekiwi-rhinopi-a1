#!/bin/sh
# 板卡端环境准备（犀牛派 A1 / AidLux / Debian 系）。可重复执行，幂等。
# 用法： sh scripts/a1_bootstrap.sh
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR"

ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m[!]\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m[x]\033[0m %s\n' "$1"; exit 1; }
step() { printf '\n\033[36m== %s ==\033[0m\n' "$1"; }

# ---------------------------------------------------------------- 1. 系统信息
step "1/7 系统信息"
printf '  架构: %s\n' "$(uname -m)"
printf '  内核: %s\n' "$(uname -r)"
if command -v lsb_release >/dev/null 2>&1; then
    printf '  发行版: %s\n' "$(lsb_release -ds 2>/dev/null || echo unknown)"
else
    printf '  发行版: %s\n' "$(cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME' | cut -d= -f2- || echo unknown)"
fi
printf '  用户: %s\n' "$(id -un)"

case "$(uname -m)" in
    aarch64|arm64) ok "ARM64" ;;
    *) warn "非 ARM64（$(uname -m)）—— 本文档按 A1/ARM64 验证过，其他架构可能需自行调整依赖" ;;
esac

# ---------------------------------------------------------------- 2. 配置文件
step "2/7 配置文件"
if [ ! -f "$REPO_DIR/config/env" ]; then
    cp "$REPO_DIR/config/env.example" "$REPO_DIR/config/env"
    warn "已生成 config/env（来自 env.example），请稍后按需修改：$REPO_DIR/config/env"
else
    ok "config/env 已存在，保持不变"
fi
# shellcheck disable=SC1091
. "$REPO_DIR/config/env"

LEROBOT_DIR=${LEROBOT_DIR:-$HOME/lerobot}
LEROBOT_COMMIT=${LEROBOT_COMMIT:-53feaef}
ROBOT_ID=${ROBOT_ID:-my_kiwi}
ROBOT_PORT=${ROBOT_PORT:-/dev/ttyACM0}

# ---------------------------------------------------------------- 3. 系统依赖
step "3/7 系统依赖（git / curl / ca-certificates）"
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        warn "非 root 且没有 sudo，跳过 apt 安装"
    fi
fi

missing=""
command -v git  >/dev/null 2>&1 || missing="$missing git"
command -v curl >/dev/null 2>&1 || missing="$missing curl"
if dpkg -s ca-certificates >/dev/null 2>&1; then :; else missing="$missing ca-certificates"; fi

if [ -n "$missing" ] && [ -n "$SUDO$([ "$(id -u)" -eq 0 ] && echo root)" ]; then
    printf '  安装:%s\n' "$missing"
    if [ "$(id -u)" -eq 0 ]; then
        apt-get update && apt-get install -y $missing
    else
        $SUDO apt-get update && $SUDO apt-get install -y $missing
    fi
    ok "系统依赖就绪"
else
    ok "系统依赖已存在"
fi

# ---------------------------------------------------------------- 4. uv
step "4/7 uv"
if ! command -v uv >/dev/null 2>&1; then
    if [ -x "$HOME/.local/bin/uv" ]; then
        ok "使用已有的 ~/.local/bin/uv"
    else
        printf '  安装 uv ...\n'
        curl -LsSf https://astral.sh/uv/install.sh | sh || die "uv 安装失败（检查网络/代理）"
    fi
    PATH="$HOME/.local/bin:$PATH"
    export PATH
fi
command -v uv >/dev/null 2>&1 || die "uv 不在 PATH 中，请手工 export PATH=\"\$HOME/.local/bin:\$PATH\" 后重跑"
ok "uv $(uv --version)"

# ---------------------------------------------------------------- 5. lerobot
step "5/7 lerobot @ $LEROBOT_COMMIT → $LEROBOT_DIR"
if [ ! -d "$LEROBOT_DIR/.git" ]; then
    mkdir -p "$LEROBOT_DIR"
    git -C "$LEROBOT_DIR" init -q
    git -C "$LEROBOT_DIR" remote add origin https://github.com/huggingface/lerobot.git 2>/dev/null || true
    ok "已初始化空仓库"
fi
if git -C "$LEROBOT_DIR" rev-parse -q --verify HEAD >/dev/null 2>&1 &&
   [ "$(git -C "$LEROBOT_DIR" rev-parse HEAD 2>/dev/null)" = "$(git -C "$LEROBOT_DIR" rev-parse -q --verify "$LEROBOT_COMMIT^{commit}" 2>/dev/null || true)" ]; then
    ok "已在 $LEROBOT_COMMIT"
else
    printf '  拉取 %s ...\n' "$LEROBOT_COMMIT"
    git -C "$LEROBOT_DIR" fetch --depth 1 origin "$LEROBOT_COMMIT" || die "git fetch 失败（检查网络）"
    git -C "$LEROBOT_DIR" checkout -q --detach FETCH_HEAD
    ok "checkout 完成: $(git -C "$LEROBOT_DIR" log -1 --oneline)"
fi

# ---------------------------------------------------------------- 6. 依赖安装
step "6/7 uv sync --locked --extra lekiwi"
( cd "$LEROBOT_DIR" && uv sync --locked --extra lekiwi ) || die "uv sync 失败（ARM 上常见于 OpenCV 轮子缺失，见 docs/troubleshooting.md）"
ok "依赖安装完成"

printf '  验证 import ...\n'
"$LEROBOT_DIR/.venv/bin/python" -c "from lerobot.robots.lekiwi import LeKiwi, LeKiwiClient; print('  import ok')" \
    || die "import 失败，检查 $LEROBOT_DIR/.venv"
ok "lerobot 可导入"

# 瘦身：A1 没有 NVIDIA GPU，CUDA 依赖（~3.4 GB）纯属浪费。
# 跳过设 SLIM_VENV=0（例如以后要在板上有 GPU 的机器上用）。
if [ "${SLIM_VENV:-1}" = "1" ]; then
    printf '\n  瘦身（换 CPU 版 torch，清理 CUDA）...\n'
    sh "$REPO_DIR/scripts/a1_slim_venv.sh" || warn "瘦身失败，不影响使用（venv 会保持 CUDA 版）"
fi

chmod +x "$REPO_DIR"/scripts/*.sh 2>/dev/null || true

# ---------------------------------------------------------------- 7. 自检
step "7/7 自检"
if [ -e "$ROBOT_PORT" ]; then
    ok "舵机总线 $ROBOT_PORT 存在"
else
    warn "未找到 $ROBOT_PORT —— 检查舵机转接板 USB、底盘电池"
fi

CALIB="$HOME/.cache/huggingface/lerobot/calibration/robots/lekiwi/$ROBOT_ID.json"
if [ -f "$CALIB" ]; then
    ok "follower 校准文件存在: $CALIB"
else
    warn "缺少 follower 校准文件: $CALIB"
    warn "  → 下一步跑: sh scripts/a1_calibrate.sh"
fi

if [ -f "$REPO_DIR/config/env" ]; then
    cam=$(grep -E '^CAMERA_WRIST=' "$REPO_DIR/config/env" | cut -d= -f2-)
    case "$cam" in
        ""|*EXAMPLE*) warn "CAMERA_WRIST 未配置（当前: ${cam:-空}）→ 跑 sh scripts/a1_detect.sh 取建议值" ;;
        *) [ -e "$cam" ] && ok "相机节点存在: $cam" || warn "相机节点不存在: $cam" ;;
    esac
fi

if pgrep -f 'a1_hos[t]\.py' >/dev/null 2>&1; then
    ok "host 正在运行"
else
    printf '  host 未运行\n'
fi

# ---------------------------------------------------------------- 下一步
cat <<EOF

$(printf '\033[36m== 下一步 ==\033[0m')
  1) 看设备建议值:   sh scripts/a1_detect.sh
  2) 填 config/env:  ${REPO_DIR}/config/env
  3) 首次校准:       sh scripts/a1_calibrate.sh
  4) 启动 host:      sh scripts/a1_host.sh start
  5) 看状态:         sh scripts/a1_host.sh status

  电脑端连接前确认：hostname -I 得到的 IP 已写入电脑的 config/env 的 BOARD_IP
EOF
