param(
	[string]$Godot = "godot",
	[string]$Output = "build/web/FingerEmpire.html",
	[string]$SiteUrl = "",
	[string]$WindowsUrl = "",
	[string]$AndroidUrl = "",
	[string]$WebUrl = "",
	[string]$Notes = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$outPath = Join-Path $root $Output
$outDir = Split-Path -Parent $outPath
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
# Keep generated exports out of Godot's resource scan; otherwise the next
# export can spend minutes scanning its own output.
Set-Content -Path (Join-Path $root "build/.gdignore") -Value "" -NoNewline

Write-Host "Exporting Web build with: $Godot"
$exportArgs = @("--headless", "--path", $root, "--export-release", "Web", $outPath)
$proc = Start-Process -FilePath $Godot -ArgumentList $exportArgs -Wait -NoNewWindow -PassThru
if (-not (Test-Path -LiteralPath $outPath)) {
	throw "Web export failed: $outPath was not created (exit code $($proc.ExitCode))"
}

Get-ChildItem $outDir -File -Include *.import,*.tmp -ErrorAction SilentlyContinue | Remove-Item -Force
# Static hosts (Netlify Drop/GitHub Pages) expect the entry page at /index.html.
Copy-Item -LiteralPath $outPath -Destination (Join-Path $outDir "index.html") -Force
# Font licenses must travel with the Web build.
$fontLicense = Join-Path $root "resources/fonts/OFL.txt"
if (Test-Path -LiteralPath $fontLicense) {
	Copy-Item -LiteralPath $fontLicense -Destination (Join-Path $outDir "FONT-LICENSE.txt") -Force
}
# Netlify should revalidate the fixed-name PCK/WASM files after each deploy.
$cacheHeaders = "/*`n  Cache-Control: public, max-age=0, must-revalidate`n"
Set-Content -LiteralPath (Join-Path $outDir "_headers") -Value $cacheHeaders -Encoding ASCII

# ---------- 生成自动更新清单 update.json ----------
$version = "v0.0.0"
$releaseDate = (Get-Date -Format "yyyy-MM-dd")
$appVersionPath = Join-Path $root "scripts/core/AppVersion.gd"
if (Test-Path -LiteralPath $appVersionPath) {
	$appText = [System.IO.File]::ReadAllText($appVersionPath, [System.Text.Encoding]::UTF8)
	if ($appText -match 'const VERSION: String = "([^"]*)"') { $version = $matches[1].Trim() }
	if ($appText -match 'const RELEASE_DATE: String = "([^"]*)"') { $releaseDate = $matches[1].Trim() }
}

if ($SiteUrl -eq "") {
	$updateConfigPath = Join-Path $root "scripts/core/UpdateConfig.gd"
	if (Test-Path -LiteralPath $updateConfigPath) {
		$updateText = [System.IO.File]::ReadAllText($updateConfigPath, [System.Text.Encoding]::UTF8)
		if ($updateText -match 'const SITE_URL: String = "([^"]*)"') { $SiteUrl = $matches[1] }
	}
}
$SiteUrl = $SiteUrl.Trim().TrimEnd('/')
if ($SiteUrl -like '*YOUR-SITE*') { $SiteUrl = "" }

# 安装包默认放 GitHub Releases；仓库地址从 origin 自动推导。
$releaseBase = ""
$remote = (git remote get-url origin 2>$null | Out-String).Trim()
if ($remote -match 'github\.com[:/]([^/]+)/(.+?)(?:\.git)?$') {
	$owner = $matches[1]
	$repo = $matches[2] -replace '\.git$', ''
	$releaseBase = "https://github.com/$owner/$repo/releases/latest/download"
}
if ($WindowsUrl -eq "" -and $releaseBase -ne "") {
	$WindowsUrl = "$releaseBase/FingerEmpire-win.zip"
}
if ($AndroidUrl -eq "" -and $releaseBase -ne "") {
	$AndroidUrl = "$releaseBase/FingerEmpire.apk"
}
if ($WebUrl -eq "") {
	$WebUrl = if ($SiteUrl -ne "") { "$SiteUrl/" } else { "/" }
}
if ($Notes -eq "") {
	$Notes = "FingerEmpire $version 已发布，详情见游戏内更新日志。"
}
$defaultUrl = if ($SiteUrl -ne "") { "$SiteUrl/" } else { $WebUrl }

$manifest = [ordered]@{
	version = $version
	date = $releaseDate
	notes = $Notes
	downloads = [ordered]@{
		windows = $WindowsUrl
		android = $AndroidUrl
		web = $WebUrl
		default = $defaultUrl
	}
}
$manifestPath = Join-Path $outDir "update.json"
$manifestText = $manifest | ConvertTo-Json -Depth 5
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, $manifestText, $utf8NoBom)

$total = (Get-ChildItem $outDir -File | Measure-Object Length -Sum).Sum
Write-Host ("Web build ready: {0} ({1:N1} MB)" -f $outDir, ($total / 1MB))
Write-Host ("Update manifest: version={0}, site={1}" -f $version, $(if ($SiteUrl -ne "") { $SiteUrl } else { "(web same-origin)" }))
Write-Host "Run: node tools/serve_web.mjs build/web 8090"
