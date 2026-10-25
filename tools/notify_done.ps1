# FingerEmpire 工作区：任务完成提示
# 作用：播放双声提示音，并弹出 Windows 通知（托盘气泡 / 通知中心）
# 用法：
#   powershell -NoProfile -File tools/notify_done.ps1
#   powershell -NoProfile -File tools/notify_done.ps1 -Message "动物贴地 + AI 狩猎改写"
# 说明：ShowBalloonTip 需要进程存活到气泡显示完毕，所以脚本会等待约 4 秒后退出。

param(
	[string]$Title = 'FingerEmpire 任务完成',
	[string]$Message = '本次改动已完成并提交'
)

$ErrorActionPreference = 'Continue'

# ── 1) 提示音（两声上扬，约 0.3 秒）──
try {
	[console]::beep(880, 140)
	[console]::beep(1245, 180)
} catch {
	# 无控制台（比如被 GUI 调用）时忽略
}

# ── 2) Windows 通知 ──
try {
	Add-Type -AssemblyName System.Windows.Forms
	Add-Type -AssemblyName System.Drawing
	$notify = New-Object System.Windows.Forms.NotifyIcon
	$notify.Icon = [System.Drawing.SystemIcons]::Information
	$notify.Visible = $true
	$notify.BalloonTipTitle = $Title
	$notify.BalloonTipText = $Message
	$notify.ShowBalloonTip(4000)
	# 气泡需要进程存活才会真正显示出来
	Start-Sleep -Milliseconds 4200
	$notify.Dispose()
	Write-Host "NOTIFY_OK: $Title - $Message"
} catch {
	Write-Host "NOTIFY_FAIL: $($_.Exception.Message)"
}
