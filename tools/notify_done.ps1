# FingerEmpire 工作区：任务完成提示
# 作用：播放双声提示音，并在屏幕右下角弹出置顶提示小窗（3.5 秒自动消失）
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/notify_done.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/notify_done.ps1 -Message "动物贴地 + AI 狩猎改写"
# 说明：Windows 11 已不再显示传统的托盘气球通知（NotifyIcon.ShowBalloonTip），
#       从 PowerShell 进程调用时经常完全看不到，所以这里自己画一个无边框置顶小窗，
#       保证一定能看见。

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
	# 无控制台时忽略
}

# ── 2) 右下角置顶提示小窗 ──
try {
	Add-Type -AssemblyName System.Windows.Forms
	Add-Type -AssemblyName System.Drawing

	$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
	$form = New-Object System.Windows.Forms.Form
	$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
	$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
	$form.Width = 400
	$form.Height = 136
	# 贴着右下角，留 24 像素边距
	$form.Left = $screen.Right - $form.Width - 24
	$form.Top = $screen.Bottom - $form.Height - 24
	$form.BackColor = [System.Drawing.Color]::FromArgb(28, 30, 36)
	$form.TopMost = $true
	$form.ShowInTaskbar = $false
	$form.Opacity = 0.96

	# 顶部一条绿色高亮，像通知条
	$bar = New-Object System.Windows.Forms.Panel
	$bar.Bounds = New-Object System.Drawing.Rectangle(0, 0, $form.Width, 4)
	$bar.BackColor = [System.Drawing.Color]::FromArgb(110, 210, 140)
	$form.Controls.Add($bar)

	$titleLabel = New-Object System.Windows.Forms.Label
	$titleLabel.Text = $Title
	$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 150)
	$titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
	$titleLabel.AutoSize = $false
	$titleLabel.Bounds = New-Object System.Drawing.Rectangle(18, 16, 364, 26)
	$form.Controls.Add($titleLabel)

	$msgLabel = New-Object System.Windows.Forms.Label
	$msgLabel.Text = $Message
	$msgLabel.ForeColor = [System.Drawing.Color]::FromArgb(228, 230, 236)
	$msgLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
	$msgLabel.AutoSize = $false
	$msgLabel.Bounds = New-Object System.Drawing.Rectangle(18, 48, 364, 74)
	$form.Controls.Add($msgLabel)

	# 3.5 秒后自动关闭
	$timer = New-Object System.Windows.Forms.Timer
	$timer.Interval = 3500
	$timer.Add_Tick({ $form.Close() })
	$timer.Start()

	[void]$form.Show()

	# 用 DoEvents 让窗口保持响应（点击也能立即关掉），最多停留 3.6 秒
	$sw = [System.Diagnostics.Stopwatch]::StartNew()
	while ($sw.ElapsedMilliseconds -lt 3600 -and $form.Visible) {
		[System.Windows.Forms.Application]::DoEvents()
		Start-Sleep -Milliseconds 25
	}

	$timer.Stop()
	$form.Close()
	$form.Dispose()
	Write-Host "NOTIFY_OK: $Title - $Message"
} catch {
	Write-Host "NOTIFY_FAIL: $($_.Exception.Message)"
}
