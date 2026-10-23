# GDScript format checker for pre-commit hook

$ErrorActionPreference = "Stop"

$staged = git diff --cached --name-only --diff-filter=ACM -- "*.gd" 2>$null
if (-not $staged -or $staged.Count -eq 0) {
    exit 0
}

$issues = New-Object System.Collections.ArrayList
$maxIssues = 30

foreach ($f in $staged) {
    if (-not (Test-Path $f)) { continue }
    try { $lines = Get-Content $f -ErrorAction Stop } catch { continue }

    $i = 0
    foreach ($line in $lines) {
        $i++
        if ($line -match '^\s*$') { continue }

        if ($line -match '^(    |  )') {
            [void]$issues.Add("[INDENT] ${f}:$i - spaces used instead of tabs")
        }

        if ($line -match ' $') {
            [void]$issues.Add("[TRAILING] ${f}:$i - trailing whitespace")
        }

        if ($issues.Count -ge $maxIssues) { break }
    }
    if ($issues.Count -ge $maxIssues) { break }
}

if ($issues.Count -eq 0) {
    exit 0
}

$msg = "GDScript format check: $($issues.Count) issue(s) found`n"
$show = [Math]::Min($issues.Count, $maxIssues)
for ($j = 0; $j -lt $show; $j++) {
    $msg += $issues[$j] + "`n"
}
if ($issues.Count -ge $maxIssues) {
    $msg += "... showing first $maxIssues only`n"
}
$msg += "GDScript standard: use tabs for indent, no trailing spaces."

$json = @{ systemMessage = $msg; continue = $true } | ConvertTo-Json -Compress
Write-Output $json
