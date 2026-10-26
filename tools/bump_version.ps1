# 版本号自动递进工具
#
# 规则（玩家定的）：
#   1. 每累计 10 次提交 +1 个小版本，例如 v1.0.0 → v1.0.1（余数保留到下次）；
#   2. 距「上次版本号发布日」超过 3 天且这期间有提交 → +1 个中版本，小版本归零，
#      例如 v1.0.8 → v1.1.0；
#   3. 大版本只能由玩家口头指定：powershell -File tools/bump_version.ps1 -Major 2
#      （会重置中/小版本为 0，得到 2.0.0）。
#
# 每次任务提交后跑一次（CLAUDE.md 里有约定）。脚本会：
#   - 读 tools/version_state.json 里的计数与上次发布信息；
#   - 用 git 统计上次发布以来的提交数；
#   - 需要升版时改写 scripts/core/AppVersion.gd 的 VERSION / RELEASE_DATE；
#   - 写回状态文件（最后一次计入的提交、剩余的 pending 次数）。
#
# 参数：
#   -DryRun   只打印判断结果，不写任何文件（调试用）
#   -Major N  手动指定大版本，重置中/小版本（如 -Major 2 → 2.0.0）

param(
	[switch]$DryRun,
	[int]$Major = -1
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$stateFile = Join-Path $PSScriptRoot "version_state.json"
$versionScript = Join-Path $root "scripts/core/AppVersion.gd"

if (-not (Test-Path -LiteralPath $stateFile)) {
	throw "缺少状态文件：$stateFile"
}
if (-not (Test-Path -LiteralPath $versionScript)) {
	throw "缺少版本脚本：$versionScript"
}

# 状态文件统一写成无 BOM 的 UTF-8，避免每次运行都产生编码差异
function Save-StateFile($obj) {
	$json = $obj | ConvertTo-Json -Depth 4
	$utf8 = New-Object System.Text.UTF8Encoding($false)
	[System.IO.File]::WriteAllText($stateFile, $json, $utf8)
}

$state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json

$head = (git rev-parse HEAD).Trim()
$fromCommit = [string]$state.last_bump_commit
if ([string]::IsNullOrWhiteSpace($fromCommit)) {
	$fromCommit = $head
}

# 上次发布以来有多少次提交（--count 只数提交数，包含合并提交）
$commitCount = 0
if ($fromCommit -ne $head) {
	$commitCount = [int]((git rev-list --count "$fromCommit..$head")).Trim()
}

# 距上次版本号发布多少天
$today = Get-Date
$lastDate = [datetime]::ParseExact([string]$state.last_bump_date, "yyyy-MM-dd", $null)
$daysSinceRelease = [int]($today.Date - $lastDate.Date).Days

$oldMajor = [int]$state.major
$oldMinor = [int]$state.minor
$oldPatch = [int]$state.patch
$pending = [int]$state.pending

$newMajor = $oldMajor
$newMinor = $oldMinor
$newPatch = $oldPatch
$newPending = $pending
$reason = ""
$changed = $false

if ($Major -ge 0) {
	# 玩家指定的新大版本：中/小版本归零，计数清空
	$newMajor = $Major
	$newMinor = 0
	$newPatch = 0
	$newPending = 0
	$reason = "玩家指定大版本"
	$changed = $true
}
elseif ($daysSinceRelease -ge 3 -and ($commitCount + $pending) -gt 0) {
	# 距上次发布超过 3 天且有未计入的提交 → 中版本 +1
	$newMinor = $oldMinor + 1
	$newPatch = 0
	$newPending = 0
	$reason = "距上次发布 $daysSinceRelease 天，中版本 +1"
	$changed = $true
}
else {
	# 每累计 10 次提交 +1 个小版本，余数保留
	$total = $pending + $commitCount
	if ($total -ge 10) {
		$steps = [int][math]::Floor($total / 10)
		$newPatch = $oldPatch + $steps
		$newPending = $total % 10
		$reason = "累计 $total 次提交，小版本 +$steps"
		$changed = $true
	}
	else {
		$newPending = $total
		$reason = "累计 $total/10 次提交，距上次发布 $daysSinceRelease 天"
	}
}

$oldVersion = "v$oldMajor.$oldMinor.$oldPatch"
$newVersion = "v$newMajor.$newMinor.$newPatch"
$todayText = $today.ToString("yyyy-MM-dd")

if ($changed) {
	if (-not $DryRun) {
		# 改写 AppVersion.gd：只替换两行常量，其余内容原样保留
		$content = [System.IO.File]::ReadAllText($versionScript, [System.Text.Encoding]::UTF8)
		$content = [regex]::Replace($content, 'const VERSION: String = "[^"]*"', "const VERSION: String = `"$newVersion`"")
		$content = [regex]::Replace($content, 'const RELEASE_DATE: String = "[^"]*"', "const RELEASE_DATE: String = `"$todayText`"")
		$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
		[System.IO.File]::WriteAllText($versionScript, $content, $utf8NoBom)

		$state.major = $newMajor
		$state.minor = $newMinor
		$state.patch = $newPatch
		$state.pending = $newPending
		$state.last_bump_commit = $head
		$state.last_bump_date = $todayText
		Save-StateFile $state
	}
	Write-Host "VERSION_BUMPED $oldVersion -> $newVersion ($reason)"
	if (-not $DryRun) {
		Write-Host "已更新 scripts/core/AppVersion.gd 与 tools/version_state.json"
		Write-Host "别忘了在 scripts/data/ChangelogData.gd 的 entries() 顶部补一条 $newVersion 的更新日志"
	}
}
else {
	if (-not $DryRun) {
		# 没升版也要记住这次计入的提交，避免下次重复计数
		$state.pending = $newPending
		$state.last_bump_commit = $head
		Save-StateFile $state
	}
	Write-Host "VERSION_SAME $newVersion ($reason)"
}
