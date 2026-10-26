param(
	[string]$Destination = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if ($Destination -eq "") {
	$Destination = Join-Path $root "cloudflared.exe"
}
$url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"

if (Test-Path -LiteralPath $Destination) {
	Write-Host "已存在：$Destination"
	exit 0
}

Write-Host "下载 Cloudflare Tunnel 客户端（约 53 MB）..." -ForegroundColor Cyan
Write-Host "URL: $url"
$tmp = "$Destination.download"
if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
try {
	Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 600
} catch {
	if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
	throw "下载失败：$($_.Exception.Message)"
}
Move-Item -LiteralPath $tmp -Destination $Destination -Force
Write-Host "已保存：$Destination" -ForegroundColor Green
Write-Host "编辑器运行时把它放在项目根目录即可；发布 zip 时会被自动带进 Windows 包。"
