<#PSScriptInfo
.VERSION 1.0.0
.AUTHOR Antonio DA SILVA
.DESCRIPTION Runs dotnet tests on assemblies matching a pattern with NUnit 3 report output, timeout, and optional coverage.
#>

<#
.SYNOPSIS
    Runs dotnet tests on assemblies matching a pattern with NUnit 3 report output and timeout.

.DESCRIPTION
    This script runs `dotnet test` on assemblies matching the specified pattern. It generates an NUnit 3 XML report,
    enforces a configurable timeout, outputs individual test statuses, provides global statistics, and optionally
    enables test coverage collection. Any remaining test runners are killed at the end.

.PARAMETER AssemblyPattern
    The file pattern to match test assemblies (e.g., "**/*Tests.dll" or "MyProject.Tests.dll").

.PARAMETER TimeoutSeconds
    Maximum time in seconds to wait for the test runner before killing it. Default: 300 (5 minutes).

.PARAMETER EnableCoverage
    Switch to enable code coverage collection using XPlat Code Coverage.

.PARAMETER OutputDirectory
    Directory for test results and reports. Default: "./TestResults".

.EXAMPLE
    .\run-nunit-tests.ps1 -AssemblyPattern "**/*Tests.dll" -TimeoutSeconds 600 -EnableCoverage

.EXAMPLE
    .\run-nunit-tests.ps1 -AssemblyPattern "MyApp.Tests.dll" -TimeoutSeconds 120

.EXAMPLE
    .\run-nunit-tests.ps1 -AssemblyPattern "*.Tests.dll" -EnableCoverage
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$AssemblyPattern,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 300,

    [Parameter(Mandatory = $false)]
    [switch]$EnableCoverage,

    [Parameter(Mandatory = $false)]
    [string]$OutputDirectory = "./TestResults"
)

#region Helper Functions

function Get-NUnitTestResults {
    param (
        [string]$XmlPath
    )

    if (-not (Test-Path -Path $XmlPath)) {
        Write-Warning "NUnit report not found at: $XmlPath"
        return @{
            Tests = @()
            Total = 0
            Passed = 0
            Failed = 0
            Skipped = 0
            Inconclusive = 0
            Duration = "0"
        }
    }

    try {
        [xml]$nunitXml = Get-Content -Path $XmlPath -Raw -ErrorAction Stop

        $results = @{
            Tests = @()
            Total = 0
            Passed = 0
            Failed = 0
            Skipped = 0
            Inconclusive = 0
            Duration = "0"
        }

        # Extract summary from test-run element
        $testRun = $nunitXml.SelectSingleNode("//test-run")
        if ($testRun -ne $null) {
            $results.Total = if ($testRun.total) { [int]$testRun.total } else { 0 }
            $results.Passed = if ($testRun.passed) { [int]$testRun.passed } else { 0 }
            $results.Failed = if ($testRun.failed) { [int]$testRun.failed } else { 0 }
            $results.Skipped = if ($testRun.skipped) { [int]$testRun.skipped } else { 0 }
            $results.Inconclusive = if ($testRun.inconclusive) { [int]$testRun.inconclusive } else { 0 }
            $results.Duration = if ($testRun.duration) { $testRun.duration } else { "0" }
        }

        # Extract individual test cases
        $testCases = $nunitXml.SelectNodes("//test-case")
        foreach ($testCase in $testCases) {
            $testInfo = @{
                Name = $testCase.GetAttribute("name")
                FullName = $testCase.GetAttribute("fullname")
                Result = $testCase.GetAttribute("result")
                Time = $testCase.GetAttribute("time")
                Message = $testCase.GetAttribute("message")
                StackTrace = $testCase.GetAttribute("stack-trace")
                Assertions = $testCase.GetAttribute("assertions")
            }
            $results.Tests += $testInfo
        }

        return $results

    } catch {
        Write-Warning "Error parsing NUnit XML: $_"
        return @{
            Tests = @()
            Total = 0
            Passed = 0
            Failed = 0
            Skipped = 0
            Inconclusive = 0
            Duration = "0"
        }
    }
}

