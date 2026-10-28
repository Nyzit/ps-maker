# Manual test plan

Run these checks in a Windows Terminal PowerShell tab after loading `ps-maker.ps1`.

## 1. Normal execution

Input:

```powershell
Write-Host 'normal execution passed'
:run
```

Expected: the message appears, the process exits with code 0, and the tool reports deleting the temporary script.

## 2. Non-terminating PowerShell error

Input:

```powershell
Write-Error 'expected test error'
Write-Host 'script continued after error'
:run
```

Expected: the error is displayed, the later message appears, and the parent reports a nonzero exit code.

## 3. Terminating error

Input:

```powershell
throw 'expected terminating test error'
:run
```

Expected: the exception is displayed, the parent terminal remains open, and a nonzero exit code is reported.

## 4. Syntax validation

Input:

```powershell
if (
:run
```

Expected: a syntax error is shown and the script is not executed.

## 5. `exit` must not close the parent terminal

Input:

```powershell
exit 7
:run
```

Expected: the child exits with code 7, the parent terminal remains usable, and the temporary script is deleted.

## 6. Long input line

Paste a single valid PowerShell line longer than 1,022 characters, such as an assignment to a string literal containing at least 1,500 characters. On a following line, check that the resulting string has the expected length, then enter `:run`.

Expected: the full line is preserved. If the terminal host itself imposes a limit, document the host and observed limit.

## 7. Cancellation before execution

Input:

```powershell
Write-Host 'this must not appear'
:cancel
```

Expected: the script is not executed and no temporary script file is left behind.

## 8. Native command exit code

Input:

```powershell
cmd.exe /d /c exit 7
:run
```

Expected: the child process reports a nonzero exit code.

## 9. Cleanup failure reporting

Review the normal and error cases and confirm that each existing temporary script is reported as deleted. A deliberate deletion-failure test may require a separate test harness that locks a temporary file; do not change system permissions just to force this test.

## 10. Cancellation during input or execution

Press Ctrl+C while entering input, then try again with a long-running command such as `Start-Sleep -Seconds 60` after entering `:run`.

Expected: cancellation returns control when the host/process permits it and cleanup is attempted. Forced termination of the parent process is outside the cleanup guarantee.
