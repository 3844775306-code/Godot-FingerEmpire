param(
	[string]$Godot = "godot",
	[string]$Output = "build/web/FingerEmpire.html"
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
& $Godot --headless --path $root --export-release "Web" $outPath
if ($LASTEXITCODE -ne 0) {
	throw "Web export failed with exit code $LASTEXITCODE"
}

Get-ChildItem $outDir -File -Include *.import,*.tmp -ErrorAction SilentlyContinue | Remove-Item -Force
$total = (Get-ChildItem $outDir -File | Measure-Object Length -Sum).Sum
Write-Host ("Web build ready: {0} ({1:N1} MB)" -f $outDir, ($total / 1MB))
Write-Host "Run: node tools/serve_web.mjs build/web 8090"