function Show-TestResults {
    param (
        [object]$Results,
        [bool]$ShowIndividual = $true
    )

    Write-Host (`"`n" + ("=" * 80)) -ForegroundColor DarkCyan
    Write-Host "TEST RESULTS SUMMARY" -ForegroundColor DarkCyan
    Write-Host ("=" * 80) -ForegroundColor DarkCyan
    Write-Host ""

    # Global statistics
    $stats = @(
        ("Total Tests:  {0,8}" -f $Results.Total)
        ("Passed:       {0,8}" -f $Results.Passed)
        ("Failed:       {0,8}" -f $Results.Failed)
        ("Skipped:      {0,8}" -f $Results.Skipped)
        ("Inconclusive: {0,8}" -f $Results.Inconclusive)
    )

    foreach ($stat in $stats) {
        if ($stat -match "Passed") { Write-Host $stat -ForegroundColor Green }
        elseif ($stat -match "Failed") { Write-Host $stat -ForegroundColor Red }
        elseif ($stat -match "Skipped") { Write-Host $stat -ForegroundColor Yellow }
        elseif ($stat -match "Inconclusive") { Write-Host $stat -ForegroundColor Magenta }
        else { Write-Host $stat -ForegroundColor White }
    }

    # Duration
    if ($Results.Duration -and $Results.Duration -ne "0") {
        Write-Host ("Duration:      {0}s" -f $Results.Duration) -ForegroundColor Cyan
    }

    # Success rate
    if ($Results.Total -gt 0) {
        $successRate = ($Results.Passed / $Results.Total) * 100
        Write-Host ("Success Rate:  {0:N2}%" -f $successRate) -ForegroundColor Cyan
    }
    Write-Host ""

    # Individual test statuses
    if ($ShowIndividual -and $Results.Tests.Count -gt 0) {
        Write-Host ("-" * 80) -ForegroundColor DarkCyan
        Write-Host "INDIVIDUAL TEST STATUS" -ForegroundColor DarkCyan
        Write-Host ("-" * 80) -ForegroundColor DarkCyan

        foreach ($test in $Results.Tests) {
            $statusColor = "White"
            $statusIcon = "[????]"

            switch ($test.Result) {
                "Success" { 
                    $statusColor = "Green"
                    $statusIcon = "[PASS]"
                }
                "Failure" { 
                    $statusColor = "Red"
                    $statusIcon = "[FAIL]"
                }
                "Skipped" { 
                    $statusColor = "Yellow"
                    $statusIcon = "[SKIP]"
                }
                "Inconclusive" { 
                    $statusColor = "Magenta"
                    $statusIcon = "[INCL]"
                }
            }

            $timeDisplay = if ($test.Time -and $test.Time -ne "0") { " ({0}s)" -f [math]::Round([double]$test.Time, 3) } else { "" }
            Write-Host ("$statusIcon $($test.FullName)$timeDisplay") -ForegroundColor $statusColor

            # Show failure details
            if ($test.Result -eq "Failure" -and $test.Message) {
                Write-Host ("    Message: $($test.Message)") -ForegroundColor Red
                if ($test.StackTrace) {
                    Write-Host ("    Stack: $($test.StackTrace.Substring(0, [Math]::Min(200, $test.StackTrace.Length)))...") -ForegroundColor DarkRed
                }
            }
        }
        Write-Host ""
    }

    Write-Host ("=" * 80) -ForegroundColor DarkCyan
}

function Kill-RemainingTestRunners {
    param (
        [array]$KnownProcesses
    )

    Write-Host "Cleaning up any remaining test runner processes..." -ForegroundColor Cyan

    # Find all dotnet processes that might be test runners
    $dotnetProcesses = Get-Process -Name "dotnet" -ErrorAction SilentlyContinue | 
        Where-Object { 
            $_.Id -notin $KnownProcesses.Id -and (
                $_.CommandLine -like "*dotnet test*" -or 
                $_.CommandLine -like "*vstest*" -or
                $_.MainWindowTitle -like "*test*"
            )
        }

    $vstestProcesses = Get-Process -Name "vstest*" -ErrorAction SilentlyContinue | 
        Where-Object { $_.Id -notin $KnownProcesses.Id }

    $allProcesses = $dotnetProcesses + $vstestProcesses

    if ($allProcesses) {
        Write-Host "Found $($allProcesses.Count) remaining test runner processes - killing..." -ForegroundColor Yellow
        foreach ($proc in $allProcesses) {
            try {
                Write-Host "  Killing process ID: $($proc.Id) - $($proc.ProcessName)" -ForegroundColor Gray
                $proc.Kill()
                $proc.WaitForExit(2000)
                $proc.Dispose()
            } catch {
                Write-Host "  Failed to kill process ID: $($proc.Id) - $_" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "No remaining test runner processes found." -ForegroundColor Green
    }
}

#endregion

#region Main Script

# Validate dotnet is available
try {
    $dotnetPath = (Get-Command dotnet -ErrorAction Stop).Source
    Write-Host "Using dotnet from: $dotnetPath" -ForegroundColor Gray
} catch {
    Write-Error "dotnet CLI is not available. Please install .NET SDK."
    exit 1
}

# Ensure output directory exists
if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

# Generate unique timestamp for this run
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$nunitReportPath = Join-Path -Path $OutputDirectory -ChildPath "nunit_results_$timestamp.xml"

# Build dotnet test arguments
$dotnetArgs = @(
    "test",
    $AssemblyPattern,
    "--logger:nunit;LogFilePath=$nunitReportPath;LogLevel=Info",
    "--no-build",
    "--verbosity:normal"
)

if ($EnableCoverage) {
    $dotnetArgs += @(
        "--collect:"XPlat Code Coverage"",
        "--settings:coverlet.runsettings"
    )
    # Create coverlet settings if not present
    $runsettingsPath = "./coverlet.runsettings"
    if (-not (Test-Path -Path $runsettingsPath)) {
        Write-Host "Creating coverlet.runsettings for coverage collection..." -ForegroundColor Gray
        @{
            "DataCollectionRunSettings" = @{
                "DataCollectors" = @(
                    @{
                        "dataCollectorFriendlyName" = "XPlat code coverage"
                        "configuration" = @{
                            "format" = "cobertura,json"
                            "include" = @("[*.]*")
                            "exclude" = @("[*.Tests]*", "[*.]Program", "[*.]Startup")
                        }
                    }
                )
            }
        } | ConvertTo-Json -Depth 10 | Out-File -FilePath $runsettingsPath -Encoding UTF8
    }
}

Write-Host "Starting dotnet test with NUnit 3 reporting..." -ForegroundColor Cyan
Write-Host "Assembly Pattern: $AssemblyPattern" -ForegroundColor Gray
Write-Host "Timeout: $TimeoutSeconds seconds" -ForegroundColor Gray
Write-Host "Coverage Enabled: $EnableCoverage" -ForegroundColor Gray
Write-Host "NUnit Report: $nunitReportPath" -ForegroundColor Gray
Write-Host ""

# Track all processes we start
$startedProcesses = @()
$exitCode = 0

try {
    # Start dotnet test process
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = "dotnet"
    $processInfo.Arguments = $dotnetArgs -join " "
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo

    # Event handlers for real-time output
    $outputHandler = [System.EventHandler[System.Diagnostics.DataReceivedEventArgs]]{
        param($sender, $e)
        if ($e.Data -ne $null) {
            # Color code output based on content
            if ($e.Data -match "Passed!|PASS|Success") {
                Write-Host $e.Data -ForegroundColor Green
            } elseif ($e.Data -match "Failed!|FAIL|Error") {
                Write-Host $e.Data -ForegroundColor Red
            } elseif ($e.Data -match "Skipped!|SKIP") {
                Write-Host $e.Data -ForegroundColor Yellow
            } else {
                Write-Host $e.Data -ForegroundColor White
            }
        }
    }

    $errorHandler = [System.EventHandler[System.Diagnostics.DataReceivedEventArgs]]{
        param($sender, $e)
        if ($e.Data -ne $null) {
            Write-Host $e.Data -ForegroundColor Red
        }
    }

    $process.add_OutputDataReceived($outputHandler)
    $process.add_ErrorDataReceived($errorHandler)

    $process.Start() | Out-Null
    $startedProcesses += $process

    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()

    # Wait for process to complete or timeout
    Write-Host "Running tests... (Timeout: $TimeoutSeconds seconds)" -ForegroundColor Cyan
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)

    if (-not $completed) {
        Write-Host "`n[TIMEOUT] Test runner exceeded $TimeoutSeconds seconds - killing process..." -ForegroundColor Yellow
        $process.Kill()
        $process.WaitForExit(5000) # Give it 5 seconds to clean up
        $exitCode = -1
    } else {
        $exitCode = $process.ExitCode
    }

    # Clean up event handlers
    $process.remove_OutputDataReceived($outputHandler)
    $process.remove_ErrorDataReceived($errorHandler)

    $process.Dispose()

} catch {
    Write-Host "Error starting test runner: $_" -ForegroundColor Red
    $exitCode = -2
}

# Parse and display results
Write-Host "`nParsing NUnit report..." -ForegroundColor Cyan
$results = Get-NUnitTestResults -XmlPath $nunitReportPath
Show-TestResults -Results $results -ShowIndividual $true

# Cleanup: Kill any remaining test runner processes
Kill-RemainingTestRunners -KnownProcesses $startedProcesses

# Final status
Write-Host ""
if ($exitCode -eq 0 -and $results.Failed -eq 0) {
    Write-Host "All tests completed successfully!" -ForegroundColor Green
    exit 0
} elseif ($exitCode -eq -1) {
    Write-Host "Tests timed out!" -ForegroundColor Yellow
    exit 1
} elseif ($results.Failed -gt 0) {
    Write-Host "Tests completed with $($results.Failed) failure(s)!" -ForegroundColor Red
    exit 1
} else {
    Write-Host "Tests completed with exit code: $exitCode" -ForegroundColor Yellow
    exit $exitCode
}

#endregion
