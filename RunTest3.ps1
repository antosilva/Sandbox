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

.PARAMETER Category
    One or more NUnit test categories to filter by. If provided, tests will be run separately for each category
    and a separate NUnit report file will be created per category. If not provided, all tests are run with a single report.

.EXAMPLE
    .\run-nunit-tests.ps1 -AssemblyPattern "**/*Tests.dll" -TimeoutSeconds 600 -EnableCoverage

.EXAMPLE
    .\run-nunit-tests.ps1 -AssemblyPattern "MyApp.Tests.dll" -TimeoutSeconds 120

.EXAMPLE
    .\run-nunit-tests.ps1 -AssemblyPattern "*.Tests.dll" -EnableCoverage

.EXAMPLE
    .\run-nunit-tests.ps1 -AssemblyPattern "*.Tests.dll" -Category "Integration","Smoke"

.EXAMPLE
    .\run-nunit-tests.ps1 -AssemblyPattern "*.Tests.dll" -Category "Unit"
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
    [string]$OutputDirectory = "./TestResults",

    [Parameter(Mandatory = $false)]
    [string[]]$Category
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
        [bool]$ShowIndividual = $true,
        [string]$CategoryFilter = $null
    )

    if ($CategoryFilter) {
        Write-Host (`"`n" + ("=" * 80)) -ForegroundColor DarkCyan
        Write-Host "TEST RESULTS SUMMARY [Category: $CategoryFilter]" -ForegroundColor DarkCyan
    } else {
        Write-Host (`"`n" + ("=" * 80)) -ForegroundColor DarkCyan
        Write-Host "TEST RESULTS SUMMARY" -ForegroundColor DarkCyan
    }
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
        if ($CategoryFilter) {
            Write-Host "INDIVIDUAL TEST STATUS [Category: $CategoryFilter]" -ForegroundColor DarkCyan
        } else {
            Write-Host "INDIVIDUAL TEST STATUS" -ForegroundColor DarkCyan
        }
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

function Run-SingleTest {
    param (
        [string]$AssemblyPattern,
        [int]$TimeoutSeconds,
        [switch]$EnableCoverage,
        [string]$OutputDirectory,
        [array]$DotnetArgs,
        [string]$NunitReportPath,
        [ref]$StartedProcesses,
        [string]$Category = $null,
        [ref]$AllResults
    )

    $localExitCode = 0

    try {
        # Start dotnet test process
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = "dotnet"
        $processInfo.Arguments = $DotnetArgs -join " "
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

        Write-Host "Starting test run...`n  Report: $NunitReportPath" -ForegroundColor Cyan
        if ($Category) {
            Write-Host "  Category: $Category" -ForegroundColor Gray
        }

        $process.Start() | Out-Null
        $StartedProcesses.Value += $process

        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        # Wait for process to complete or timeout
        Write-Host "Running tests... (Timeout: $TimeoutSeconds seconds)" -ForegroundColor Cyan
        $completed = $process.WaitForExit($TimeoutSeconds * 1000)

        if (-not $completed) {
            Write-Host "`n[TIMEOUT] Test runner exceeded $TimeoutSeconds seconds - killing process..." -ForegroundColor Yellow
            $process.Kill()
            $process.WaitForExit(5000)
            $localExitCode = -1
        } else {
            $localExitCode = $process.ExitCode
        }

        # Clean up event handlers
        $process.remove_OutputDataReceived($outputHandler)
        $process.remove_ErrorDataReceived($errorHandler)
        $process.Dispose()

        # Parse and display results
        Write-Host "`nParsing NUnit report...`n" -ForegroundColor Cyan
        $results = Get-NUnitTestResults -XmlPath $NunitReportPath
        $results.Category = $Category
        $AllResults.Value += $results
        Show-TestResults -Results $results -ShowIndividual $true -CategoryFilter $Category

    } catch {
        Write-Host "Error starting test runner: $_" -ForegroundColor Red
        $localExitCode = -2
    }

    return $localExitCode
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

# Create coverlet settings if coverage is enabled
if ($EnableCoverage) {
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
if ($Category -and $Category.Count -gt 0) {
    Write-Host "Categories: $($Category -join ', ')" -ForegroundColor Gray
} else {
    Write-Host "Categories: (all)" -ForegroundColor Gray
}
Write-Host "Output Directory: $OutputDirectory" -ForegroundColor Gray
Write-Host ""

# Collection for all results
$allResults = @()
$startedProcesses = @()
$exitCode = 0

# Run tests for each category or all tests
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

if ($Category -and $Category.Count -gt 0) {
    # Run tests separately for each category
    foreach ($cat in $Category) {
        $catSafeName = $cat -replace "[^a-zA-Z0-9_]", "_"
        $nunitReportPath = Join-Path -Path $OutputDirectory -ChildPath "nunit_results_${timestamp}_${catSafeName}.xml"

        $dotnetArgs = @(
            "test",
            $AssemblyPattern,
            "--logger:nunit;LogFilePath=$nunitReportPath;LogLevel=Info",
            "--no-build",
            "--verbosity:normal",
            "--filter `"`"TestCategory=$cat`"\""
        )

        if ($EnableCoverage) {
            $dotnetArgs += @(
                "--collect:`"XPlat Code Coverage`"",
                "--settings:coverlet.runsettings"
            )
        }

        Write-Host "`nProcessing category: '$cat'..." -ForegroundColor Magenta
        $currentExitCode = Run-SingleTest -AssemblyPattern $AssemblyPattern -TimeoutSeconds $TimeoutSeconds `
            -EnableCoverage $EnableCoverage -OutputDirectory $OutputDirectory -DotnetArgs $dotnetArgs `
            -NunitReportPath $nunitReportPath -StartedProcesses ([ref]$startedProcesses) `
            -Category $cat -AllResults ([ref]$allResults)

        if ($currentExitCode -ne 0 -and $exitCode -eq 0) {
            $exitCode = $currentExitCode
        }
    }
} else {
    # Run all tests without category filter
    $nunitReportPath = Join-Path -Path $OutputDirectory -ChildPath "nunit_results_$timestamp.xml"

    $dotnetArgs = @(
        "test",
        $AssemblyPattern,
        "--logger:nunit;LogFilePath=$nunitReportPath;LogLevel=Info",
        "--no-build",
        "--verbosity:normal"
    )

    if ($EnableCoverage) {
        $dotnetArgs += @(
            "--collect:`"XPlat Code Coverage`"",
            "--settings:coverlet.runsettings"
        )
    }

    $exitCode = Run-SingleTest -AssemblyPattern $AssemblyPattern -TimeoutSeconds $TimeoutSeconds `
        -EnableCoverage $EnableCoverage -OutputDirectory $OutputDirectory -DotnetArgs $dotnetArgs `
        -NunitReportPath $nunitReportPath -StartedProcesses ([ref]$startedProcesses) `
        -AllResults ([ref]$allResults)
}

# Cleanup
Kill-RemainingTestRunners -KnownProcesses $startedProcesses

# Show aggregated summary if multiple categories
if ($Category -and $Category.Count -gt 1) {
    Write-Host "`n" + ("=" * 80) -ForegroundColor DarkCyan
    Write-Host "AGGREGATED RESULTS ACROSS ALL CATEGORIES" -ForegroundColor DarkCyan
    Write-Host ("=" * 80) -ForegroundColor DarkCyan
    Write-Host ""

    $totalTotal = 0
    $totalPassed = 0
    $totalFailed = 0
    $totalSkipped = 0
    $totalInconclusive = 0

    foreach ($result in $allResults) {
        $totalTotal += $result.Total
        $totalPassed += $result.Passed
        $totalFailed += $result.Failed
        $totalSkipped += $result.Skipped
        $totalInconclusive += $result.Inconclusive
    }

    Write-Host ("Total Tests:  {0,8}" -f $totalTotal) -ForegroundColor White
    Write-Host ("Passed:       {0,8}" -f $totalPassed) -ForegroundColor Green
    Write-Host ("Failed:       {0,8}" -f $totalFailed) -ForegroundColor Red
    Write-Host ("Skipped:      {0,8}" -f $totalSkipped) -ForegroundColor Yellow
    Write-Host ("Inconclusive: {0,8}" -f $totalInconclusive) -ForegroundColor Magenta

    if ($totalTotal -gt 0) {
        $successRate = ($totalPassed / $totalTotal) * 100
        Write-Host ("Success Rate:  {0:N2}%" -f $successRate) -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor DarkCyan
}

# Final status
Write-Host ""
if ($exitCode -eq 0 -and $totalFailed -eq 0) {
    Write-Host "All tests completed successfully!" -ForegroundColor Green
    exit 0
} elseif ($exitCode -eq -1) {
    Write-Host "Tests timed out!" -ForegroundColor Yellow
    exit 1
} elseif ($totalFailed -gt 0) {
    Write-Host "Tests completed with $totalFailed failure(s)!" -ForegroundColor Red
    exit 1
} else {
    Write-Host "Tests completed with exit code: $exitCode" -ForegroundColor Yellow
    exit $exitCode
}

#endregion