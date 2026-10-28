#requires -Version 5.1
<#
.SYNOPSIS
    Runs automated source and integration tests for ps-maker.
.DESCRIPTION
    No third-party test module is required. The integration checks feed input to a
    fresh PowerShell console process, exercising ps-maker's normal interactive
    path. Ctrl+C behavior and deliberate file-lock/deletion-failure scenarios still
    require manual verification.
#>

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SourcePath = Join-Path $ProjectRoot 'ps-maker.ps1'
$InteractiveRunner = Join-Path $PSScriptRoot 'fixtures\Run-Interactive.ps1'

if ($PSVersionTable.PSEdition -eq 'Core') {
    $PowerShellExe = Join-Path $PSHOME 'pwsh.exe'
}
else {
    $PowerShellExe = Join-Path $PSHOME 'powershell.exe'
}

if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw "Source file not found: $SourcePath"
}
if (-not (Test-Path -LiteralPath $InteractiveRunner -PathType Leaf)) {
    throw "Interactive runner not found: $InteractiveRunner"
}
if (-not (Test-Path -LiteralPath $PowerShellExe -PathType Leaf)) {
    throw "PowerShell executable not found: $PowerShellExe"
}

$script:TestCount = 0
$script:FailureCount = 0

function Write-TestResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [string]$Detail
    )

    if ($Passed) {
        Write-Host "PASS  $Name" -ForegroundColor Green
    }
    else {
        $script:FailureCount++
        Write-Host "FAIL  $Name" -ForegroundColor Red
        if ($Detail) {
            Write-Host $Detail -ForegroundColor DarkRed
        }
    }
}

Write-Host 'ps-maker automated test suite' -ForegroundColor Cyan
Write-Host "PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
Write-Host ''

# Test 1: source parses and defines the expected function.
$script:TestCount++
$Tokens = $null
$ParseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $SourcePath,
    [ref]$Tokens,
    [ref]$ParseErrors
)

if ($ParseErrors.Count -gt 0) {
    $ParseDetails = ($ParseErrors | ForEach-Object {
        'Line {0}, column {1}: {2}' -f
            $_.Extent.StartLineNumber,
            $_.Extent.StartColumnNumber,
            $_.Message
    }) -join [Environment]::NewLine
    Write-TestResult -Name 'Source parses' -Passed $false -Detail $ParseDetails
}
else {
    try {
        . $SourcePath
        $Function = Get-Command -Name ps-maker -CommandType Function -ErrorAction Stop
        Write-TestResult -Name 'Source parses and function loads' -Passed ($null -ne $Function)
    }
    catch {
        Write-TestResult -Name 'Source parses and function loads' -Passed $false -Detail $_.Exception.Message
    }
}

function Invoke-InteractiveCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$InputText,
        [string[]]$MustContain = @(),
        [string[]]$MustNotContain = @(),
        [bool]$ExpectTemporaryScript = $true,
        [int]$TimeoutSeconds = 25
    )

    $script:TestCount++
    $Passed = $true
    $Problems = [System.Collections.Generic.List[string]]::new()
    $Process = $null
    $OutputText = ''

    try {
        $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $StartInfo.FileName = $PowerShellExe
        $StartInfo.Arguments = '-NoLogo -NoProfile -File "{0}" -SourcePath "{1}"' -f $InteractiveRunner, $SourcePath
        $StartInfo.UseShellExecute = $false
        $StartInfo.CreateNoWindow = $true
        $StartInfo.RedirectStandardInput = $true
        $StartInfo.RedirectStandardOutput = $true
        $StartInfo.RedirectStandardError = $true

        $Process = [System.Diagnostics.Process]::new()
        $Process.StartInfo = $StartInfo
        if (-not $Process.Start()) {
            throw 'Could not start the PowerShell test process.'
        }

        # Drain output asynchronously so full pipes cannot deadlock the process.
        $StdOutTask = $Process.StandardOutput.ReadToEndAsync()
        $StdErrTask = $Process.StandardError.ReadToEndAsync()
        $Process.StandardInput.Write($InputText)
        $Process.StandardInput.Close()

        if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $Process.Kill() } catch { }
            try { $Process.WaitForExit() } catch { }
            throw "Timed out after $TimeoutSeconds seconds. The host may not support redirected interactive input."
        }

        $StdOut = $StdOutTask.GetAwaiter().GetResult()
        $StdErr = $StdErrTask.GetAwaiter().GetResult()
        $OutputText = $StdOut + [Environment]::NewLine + $StdErr

        if ($Process.ExitCode -ne 0) {
            $Passed = $false
            [void]$Problems.Add("Test harness exited with code $($Process.ExitCode).")
        }

        foreach ($Pattern in $MustContain) {
            if ($OutputText -notmatch $Pattern) {
                $Passed = $false
                [void]$Problems.Add("Expected output pattern not found: $Pattern")
            }
        }

        foreach ($Pattern in $MustNotContain) {
            if ($OutputText -match $Pattern) {
                $Passed = $false
                [void]$Problems.Add("Unexpected output pattern found: $Pattern")
            }
        }

        if ($OutputText -match 'Could not delete temporary file') {
            $Passed = $false
            [void]$Problems.Add('The tool reported temporary-file cleanup failure.')
        }

        $DeletedNames = [regex]::Matches(
            $OutputText,
            'Temporary script deleted: (ps-maker-[A-Za-z0-9-]+\.ps1)'
        )

        if ($ExpectTemporaryScript -and $DeletedNames.Count -eq 0) {
            $Passed = $false
            [void]$Problems.Add('Expected a temporary-script deletion confirmation, but none was found.')
        }

        foreach ($Match in $DeletedNames) {
            $TempPath = Join-Path ([System.IO.Path]::GetTempPath()) $Match.Groups[1].Value
            if (Test-Path -LiteralPath $TempPath) {
                $Passed = $false
                [void]$Problems.Add("Temporary file still exists: $TempPath")
            }
        }

        Write-TestResult -Name $Name -Passed $Passed -Detail (($Problems -join [Environment]::NewLine) +
            $(if (-not $Passed) { [Environment]::NewLine + '--- Captured output ---' + [Environment]::NewLine + $OutputText } else { '' }))
    }
    catch {
        Write-TestResult -Name $Name -Passed $false -Detail ($_.Exception.Message +
            $(if ($OutputText) { [Environment]::NewLine + $OutputText } else { '' }))
    }
    finally {
        if ($null -ne $Process) {
            $Process.Dispose()
        }
    }
}

