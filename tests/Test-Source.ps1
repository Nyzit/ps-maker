#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SourcePath = Join-Path $ProjectRoot 'ps-maker.ps1'

if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw "Source file not found: $SourcePath"
}

$Tokens = $null
$ParseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $SourcePath,
    [ref]$Tokens,
    [ref]$ParseErrors
)

if ($ParseErrors.Count -gt 0) {
    foreach ($ParseError in $ParseErrors) {
        Write-Error (
            'Line {0}, column {1}: {2}' -f
            $ParseError.Extent.StartLineNumber,
            $ParseError.Extent.StartColumnNumber,
            $ParseError.Message
        )
    }
    exit 1
}

. $SourcePath
$Command = Get-Command -Name ps-maker -CommandType Function -ErrorAction SilentlyContinue
if (-not $Command) {
    throw 'ps-maker function did not load from the source file.'
}

if ($Command.Definition -notmatch '\$Host\.UI\.ReadLine\(\)') {
    throw 'Expected host-based line input was not found in the loaded function.'
}

Write-Host 'PASS: ps-maker.ps1 parses and the ps-maker function loads.' -ForegroundColor Green
Write-Host 'Interactive behavior is covered by tests/manual-test-plan.md.'
