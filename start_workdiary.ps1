# 极简工作日记启动器（后端 API 服务已部署到服务器，本机无需再启动任何服务）
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  极简工作日记 - 启动中..." -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 启动应用（登录/注册/任务/验证码全部走云端 API 服务）
$appPath = "E:\Code\WorkDiary\work_diary_app\build\windows\x64\runner\Debug\work_diary_app.exe"
if (Test-Path $appPath) {
    Start-Process -FilePath $appPath
    Write-Host "[OK] 应用已启动" -ForegroundColor Green
    Write-Host ""
    Write-Host "  API 服务: https://work.jspang.com（云端，登录/注册/任务/验证码）" -ForegroundColor Gray
    Write-Host "  官网: https://work.jspang.com" -ForegroundColor Gray
} else {
    Write-Host "[错误] 未找到应用程序，请先编译：" -ForegroundColor Red
    Write-Host "  cd E:\Code\WorkDiary\work_diary_app"
    Write-Host "  flutter build windows --debug"
    Read-Host "按回车键退出"
    exit 1
}
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  启动完成！" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Start-Sleep -Seconds 2
