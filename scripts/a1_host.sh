#!/bin/sh
# 板卡端 host 管理。用法：
#   sh scripts/a1_host.sh start           后台启动并等待就绪
#   sh scripts/a1_host.sh stop            停止（强杀，扭矩保持）
#   sh scripts/a1_host.sh status          进程 + 日志尾部
#   sh scripts/a1_host.sh log             tail -f 日志
#   sh scripts/a1_host.sh run             前台运行（调试用）
#   sh scripts/a1_host.sh release-torque  释放扭矩（需先 stop）
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO_DIR/config/env"
LEROBOT_DIR=${LEROBOT_DIR:-$HOME/lerobot}
PY="$LEROBOT_DIR/.venv/bin/python"
LOG=${HOST_LOG:-$HOME/host.log}
PIDFILE=${HOST_PIDFILE:-$HOME/host.pid}
WAIT_S=${HOST_WAIT_S:-60}

# 用正则 [t] 规避 pkill/pgrep 匹配到自身命令行（这条踩过坑）
PAT='a1_hos[t]\.py'

ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m[!]\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m[x]\033[0m %s\n' "$1"; exit 1; }

running() { pgrep -f "$PAT" >/dev/null 2>&1; }

case "${1:-}" in
start)
    [ -x "$PY" ] || die "没找到 $PY，先跑 sh scripts/a1_bootstrap.sh"
    if running; then
        warn "host 已在运行（pid $(pgrep -f "$PAT" | tr '\n' ' ')），先 stop"
        exit 1
    fi
    : >"$LOG"
    cd "$LEROBOT_DIR"
    nohup "$PY" "$REPO_DIR/scripts/a1_host.py" >>"$LOG" 2>&1 &
    echo $! >"$PIDFILE"
    printf '  启动中（pid %s），等待就绪...\n' "$(cat "$PIDFILE")"

    i=0
    while [ "$i" -lt "$((WAIT_S * 2))" ]; do
        if grep -q 'Waiting for commands' "$LOG" 2>/dev/null; then
            ok "host 就绪: Waiting for commands..."
            grep -q 'Address already in use' "$LOG" 2>/dev/null && die "端口被占用，检查是否有残留 host"
            printf '  日志: %s\n' "$LOG"
            exit 0
        fi
        if ! running; then
            printf '\n\033[31m[x]\033[0m host 启动失败，日志尾部：\n'
            tail -n 30 "$LOG" 2>/dev/null
            exit 1
        fi
        sleep 0.5
        i=$((i + 1))
    done
    warn "等待 ${WAIT_S}s 仍未看到 'Waiting for commands'，请查看日志"
    tail -n 30 "$LOG" 2>/dev/null
    exit 1
    ;;

stop)
    if running; then
        pkill -f "$PAT" || true
        sleep 1
        running && pkill -9 -f "$PAT" || true
        ok "host 已停止"
    else
        printf '  host 未运行\n'
    fi
    warn "强杀不走 disconnect()，机械臂扭矩仍然保持"
    warn "要手动摆臂请执行: sh scripts/a1_host.sh release-torque"
    ;;

status)
    if running; then
        ok "运行中: $(pgrep -f "$PAT" | tr '\n' ' ')"
    else
        printf '  未运行\n'
    fi
    if [ -f "$LOG" ]; then
        printf '\n  日志尾部（%s）：\n' "$LOG"
        tail -n 15 "$LOG"
    fi
    ;;

log)
    exec tail -f "$LOG"
    ;;

run)
    [ -x "$PY" ] || die "没找到 $PY，先跑 sh scripts/a1_bootstrap.sh"
    cd "$LEROBOT_DIR"
    exec "$PY" "$REPO_DIR/scripts/a1_host.py"
    ;;

release-torque)
    if running; then
        die "host 还在运行，先 sh scripts/a1_host.sh stop"
    fi
    cd "$LEROBOT_DIR"
    "$PY" "$REPO_DIR/scripts/release_torque.py"
    ;;

*)
    cat <<EOF
用法: sh scripts/a1_host.sh <命令>

  start           后台启动并等待就绪
  stop            停止（扭矩保持）
  status          进程 + 日志尾部
  log             tail -f 日志
  run             前台运行（调试）
  release-torque  释放扭矩（需先 stop）
EOF
    exit 2
    ;;
esac
