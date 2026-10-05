$entry = Join-Path $PSScriptRoot 'ddd.py'
$python = $null
foreach ($candidate in @($env:PYTHON, 'python', 'python3', 'py')) {
    if (-not $candidate) { continue }
    if (-not (Get-Command $candidate -ErrorAction SilentlyContinue)) { continue }
    if ($candidate -eq 'py') {
        & py -3 -c "" 2>$null
        if ($LASTEXITCODE -eq 0) { $python = @('py', '-3'); break }
        continue
    }
    & $candidate -c "import sys; sys.exit(sys.version_info < (3, 8))" 2>$null
    if ($LASTEXITCODE -eq 0) { $python = @($candidate); break }
}
if (-not $python) {
    if ($args.Count -gt 0 -and $args[0] -eq 'hook') { $null = $input | Out-String; exit 0 }
    Write-Error 'ddd: needs Python 3.8+ on PATH (python, python3 or py -3)'
    exit 127
}
$exe = $python[0]
$rest = @()
if ($python.Count -gt 1) { $rest = $python[1..($python.Count - 1)] }
if ($MyInvocation.ExpectingInput) {
    $input | & $exe @rest $entry @args
} else {
    & $exe @rest $entry @args
}
exit $LASTEXITCODE
