#requires -Version 5.1
<#
.SYNOPSIS
    Collects and runs a PowerShell script entered interactively.
.DESCRIPTION
    Accepts multiline PowerShell input until :run or :cancel is entered.
    Validates syntax before execution, runs the script in a child PowerShell
    process, and attempts to remove the temporary script after the child exits.
.NOTES
    This is not a sandbox. Submitted code runs with the current user's permissions.
#>

function ps-maker {
    [CmdletBinding()]
    param()

    $CreatedFiles = [System.Collections.Generic.List[string]]::new()
    $Lines = [System.Collections.Generic.List[string]]::new()
    $TempScript = $null

    try {
        Write-Host ''
        Write-Host 'Paste your PowerShell script below.'
        Write-Host 'Type :run on its own line and press Enter to execute.'
        Write-Host 'Type :cancel on its own line to cancel.'
        Write-Host 'Press Ctrl+C to interrupt input or execution.'
        Write-Host ''

        while ($true) {
            $Host.UI.Write('ps-maker> ')
            $Line = $Host.UI.ReadLine()

            if ($null -eq $Line) {
                Write-Host "`nInput ended; cancelling."
                return
            }

            if ($Line -ceq ':run') {
                break
            }

            if ($Line -ceq ':cancel') {
                Write-Host 'Cancelled.'
                return
            }

            [void]$Lines.Add($Line)
        }

        $ScriptText = $Lines -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($ScriptText)) {
            Write-Host 'No script entered; nothing to execute.'
            return
        }

        # Create temporary files exclusively to avoid overwriting an existing file.
        $CreateTempFile = {
            param([string]$Content)

            $Path = Join-Path ([System.IO.Path]::GetTempPath()) (
                'ps-maker-' + [guid]::NewGuid().ToString('N') + '.ps1'
            )

            $Stream = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )

            [void]$CreatedFiles.Add($Path)

            try {
                $Bytes = [System.Text.UTF8Encoding]::new($true).GetBytes($Content)
                $Stream.Write($Bytes, 0, $Bytes.Length)
            }
            finally {
                $Stream.Dispose()
            }

            return $Path
        }

        $TempScript = & $CreateTempFile $ScriptText

        # Parse first so syntax errors don't execute a partial/invalid script.
        $Tokens = $null
        $ParseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $TempScript,
            [ref]$Tokens,
            [ref]$ParseErrors
        )

        if ($ParseErrors.Count -gt 0) {
            Write-Host "`nSyntax errors found. The script was not executed." -ForegroundColor Red
            foreach ($ParseError in $ParseErrors) {
                Write-Host (
                    'Line {0}, column {1}: {2}' -f
                    $ParseError.Extent.StartLineNumber,
                    $ParseError.Extent.StartColumnNumber,
                    $ParseError.Message
                ) -ForegroundColor Red
            }
            return
        }

        # The encoded child command checks PowerShell errors and returns an exit code.
        # Escaped variables are intentional: they must expand in the child, not here.
        $RunnerCommand = @"
`$ScriptPath = `$env:PS_MAKER_SCRIPT_PATH
if ([string]::IsNullOrWhiteSpace(`$ScriptPath) -or -not (Test-Path -LiteralPath `$ScriptPath -PathType Leaf)) {
    [Console]::Error.WriteLine('ps-maker: submitted script was not found.')
    exit 2
}

`# Start with no native exit status so we can detect whether the submitted script
# actually ran a native program and left a nonzero status behind.
`$global:LASTEXITCODE = `$null
`$PriorErrors = @(`$global:Error)
`$InvocationSucceeded = `$true
`$InvocationException = `$null
try {
    & `$ScriptPath
    `$InvocationSucceeded = `$?
}
catch {
    # PowerShell implements the `exit` keyword with ExitException. Preserve its
    # requested process exit code instead of misreporting it as a generic error.
    if (`$_.Exception -is [System.Management.Automation.ExitException]) {
        `$RequestedExitCode = `$_.Exception.Argument
        if (`$null -eq `$RequestedExitCode -or [string]::IsNullOrWhiteSpace([string]`$RequestedExitCode)) {
            exit 0
        }
        `$ParsedExitCode = 1
        if ([int]::TryParse([string]`$RequestedExitCode, [ref]`$ParsedExitCode)) {
            exit `$ParsedExitCode
        }
        exit 1
    }

    `$InvocationException = `$_
    [Console]::Error.WriteLine(`$_.ToString())
}

`$NewErrorCount = 0
foreach (`$CurrentError in @(`$global:Error)) {
    `$WasExisting = `$false
    foreach (`$OldError in `$PriorErrors) {
        if ([object]::ReferenceEquals(`$CurrentError, `$OldError)) {
            `$WasExisting = `$true
            break
        }
    }
    if (-not `$WasExisting) {
        `$NewErrorCount++
    }
}

