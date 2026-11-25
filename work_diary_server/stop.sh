#!/usr/bin/env bash
# 极简工作日记 - 后端服务 Linux 停止脚本（与 start.sh 配套）
set -e
cd "$(dirname "$0")"

PID_FILE=".server.pid"
UVICORN_CMD="$(pwd)/.venv/bin/uvicorn app.main:app"

stopped=0

# 方式 1：按 PID 文件停止（start.sh 正常启动的场景）
if [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE")"
  if kill -0 "$PID" 2>/dev/null; then
    echo "[stop] 停止服务 (PID $PID)..."
    kill "$PID"
    # 最多等 5 秒，仍未退出则强制结束
    for i in 1 2 3 4 5; do
      kill -0 "$PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$PID" 2>/dev/null; then
      kill -9 "$PID" 2>/dev/null || true
      echo "[stop] 进程未在 5 秒内退出，已强制结束"
    fi
    echo "[stop] 服务已停止"
    stopped=1
  else
    echo "[stop] PID 文件存在但进程已不在，清理残留文件"
  fi
  rm -f "$PID_FILE"
fi

# 方式 2：兜底按绝对路径进程名停止（PID 文件丢失等异常场景）
PIDS="$(pgrep -f "$UVICORN_CMD" || true)"
if [ -n "$PIDS" ]; then
  echo "[stop] 按进程名找到服务进程: $PIDS"
  kill $PIDS 2>/dev/null || true
  echo "[stop] 服务已停止"
  stopped=1
fi

if [ "$stopped" = "0" ]; then
  echo "[stop] 服务本来就没有在运行"
fi
