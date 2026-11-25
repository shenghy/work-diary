# 极简工作日记 - 后端服务 Windows 启动脚本
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if (-not (Test-Path ".venv\Scripts\python.exe")) {
    Write-Host "[start] 创建虚拟环境..."
    py -3 -m venv .venv
}
& ".venv\Scripts\python.exe" -m pip install -q -r requirements.txt

$port = if ($env:PORT) { $env:PORT } else { "8000" }
Write-Host "[start] 启动服务 http://0.0.0.0:${port}  (后台 /admin, 文档 /docs)"
& ".venv\Scripts\uvicorn.exe" app.main:app --host 0.0.0.0 --port $port