if (`$null -ne `$InvocationException -or `$NewErrorCount -gt 0) {
    if (`$NewErrorCount -gt 0) {
        [Console]::Error.WriteLine(('ps-maker: detected {0} PowerShell error record(s).' -f `$NewErrorCount))
    }
    exit 1
}

# Native executables report errors via LASTEXITCODE, not PowerShell's Error
# collection. Propagate a nonzero final native exit code to the parent process.
if (`$null -ne `$global:LASTEXITCODE -and [int]`$global:LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine(('ps-maker: native command returned exit code {0}.' -f `$global:LASTEXITCODE))
    exit [int]`$global:LASTEXITCODE
}

if (-not `$InvocationSucceeded) {
    exit 1
}
exit 0
"@

        $EncodedCommand = [Convert]::ToBase64String(
            [System.Text.Encoding]::Unicode.GetBytes($RunnerCommand)
        )

        if ($PSVersionTable.PSEdition -eq 'Core') {
            $PowerShellExe = Join-Path $PSHOME 'pwsh.exe'
        }
        else {
            $PowerShellExe = Join-Path $PSHOME 'powershell.exe'
        }

        if (-not (Test-Path -LiteralPath $PowerShellExe -PathType Leaf)) {
            throw "Could not find the PowerShell executable at '$PowerShellExe'."
        }

        $HadPreviousEnvValue = Test-Path Env:PS_MAKER_SCRIPT_PATH
        $PreviousEnvValue = $env:PS_MAKER_SCRIPT_PATH

        try {
            $env:PS_MAKER_SCRIPT_PATH = $TempScript
            $ArgumentLine = '-NoLogo -NoProfile -EncodedCommand {0}' -f $EncodedCommand

            Write-Host "`n--- Executing in a child PowerShell process ---`n"
            $ChildProcess = Start-Process `
                -FilePath $PowerShellExe `
                -ArgumentList $ArgumentLine `
                -NoNewWindow `
                -Wait `
                -PassThru `
                -ErrorAction Stop

            if ($ChildProcess.ExitCode -eq 0) {
                Write-Host "`nScript process finished with exit code 0." -ForegroundColor Green
            }
            else {
                Write-Warning "Script process exited with code $($ChildProcess.ExitCode). Review the output above."
            }
        }
        finally {
            if ($HadPreviousEnvValue) {
                $env:PS_MAKER_SCRIPT_PATH = $PreviousEnvValue
            }
            else {
                Remove-Item Env:PS_MAKER_SCRIPT_PATH -ErrorAction SilentlyContinue
            }
        }
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        Write-Host "`nInput or execution was interrupted." -ForegroundColor Yellow
    }
    catch {
        Write-Host "`nps-maker failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        foreach ($TemporaryFile in $CreatedFiles) {
            if ([System.IO.File]::Exists($TemporaryFile)) {
                try {
                    Remove-Item -LiteralPath $TemporaryFile -Force -ErrorAction Stop

                    if ([System.IO.File]::Exists($TemporaryFile)) {
                        throw [System.IO.IOException]::new('The file still exists after removal.')
                    }

                    Write-Host (
                        'Temporary script deleted: {0}' -f
                        [System.IO.Path]::GetFileName($TemporaryFile)
                    ) -ForegroundColor DarkGray
                }
                catch {
                    Write-Warning (
                        "Could not delete temporary file '$TemporaryFile': " +
                        $_.Exception.Message
                    )
                }
            }
        }
    }
}