# Test 2: ordinary successful script.
Invoke-InteractiveCase -Name 'Normal execution and cleanup' `
    -InputText "Write-Output 'PSMAKER_NORMAL_OK'`r`n:run`r`n" `
    -MustContain @('PSMAKER_NORMAL_OK', 'Script process finished with exit code 0\.')

# Test 3: non-terminating error is reported, and later commands still run.
Invoke-InteractiveCase -Name 'Non-terminating error detection' `
    -InputText "Write-Error 'expected test error'`r`nWrite-Output 'PSMAKER_CONTINUED_OK'`r`n:run`r`n" `
    -MustContain @('expected test error', 'PSMAKER_CONTINUED_OK', 'detected [1-9]\d* PowerShell error record', 'exited with code [1-9]\d*\.')

# Test 4: terminating error fails without closing the outer test process.
Invoke-InteractiveCase -Name 'Terminating error detection' `
    -InputText "throw 'PSMAKER_THROW_MARKER'`r`n:run`r`n" `
    -MustContain @('PSMAKER_THROW_MARKER', 'exited with code [1-9]\d*\.')

# Test 5: syntax errors are rejected before execution.
Invoke-InteractiveCase -Name 'Syntax validation prevents execution' `
    -InputText "Write-Output 'PSMAKER_MUST_NOT_RUN'`r`nif (`r`n:run`r`n" `
    -MustContain @('Syntax errors found\. The script was not executed\.', 'Temporary script deleted:') `
    -MustNotContain @('(?m)^PSMAKER_MUST_NOT_RUN\s*$')

# Test 6: exit 7 must not close the test harness; the child exit code is shown.
Invoke-InteractiveCase -Name 'exit 7 stays in the child process' `
    -InputText "exit 7`r`n:run`r`n" `
    -MustContain @('Script process exited with code 7\.')

# Test 7: a long line is preserved by the host line reader.
$LongLine = '$longValue = "' + ('A' * 1500) + '"; Write-Output $longValue.Length'
Invoke-InteractiveCase -Name 'Long input line is preserved' `
    -InputText ($LongLine + "`r`n:run`r`n") `
    -MustContain @('(?m)^1500\s*$')

# Test 8: cancellation must prevent execution and must not create a temp file.
Invoke-InteractiveCase -Name 'Cancellation prevents execution' `
    -InputText "Write-Output 'PSMAKER_CANCEL_MUST_NOT_RUN'`r`n:cancel`r`n" `
    -MustContain @('Cancelled\.') `
    -MustNotContain @('(?m)^PSMAKER_CANCEL_MUST_NOT_RUN\s*$', 'Temporary script deleted:') `
    -ExpectTemporaryScript $false

# Test 9: empty input does not create a temp file.
Invoke-InteractiveCase -Name 'Empty input is ignored' `
    -InputText ":run`r`n" `
    -MustContain @('No script entered; nothing to execute\.') `
    -MustNotContain @('Temporary script deleted:') `
    -ExpectTemporaryScript $false

# Test 10: native command failure must be reported as nonzero.
Invoke-InteractiveCase -Name 'Native command nonzero exit is detected' `
    -InputText "cmd.exe /d /c exit 7`r`n:run`r`n" `
    -MustContain @('Script process exited with code [1-9]\d*\.')

Write-Host ''
if ($script:FailureCount -eq 0) {
    Write-Host "ALL PASS: $script:TestCount checks passed." -ForegroundColor Green
    exit 0
}

Write-Host "FAILED: $script:FailureCount of $script:TestCount checks failed." -ForegroundColor Red
exit 1
