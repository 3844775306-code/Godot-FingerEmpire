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
$total = (Get-ChildItem $outDir -File | Measure-Object Length -Sum).Sum
Write-Host ("Web build ready: {0} ({1:N1} MB)" -f $outDir, ($total / 1MB))
Write-Host "Run: node tools/serve_web.mjs build/web 8090"
