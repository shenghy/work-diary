#!/usr/bin/env bash
# 极简工作日记 - 后端服务 Linux 启动脚本（后台运行，用 stop.sh 停止）
set -e
cd "$(dirname "$0")"

PORT="${PORT:-8010}"
PID_FILE=".server.pid"
LOG_FILE="server.log"

# 已在运行则直接提示退出，避免重复启动
if [ -f "$PID_FILE" ]; then
  OLD_PID="$(cat "$PID_FILE")"
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[start] 服务已在运行 (PID $OLD_PID, http://0.0.0.0:${PORT})"
    echo "[start] 如需重启：先 ./stop.sh，再 ./start.sh"
    exit 0
  else
    echo "[start] 发现残留 PID 文件（进程已不存在），自动清理后重新启动"
    rm -f "$PID_FILE"
  fi
fi

# 首次运行：创建虚拟环境
if [ ! -x ".venv/bin/uvicorn" ]; then
  echo "[start] 首次运行，创建虚拟环境..."
  python3 -m venv .venv
fi

# 每次启动都检查并补装依赖（已装的包会秒过，避免依赖缺失导致起不来）
echo "[start] 检查并安装依赖..."
.venv/bin/pip install -q -r requirements.txt

echo "[start] 后台启动服务 http://0.0.0.0:${PORT}  (管理后台 /admin, 文档 /docs)"
nohup "$(pwd)/.venv/bin/uvicorn" app.main:app --host 0.0.0.0 --port "$PORT" >> "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"

# 等待 2 秒确认进程存活
sleep 2
if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "[start] 启动成功 (PID $(cat "$PID_FILE"), 日志: $LOG_FILE)"
else
  echo "[start] 启动失败，请查看日志: $LOG_FILE"
  rm -f "$PID_FILE"
  exit 1
fi
