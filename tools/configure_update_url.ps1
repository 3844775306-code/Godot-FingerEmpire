param(
	[Parameter(Mandatory = $true)]
	[string]$SiteUrl,
	[switch]$DryRun
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$url = $SiteUrl.Trim()
while ($url.EndsWith("/")) {
	$url = $url.Substring(0, $url.Length - 1)
}
if ($url -notmatch '^https?://') {
	throw "SiteUrl 必须是 http:// 或 https:// 开头的地址：$url"
}

$configPath = Join-Path $root "scripts/core/UpdateConfig.gd"
if (-not (Test-Path -LiteralPath $configPath)) {
	throw "找不到 $configPath"
}
$text = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
$pattern = 'const SITE_URL: String = "[^"]*"'
if ($text -notmatch $pattern) {
	throw "UpdateConfig.gd 里找不到 SITE_URL 常量"
}
$replacement = 'const SITE_URL: String = "' + $url + '"'
$newText = [regex]::Replace($text, $pattern, $replacement)
if ($newText -ne $text) {
	if ($DryRun) {
		Write-Host "DryRun: 将把 SITE_URL 设为 $url" -ForegroundColor Yellow
	} else {
		$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
		[System.IO.File]::WriteAllText($configPath, $newText, $utf8NoBom)
		Write-Host "已更新 UpdateConfig.SITE_URL = $url" -ForegroundColor Green
	}
} else {
	Write-Host "SITE_URL 已经是 $url，无需修改"
}
