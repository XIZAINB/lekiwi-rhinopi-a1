#!/bin/sh
# 板端瘦身：把 CUDA 版 torch 换成 CPU 版，并清掉 nvidia / cuda / triton。
#
# 为什么需要：
#   lerobot 的 pyproject 把 linux 的 torch 指向 pytorch CUDA 索引，uv sync 会额外拉
#   ~3.4 GB 的 CUDA 依赖（cudnn 626MB、nccl 283MB…）。A1 没有 NVIDIA GPU，纯浪费。
#   而 CUDA 版 torch 删掉这些库后连 import 都会失败（libcudart.so.13 not found），
#   所以不能只删，必须换成 CPU 版 wheel。
#
# 实测：venv 4.7 GB → 848 MB，torch 2.8.0+cpu，lerobot host 正常工作。
#
# 用法：
#   sh scripts/a1_slim_venv.sh            # 换 CPU torch + 清理
#   KEEP_CUDA=1 sh scripts/a1_slim_venv.sh   # 跳过（保留 CUDA 版）
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$REPO_DIR/config/env" ] && . "$REPO_DIR/config/env"

LEROBOT_DIR=${LEROBOT_DIR:-$HOME/lerobot}
VENV="$LEROBOT_DIR/.venv"
SP="$VENV/lib/python3.12/site-packages"
TORCH_VER=${TORCH_CPU_VERSION:-2.8.0}
TV_VER=${TORCHVISION_CPU_VERSION:-0.23.0}

ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m[!]\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m[x]\033[0m %s\n' "$1"; exit 1; }

if [ "${KEEP_CUDA:-0}" = "1" ]; then
    warn "KEEP_CUDA=1，跳过瘦身"
    exit 0
fi

[ -x "$VENV/bin/python" ] || die "没找到 $VENV，先跑 scripts/a1_bootstrap.sh"
command -v uv >/dev/null 2>&1 || export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null 2>&1 || die "uv 不在 PATH"

before=$(du -sm "$VENV" 2>/dev/null | cut -f1)
printf '  当前体积: %s MB\n' "$before"

printf '  安装 CPU 版 torch %s / torchvision %s ...\n' "$TORCH_VER" "$TV_VER"
# --no-deps：避免 uv 顺着 torch 的元数据又把 nvidia-* 拉回来
uv pip install --python "$VENV/bin/python" --reinstall --no-deps \
    --index-url https://pypi.org/simple \
    "torch==$TORCH_VER" "torchvision==$TV_VER" >/dev/null 2>&1 \
    || die "CPU torch 安装失败（网络？版本号？）"

names=$(ls -d "$SP"/nvidia_*.dist-info "$SP"/cuda_*.dist-info "$SP"/triton-*.dist-info 2>/dev/null \
    | sed 's|.*/||; s|\.dist-info$||; s|-[0-9].*$||' | tr '_' '-' | sort -u)
if [ -n "$names" ]; then
    # shellcheck disable=SC2086
    uv pip uninstall --python "$VENV/bin/python" $names >/dev/null 2>&1 || true
    ok "已移除 CUDA / triton 包"
else
    ok "没有 CUDA 残留"
fi

after=$(du -sm "$VENV" 2>/dev/null | cut -f1)
ok "体积: ${before} MB → ${after} MB"

printf '  验证 torch ...\n'
"$VENV/bin/python" - <<'PY' || die "torch 验证失败"
import torch, torchvision
print(f"  torch {torch.__version__} | cuda: {torch.cuda.is_available()}")
PY

"$VENV/bin/python" -c "import lerobot.robots.lekiwi.lekiwi_host" || die "lerobot host 导入失败"
ok "lerobot host 可导入"
