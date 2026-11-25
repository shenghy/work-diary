# 极简工作日记启动器
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  极简工作日记 - 启动中..." -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 检查Python
$pythonPath = "C:\Users\Administrator\AppData\Local\Programs\Python\Python313\python.exe"
Write-Host "[检查] Python路径..."
if (Test-Path $pythonPath) {
    Write-Host "[OK] Python 已找到" -ForegroundColor Green
} else {
    Write-Host "[错误] 未找到 Python，请检查路径" -ForegroundColor Red
    Read-Host "按回车键退出"
    exit 1
}
Write-Host ""

# 1. 启动邮件验证码服务
Write-Host "[1/2] 启动邮件服务..."
Start-Process -FilePath $pythonPath -ArgumentList "E:\Code\WorkDiary\email_server.py" -WindowStyle Minimized
Write-Host "      邮件服务已启动（最小化窗口）"
Write-Host ""

# 等待服务启动
Write-Host "[等待] 等待邮件服务就绪（3秒）..."
Start-Sleep -Seconds 3
Write-Host ""

# 检查邮件服务端口
Write-Host "[检查] 邮件服务端口 5000..."
$portCheck = Get-NetTCPConnection -LocalPort 5000 -ErrorAction SilentlyContinue
if ($portCheck) {
    Write-Host "[OK] 邮件服务运行正常" -ForegroundColor Green
} else {
    Write-Host "[警告] 未检测到 5000 端口，邮件服务可能启动失败" -ForegroundColor Yellow
}
Write-Host ""

# 2. 启动应用
Write-Host "[2/2] 启动极简工作日记..."
$appPath = "E:\Code\WorkDiary\work_diary_app\build\windows\x64\runner\Debug\work_diary_app.exe"
if (Test-Path $appPath) {
    Start-Process -FilePath $appPath
    Write-Host "[OK] 应用已启动" -ForegroundColor Green
} else {
    Write-Host "[错误] 未找到应用程序，请先编译" -ForegroundColor Red
    Read-Host "按回车键退出"
    exit 1
}
Write-Host ""

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  启动完成！" -ForegroundColor Green
Write-Host "  提示：邮件服务窗口请勿关闭" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "按回车键关闭窗口"
