# AI 架构约束检查（R1~R4）
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/ai_arch_check.ps1
#   powershell ... -File tools/ai_arch_check.ps1 -Json   # 只输出 JSON
#
# 判定规则（见 docs/AI架构总设计.md §4）：
#   R1  执行层模块不得直接调用 AI 控制器方法（ai.xxx(...)），跨模块请求应走 Port
#   R2  执行层模块之间不得互相引用（不得出现其它模块的类名/常量）
#   R3  执行层模块构造签名只能是 (context, ports...)，当前为遗留签名会记为待办
#   R4  执行层模块不得直接访问 battle（地图/实体/时间都应经 AIContext）
#
# 说明：R1 会把"包装函数里的回落分支"也算进来——那是迁移期的过渡代码，
# 因此额外统计"回落后备"数量，用来区分"还没迁"和"已迁但保留兜底"。

param([switch]$Json, [switch]$Strict, [switch]$Quiet)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$modules = [ordered]@{
	'AIDefense'       = 'scripts/ai/AIDefense.gd'
	'AIWorkerDirector'= 'scripts/ai/AIWorkerDirector.gd'
	'AIWaterCrossing' = 'scripts/ai/AIWaterCrossing.gd'
	'AILadderSiege'   = 'scripts/ai/AILadderSiege.gd'
	'AIWallPlanner'   = 'scripts/ai/AIWallPlanner.gd'
	'DefenseContext'  = 'scripts/ai/defense/DefenseContext.gd'
	'DefensePlan'     = 'scripts/ai/defense/DefensePlan.gd'
	'DefenseThreat'   = 'scripts/ai/defense/DefenseThreatModel.gd'
	'DefenseDirector' = 'scripts/ai/defense/DefenseDirector.gd'
	'DefenseAlloc'    = 'scripts/ai/defense/DefenseForceAllocator.gd'
}

$moduleNames = @('AIDefense','AIWorkerDirector','AIWaterCrossing','AILadderSiege','AIWallPlanner')
# R2 只统计 5 个平级执行模块之间的互相引用；defense/ 是 AIDefense 的子包，不算违规。

$result = [ordered]@{}
$total = [ordered]@{ r1 = 0; r1_fallback = 0; r2 = 0; r3 = 0; r4 = 0 }

foreach ($name in $modules.Keys) {
	$path = Join-Path $root $modules[$name]
	if (-not (Test-Path $path)) { continue }
	$lines = Get-Content $path -Encoding UTF8

	$r1 = 0; $r1fb = 0; $r2 = 0; $r4 = 0
	foreach ($raw in $lines) {
		$ln = $raw -replace '#.*$', ''
		if ($ln -match '\bai\.[A-Za-z_][A-Za-z0-9_]*\s*\(') {
			$r1++
			if ($ln -match '_ctx\s*!=\s*null\s*else') { $r1fb++ }
		}
		if ($ln -match '\bbattle\.') { $r4++ }
		foreach ($other in $moduleNames) {
			if ($other -eq $name) { continue }
			if ($ln -match ("\b" + $other + "\b")) { $r2++ }
		}
	}

	# R3：构造签名是否为遗留的 _init(owner_ai)
	$r3 = 0
	$initLine = ($lines | Select-String -Pattern '^func _init\(' | Select-Object -First 1)
	if ($initLine -and $initLine.Line -match 'owner_ai') { $r3 = 1 }

	$result[$name] = [ordered]@{ r1 = $r1; r1_fallback = $r1fb; r2 = $r2; r3 = $r3; r4 = $r4 }
	$total.r1 += $r1; $total.r1_fallback += $r1fb; $total.r2 += $r2; $total.r3 += $r3; $total.r4 += $r4
}

$result['TOTAL'] = $total

if ($Json) {
	$result | ConvertTo-Json -Depth 4
	return
}

Write-Output '=== AI 架构约束检查（R1~R4）==='
Write-Output ('{0,-18} {1,6} {2,12} {3,6} {4,6} {5,6}' -f 'module','R1','R1(兜底)','R2','R3','R4')
foreach ($k in $modules.Keys) {
	if (-not $result.Contains($k)) { continue }
	$v = $result[$k]
	Write-Output ('{0,-18} {1,6} {2,12} {3,6} {4,6} {5,6}' -f $k, $v.r1, $v.r1_fallback, $v.r2, $v.r3, $v.r4)
}
Write-Output ('{0,-18} {1,6} {2,12} {3,6} {4,6} {5,6}' -f 'TOTAL', $total.r1, $total.r1_fallback, $total.r2, $total.r3, $total.r4)
Write-Output ''
Write-Output 'R1 = 直接调用 ai.xxx()（含兜底）；R2 = 引用其它执行模块；R3 = 遗留构造签名；R4 = 直接访问 battle'

$outDir = Join-Path $root 'docs/ai-analysis'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$snapshot = [ordered]@{ time = $stamp; version = (Select-String -Path (Join-Path $root 'scripts/core/AppVersion.gd') -Pattern 'const VERSION' | ForEach-Object { $_.Line.Trim() }); detail = $result }
$snapPath = Join-Path $outDir 'arch_check.json'
$snapText = $snapshot | ConvertTo-Json -Depth 5
for ($i = 0; $i -lt 5; $i++) {
	try {
		Set-Content -Path $snapPath -Value $snapText -Encoding UTF8
		break
	} catch {
		Start-Sleep -Milliseconds 120
	}
}
if (-not $Quiet) { Write-Output ('已写入 docs/ai-analysis/arch_check.json (' + $stamp + ')') }

$violations = [int]$total.r1 + [int]$total.r2 + [int]$total.r3 + [int]$total.r4
if ($Strict) {
	if ($violations -gt 0) {
		Write-Output ('[FAIL] 架构约束违规 ' + $violations + ' 处')
		exit 1
	}
	Write-Output '[OK] 架构约束全部通过（R1/R2/R3/R4 均为 0）'
	exit 0
}
