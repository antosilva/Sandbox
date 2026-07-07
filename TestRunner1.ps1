<#
.SYNOPSIS
    Runs dotnet tests with timeout and optional flags.
.DESCRIPTION
    Executes 'dotnet test' on a project or solution with automatic timeout handling.
    Terminates the process tree if tests exceed the specified timeout duration.
.PARAMETER ProjectPath
    Path to the test project (.csproj) or solution (.sln).
.PARAMETER TimeoutSeconds
    Maximum allowed time in seconds (default 300).
.PARAMETER NoBuild
    Skip build phase (adds --no-build flag).
.PARAMETER DotnetArguments
    Additional dotnet test arguments (e.g., "--filter Category=Smoke").
.EXAMPLE
    .\Run-Tests.ps1 .\MyTests.csproj
.EXAMPLE
    .\Run-Tests.ps1 .\MySolution.sln -TimeoutSeconds 120 -NoBuild
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$ProjectPath,

    [Parameter(Position=1)]
    [int]$TimeoutSeconds = 300,

    [switch]$NoBuild,

    [Parameter(Position=2)]
    [string]$DotnetArguments = ""
)

try {
    $ProjectFullPath = Resolve-Path $ProjectPath -ErrorAction Stop
}
catch {
    Write-Error "Project path not found: $ProjectPath"
    exit 1
}

# Build the dotnet test command
$cmdArgs = @("test", "`"$ProjectFullPath`"")
if ($NoBuild) { $cmdArgs += "--no-build" }
$cmdArgs += "--verbosity:normal"
if ($DotnetArguments) { $cmdArgs += $DotnetArguments }
$cmdArgs += "--logger:nunit;LogFilePath=test-results.xml"

Write-Host "Running: dotnet $($cmdArgs -join ' ')" -ForegroundColor Cyan

# Create and start process
$psi = New-Object System.Diagnostics.ProcessStartInfo

$psi.FileName = "dotnet"
$psi.Arguments = $cmdArgs -join " "
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi

$eventNames = @()

try {
    $completedTests = @()
    $testCount = 0

    # Register output handler
    $outputEvent = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action {
        if (-not $EventArgs.Data) { return }

        $line = $EventArgs.Data

        # Capture discovered test count from "discovered 3 of 3"
        if ($line -clike "*discovered*of*") {
            if ($line -cmatch "discovered\s+\d+\s+of\s+(\d+)") {
                $script:testCount = [int]$Matches[1]
            }
            Write-Host $line
        }
        # Match NUnit format: "  Passed TestName [123 ms]" or "  Passed TestName [< 1 ms]"
        elseif ($line -cmatch "^\s+(Passed|Failed|Skipped)\s+(.+?)\s+\[.*?m?s\s*\]") {
            $status = $Matches[1]
            $testName = $Matches[2].Trim()
            $script:completedTests += $testName

            $color = @{"Passed" = "Green"; "Failed" = "Red"; "Skipped" = "Yellow"}[$status]
            Write-Host "[$status] $testName" -ForegroundColor $color
        }
        else {
            Write-Host $line
        }
    }
    $eventNames += $outputEvent.Name

    # Register error handler
    $errorEvent = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action {
        if ($EventArgs.Data) { Write-Host "[ERROR] $($EventArgs.Data)" -ForegroundColor Red }
    }
    $eventNames += $errorEvent.Name

    $process.Start() | Out-Null
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()

    # Wait for completion or timeout
    if ($process.WaitForExit($TimeoutSeconds * 1000)) {
        # Normal exit
        if ($process.ExitCode -eq 0) {
            Write-Host "`nTests passed." -ForegroundColor Green
            exit 0
        }
        else {
            Write-Host "`nTests failed (exit code: $($process.ExitCode))." -ForegroundColor Red
            exit $process.ExitCode
        }
    }
    else {
        # Timeout - wait for any pending output to be buffered
        Start-Sleep -Milliseconds 500

        Write-Host "`nERROR: Tests exceeded timeout ($TimeoutSeconds seconds). Terminating..." -ForegroundColor Red
        Write-Host "Completed tests: $($completedTests.Count)/$testCount" -ForegroundColor Yellow

        if ($testCount -gt 0 -and $completedTests.Count -lt $testCount) {
            Write-Host "`n[TIMEOUT] Test $($completedTests.Count + 1) of $testCount" -ForegroundColor Red
            if ($completedTests.Count -eq 0) {
                Write-Host "  All tests timed out before completion" -ForegroundColor Red
            }
        }

        taskkill /F /T /PID $process.Id 2>&1 | Out-Null
        Start-Sleep -Seconds 1
        exit 1
    }
}
finally {
    # Cleanup
    $process.CancelOutputRead() 2>&1 | Out-Null
    $process.CancelErrorRead() 2>&1 | Out-Null

    foreach ($name in $eventNames) {
        Unregister-Event -SourceIdentifier $name -Force 2>&1 | Out-Null
    }

    $process.Dispose() 2>&1 | Out-Null
}
