# 版本号自动递进工具
#
# 规则（玩家定的，2026-10 起按「大版本 = 游戏时代」重新命名）：
#   1. 大版本代表游戏时代：1.0 起步、2.0 模型与 AI、3.0 Steam 与混战、4.0 画面重制与三端发布；
#      由玩家口头指定，或在相邻两次提交间隔 ≥ 30 天时自动 +1 个大版本；
#   2. 同一时代内每累计 10 次提交 +1 个小版本，例如 v4.0.0 → v4.0.1（余数保留到下次）；
#   3. 相邻两次提交间隔 ≥ 3 天 → +1 个中版本，小版本归零，例如 v4.0.8 → v4.1.0；
#   4. 大版本也可由玩家口头指定：-Major 4 → 4.0.0。
#
# 每次任务提交后跑一次。脚本会从 version_state.json 的 last_bump_commit
# 之后逐个回放提交到 HEAD，所以补算历史提交与日常递增使用同一套规则。
#
# 参数：
#   -DryRun   只打印判断结果，不写任何文件（调试用）
#   -Major N  手动指定大版本，重置中/小版本（如 -Major 4 → 4.0.0）

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
$fromCommit = $fromCommit.Trim()

$oldMajor = [int]$state.major
$oldMinor = [int]$state.minor
$oldPatch = [int]$state.patch
$pending = [int]$state.pending

$newMajor = $oldMajor
$newMinor = $oldMinor
$newPatch = $oldPatch
$newPending = $pending
$latestCommitDate = $null
$reasons = New-Object System.Collections.Generic.List[string]

if ($Major -ge 0) {
	# 玩家指定的新大版本：中/小版本归零，计数清空
	$newMajor = $Major
	$newMinor = 0
	$newPatch = 0
	$newPending = 0
	$reasons.Add("玩家指定大版本")
} elseif ($fromCommit -ne $head) {
	# 从上次计入的提交之后逐个回放，按相邻提交的日期差处理中/大版本
	$rawCommits = @(& git log --reverse --format="%H|%cI" "$fromCommit..$head")
	$commits = New-Object System.Collections.Generic.List[object]
	foreach ($line in $rawCommits) {
		if ([string]::IsNullOrWhiteSpace($line)) { continue }
		$parts = $line -split "\|", 2
		if ($parts.Count -lt 2) { continue }
		$commits.Add([pscustomobject]@{
			Hash = $parts[0].Trim()
			Date = [datetime]::Parse($parts[1].Trim())
		})
	}

	if ($commits.Count -gt 0) {
		$fromDateText = (& git show -s --format=%cI $fromCommit | Out-String).Trim()
		$prevDate = [datetime]::Parse($fromDateText)

		foreach ($commit in $commits) {
			$gapDays = [int]($commit.Date.Date - $prevDate.Date).Days
			if ($gapDays -ge 30) {
				$newMajor += 1
				$newMinor = 0
				$newPatch = 0
				$newPending = 0
				$reasons.Add("提交间隔 $gapDays 天，大版本 +1")
			} elseif ($gapDays -ge 3) {
				$newMinor += 1
				$newPatch = 0
				$newPending = 0
				$reasons.Add("提交间隔 $gapDays 天，中版本 +1")
			} else {
				$newPending += 1
				if ($newPending -ge 10) {
					$steps = [int][math]::Floor($newPending / 10)
					$newPatch += $steps
					$newPending = $newPending % 10
					$reasons.Add("累计 10 次提交，小版本 +$steps")
				}
			}
			$prevDate = $commit.Date
		}
		$latestCommitDate = $commits[$commits.Count - 1].Date
	}
}

$oldVersion = "v$oldMajor.$oldMinor.$oldPatch"
$newVersion = "v$newMajor.$newMinor.$newPatch"
$changed = $oldVersion -ne $newVersion
$todayText = (Get-Date).ToString("yyyy-MM-dd")
$releaseDateText = if ($latestCommitDate -ne $null) { $latestCommitDate.ToString("yyyy-MM-dd") } else { $todayText }
$reasonText = if ($reasons.Count -gt 0) { [string]::Join("；", $reasons) } else { "累计 $newPending/10 次提交" }

if ($changed) {
	if (-not $DryRun) {
		# 改写 AppVersion.gd：只替换两行常量，其余内容原样保留
		$content = [System.IO.File]::ReadAllText($versionScript, [System.Text.Encoding]::UTF8)
		$content = [regex]::Replace($content, 'const VERSION: String = "[^"]*"', "const VERSION: String = `"$newVersion`"")
		$content = [regex]::Replace($content, 'const RELEASE_DATE: String = "[^"]*"', "const RELEASE_DATE: String = `"$releaseDateText`"")
		$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
		[System.IO.File]::WriteAllText($versionScript, $content, $utf8NoBom)

		$state.major = $newMajor
		$state.minor = $newMinor
		$state.patch = $newPatch
		$state.pending = $newPending
		$state.last_bump_commit = $head
		$state.last_bump_date = $releaseDateText
		Save-StateFile $state
	}
	Write-Host "VERSION_BUMPED $oldVersion -> $newVersion ($reasonText)"
	if (-not $DryRun) {
		Write-Host "已更新 scripts/core/AppVersion.gd 与 tools/version_state.json"
		Write-Host "别忘了在 scripts/data/ChangelogData.gd 的 entries() 顶部补一条 $newVersion 的更新日志"
	}
} else {
	if (-not $DryRun) {
		# 没升版也要记住这次计入的提交，避免下次重复计数
		$state.pending = $newPending
		$state.last_bump_commit = $head
		if ($latestCommitDate -ne $null) {
			$state.last_bump_date = $releaseDateText
		}
		Save-StateFile $state
	}
	Write-Host "VERSION_SAME $newVersion ($reasonText)"
}
