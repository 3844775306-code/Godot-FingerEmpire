param(
	[string]$Version = "",
	[string]$Notes = "",
	[switch]$SkipUpload,
	[switch]$DryRun
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$appVersionPath = Join-Path $root "scripts/core/AppVersion.gd"
$version = $Version
if ($version -eq "") {
	$text = Get-Content -LiteralPath $appVersionPath -Raw
	if ($text -match 'const VERSION: String = "([^"]*)"') {
		$version = $matches[1].Trim()
	}
}
if ($version -eq "") {
	throw "无法读取版本号，请用 -Version v1.0.1 指定"
}
if (-not $version.StartsWith("v")) {
	$version = "v" + $version
}

$apk = Join-Path $root "FingerEmpire.apk"
$exe = Join-Path $root "FingerEmpire.exe"
$pck = Join-Path $root "FingerEmpire.pck"
if (-not (Test-Path -LiteralPath $apk)) {
	throw "找不到 Android 安装包：$apk"
}
if (-not (Test-Path -LiteralPath $exe)) {
	throw "找不到 Windows 可执行文件：$exe"
}

$releaseDir = Join-Path $root "build/release"
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
$zip = Join-Path $releaseDir "FingerEmpire-win.zip"
$winFiles = @($exe)
if (Test-Path -LiteralPath $pck) {
	$winFiles += $pck
}

if (-not $DryRun) {
	if (Test-Path -LiteralPath $zip) {
		Remove-Item -LiteralPath $zip -Force
	}
	Write-Host "打包 Windows 版..." -ForegroundColor Cyan
	Compress-Archive -Path $winFiles -DestinationPath $zip -CompressionLevel Optimal
} else {
	Write-Host "DryRun: 将打包 $($winFiles -join ', ') -> $zip"
}

if ($SkipUpload) {
	Write-Host "已跳过上传；安装包在 $releaseDir"
	exit 0
}
if ($DryRun) {
	Write-Host "DryRun: 不执行 gh release create/upload" -ForegroundColor Yellow
	exit 0
}

$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
	throw "找不到 GitHub CLI (gh)。请先安装，或手动把 APK 和 FingerEmpire-win.zip 上传到 GitHub Releases。"
}
& $gh.Source auth status 2>$null
if ($LASTEXITCODE -ne 0) {
	Write-Host ""
	Write-Host "GitHub CLI 还没有登录。请先执行：" -ForegroundColor Yellow
	Write-Host "  gh auth login"
	Write-Host "登录后重新运行本脚本。"
	exit 2
}

if ($Notes -eq "") {
	$Notes = "FingerEmpire $version"
}
& $gh.Source release view $version 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
	Write-Host "创建 GitHub Release $version" -ForegroundColor Cyan
	& $gh.Source release create $version --title "FingerEmpire $version" --notes $Notes
	if ($LASTEXITCODE -ne 0) {
		throw "创建 GitHub Release 失败，退出码 $LASTEXITCODE"
	}
}

Write-Host "上传安装包到 GitHub Release $version..." -ForegroundColor Cyan
& $gh.Source release upload $version $apk $zip --clobber
if ($LASTEXITCODE -ne 0) {
	throw "上传安装包失败，退出码 $LASTEXITCODE"
}
Write-Host "上传完成：$version" -ForegroundColor Green
Write-Host "现在运行 tools/deploy_web.ps1 重新生成 update.json 并发布。"
