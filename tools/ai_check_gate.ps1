# AI 架构检查门禁
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/ai_check_gate.ps1
#
# 只要改动过 scripts/ai/ 下的执行层代码（AIDefense / AIWorkerDirector / AIWaterCrossing /
# AILadderSiege / AIWallPlanner / defense 子包），提交前跑一遍这个脚本：
#   - 退出码 0 = 架构约束全部通过（R1/R2/R3/R4 均为 0）
#   - 退出码 1 = 有违规，先修再提交
#
# 规则说明见 docs/AI架构总设计.md §4，检查实现见 tools/ai_arch_check.ps1。

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'ai_arch_check.ps1') -Strict
exit $LASTEXITCODE
