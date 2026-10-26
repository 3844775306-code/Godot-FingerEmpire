param(
	[string]$Godot = "godot",
	[switch]$SkipBuild,
	[string]$SiteId = "",
	[string]$AuthToken = "",
	[string]$Message = "",
	[switch]$DryRun
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if ($SiteId -eq "" -and $env:NETLIFY_SITE_ID) {
	$SiteId = $env:NETLIFY_SITE_ID
}

function Invoke-Netlify {
	param(
		[string[]]$Arguments,
		[switch]$AllowFailure
	)
	$netlify = Get-Command netlify -ErrorAction SilentlyContinue
	if ($netlify) {
		& $netlify.Source @Arguments
	} else {
		$npx = Get-Command npx -ErrorAction SilentlyContinue
		if (-not $npx) {
			throw "找不到 Netlify CLI，也找不到 npx。请先安装 Node.js，或执行：npm install -g netlify-cli"
		}
		& $npx.Source --yes netlify-cli @Arguments
	}
	if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
		throw "Netlify CLI 失败，退出码 $LASTEXITCODE"
	}
}

$authArgs = @()
if ($AuthToken -ne "") {
	$authArgs = @("--auth", $AuthToken)
} elseif ($env:NETLIFY_AUTH_TOKEN) {
	$authArgs = @("--auth", $env:NETLIFY_AUTH_TOKEN)
}

# 先确认登录/站点关联，避免构建完才失败。
$statusArgs = @("status", "--json") + $authArgs
$statusRaw = Invoke-Netlify -Arguments $statusArgs -AllowFailure
$status = $null
try {
	$status = ($statusRaw | Out-String) | ConvertFrom-Json
} catch {
	$status = $null
}
if ($null -eq $status -or -not $status.loggedIn) {
	Write-Host ""
	Write-Host "还没有登录 Netlify。首次使用请执行：" -ForegroundColor Yellow
	Write-Host "  npx netlify-cli login"
	Write-Host "  npx netlify-cli link"
	Write-Host ""
	Write-Host "如果使用 CI，请设置 NETLIFY_AUTH_TOKEN 和 -SiteId（或 NETLIFY_SITE_ID）。"
	exit 2
}
if ($SiteId -eq "" -and -not $status.linked) {
	Write-Host ""
	Write-Host "Netlify 账号已登录，但当前项目还没有关联站点。首次使用请执行：" -ForegroundColor Yellow
	Write-Host "  npx netlify-cli link"
	Write-Host "或给脚本传入 -SiteId <站点ID>。"
	exit 2
}

if (-not $SkipBuild) {
	Write-Host "==> 构建 Web 版" -ForegroundColor Cyan
	& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "build_web.ps1") -Godot $Godot
	if ($LASTEXITCODE -ne 0) {
		throw "Web 构建失败，退出码 $LASTEXITCODE"
	}
}

$indexPath = Join-Path $root "build/web/index.html"
if (-not (Test-Path -LiteralPath $indexPath)) {
	throw "找不到 build/web/index.html，请先完成一次 Web 构建"
}

if ($Message -eq "") {
	$Message = "Web deploy " + (Get-Date -Format "yyyy-MM-dd HH:mm")
}

$deployArgs = @("deploy", "--prod", "--no-build", "--dir", "build/web", "--message", $Message) + $authArgs
if ($SiteId -ne "") {
	$deployArgs += @("--site", $SiteId)
}

Write-Host "==> 部署到 Netlify" -ForegroundColor Cyan
Write-Host "    deploy --prod --no-build --dir build/web --message `"$Message`""
if ($DryRun) {
	Write-Host "DryRun：不执行实际部署。" -ForegroundColor Yellow
	exit 0
}
Invoke-Netlify $deployArgs
Write-Host ""
Write-Host "部署完成。Netlify 会自动更新线上地址。" -ForegroundColor Green
