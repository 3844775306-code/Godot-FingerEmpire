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

# Steam 版不能只发 exe + pck：GodotSteam / Steam Sockets 需要随包携带运行库。
# 这些文件由 Godot 导出 Windows 版本时生成到项目根目录，必须一起打进 zip。
$steamFiles = @(
	"steam_api64.dll",
	"libgodotsteam.windows.template_release.x86_64.dll",
	"steam-multiplayer-peer.windows.template_release.x86_64.dll"
)
foreach ($name in $steamFiles) {
	$path = Join-Path $root $name
	if (-not (Test-Path -LiteralPath $path)) {
		throw "缺少 Steam 运行库：$path。请先用 Godot 导出 Windows 版本，再运行发布脚本。"
	}
	$winFiles += $path
}
$steamAppId = Join-Path $root "steam_appid.txt"
if (Test-Path -LiteralPath $steamAppId) {
	$winFiles += $steamAppId
} else {
	Write-Warning "未找到 steam_appid.txt；从 Steam 客户端启动仍可运行，但独立启动可能无法初始化 Steam。"
}
if (Test-Path -LiteralPath $pck) {
	$winFiles += $pck
}

if (-not $DryRun) {
	if (Test-Path -LiteralPath $zip) {
		Remove-Item -LiteralPath $zip -Force
	}
	Write-Host "打包 Windows 版（含 Steam 运行库）..." -ForegroundColor Cyan
	Compress-Archive -Path $winFiles -DestinationPath $zip -CompressionLevel Optimal

	# 校验 zip 根目录确实带上了运行库，避免再次发出只能单机的 exe。
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	$archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
	try {
		$zipNames = @($archive.Entries | ForEach-Object { $_.FullName })
	} finally {
		$archive.Dispose()
	}
	$requiredWinFiles = @(
		"FingerEmpire.exe",
		"FingerEmpire.pck",
		"steam_api64.dll",
		"libgodotsteam.windows.template_release.x86_64.dll",
		"steam-multiplayer-peer.windows.template_release.x86_64.dll"
	)
	$missingWinFiles = @($requiredWinFiles | Where-Object { $zipNames -notcontains $_ })
	if ($missingWinFiles.Count -gt 0) {
		throw "Windows 包缺少文件：$($missingWinFiles -join ', ')"
	}
	Write-Host ("Windows 包内容：{0}" -f ([string]::Join(", ", @($winFiles | ForEach-Object { Split-Path -Leaf $_ })))) -ForegroundColor DarkGray
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

$releaseTagsRaw = & $gh.Source release list --limit 100 --json tagName 2>$null
$releaseExists = $false
try {
	$releaseTags = @(($releaseTagsRaw | Out-String) | ConvertFrom-Json)
	$releaseExists = @($releaseTags | Where-Object { $_.tagName -eq $version }).Count -gt 0
} catch {
	$releaseExists = $false
}
if (-not $releaseExists) {
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
Write-Host "Release 地址：https://github.com/3844775306-code/Godot-FingerEmpire/releases/tag/$version"
Write-Host "如果版本号或下载链接有变化，再运行 tools/deploy_web.ps1 重新生成 update.json。"
