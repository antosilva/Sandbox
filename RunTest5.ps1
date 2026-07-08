
#Exploration test, may not work

<#
.SYNOPSIS
    Runs .NET (C#) test assemblies through "dotnet test" for a Jenkins pipeline, producing
    NUnit-format XML reports, with assembly/Category filtering, an async runner bounded by a
    per-assembly timeout (soft stop -> hard kill of the whole process tree), live streaming of
    individual test statuses, optional coverlet code coverage, and a final summary of results
    grouped by assembly and by NUnit Category.

.DESCRIPTION
    1. Discovers test assemblies under -TestAssembliesRoot whose file name matches the
       wildcard -AssemblyPattern (e.g. "*.Tests.dll"), ignoring anything under an "obj" folder.
    2. For each matched assembly, launches "dotnet test <assembly>" asynchronously
       (System.Diagnostics.Process, non-blocking Start()), streaming each test's
       Passed/Failed/Skipped status to the console as it happens via
       --logger "console;verbosity=detailed", while simultaneously writing an NUnit-format
       XML report via --logger "nunit;LogFilePath=...". The nunit logger requires the
       NunitXml.TestLogger NuGet package to be referenced by the test project.
    3. If -Category is supplied, only test cases whose class/method carries a matching NUnit
       [Category] attribute are executed (--filter "Category=A|Category=B|...").
    4. The runner is bounded by -TimeoutMinutes. On timeout it is first asked to stop
       gracefully, given -SoftKillGraceSeconds to exit, then force-killed together with
       every child process it spawned (testhost, etc.).
    5. If -Coverage is supplied, code coverage is collected via the coverlet "XPlat Code
       Coverage" data collector (requires the coverlet.collector NuGet package on the test
       project). A runsettings file at -CoverletSettingsPath configures the collector; if it
       does not already exist, a default one is generated.
    6. After every assembly has run, all generated NUnit XML reports are parsed and a summary
       is printed and exported to CSV: totals by assembly, totals by Category, and the
       runner's own exit status (Success / Failed / TimedOut) per assembly.

Jenkins snippet:
    stage('Test') {
        steps {
            powershell './Invoke-DotnetTests.ps1 -TestAssembliesRoot "$env:WORKSPACE\\artifacts" -AssemblyPattern "*.Tests.dll" -TimeoutMinutes 30 -Coverage'
        }
    }
    post {
        always {
            nunit testResultsPattern: 'TestResults/NUnit/*.xml'
        }
    }

.PARAMETER TestAssembliesRoot
    Folder to search recursively for compiled test assemblies.

.PARAMETER AssemblyPattern
    Wildcard (not regex) used to match assembly file names, e.g. "*.Tests.dll".

.PARAMETER Category
    One or more NUnit Category values to filter on (OR'ed together). Omit to run every test.

.PARAMETER ResultsDirectory
    Folder where NUnit XML reports, coverage reports and summary CSVs are written.

.PARAMETER TimeoutMinutes
    Per-assembly timeout, in minutes, before the runner is stopped.

.PARAMETER SoftKillGraceSeconds
    Seconds given to the runner to exit after a graceful stop request before it is force-killed.

.PARAMETER Coverage
    Switch. Enables coverlet "XPlat Code Coverage" collection.

.PARAMETER CoverletSettingsPath
    Path to the coverlet runsettings file. Generated with sensible defaults if missing.

.PARAMETER DotnetTestExtraArgs
    Extra raw arguments appended verbatim to every "dotnet test" invocation.

.EXAMPLE
    ./Invoke-DotnetTests.ps1 -TestAssembliesRoot .\artifacts -AssemblyPattern "*.Tests.dll" `
        -Category Smoke, Regression -TimeoutMinutes 20 -Coverage

.NOTES
    - Requires PowerShell 7+ (uses Process.Kill($true) for cross-platform process-tree kill).
    - Requires the NunitXml.TestLogger NuGet package on each test project (for the "nunit" logger).
    - Requires the coverlet.collector NuGet package on each test project when -Coverage is used.
    - On Windows, the "soft stop" is a best-effort request (taskkill without /F). A windowless
      console process frequently cannot honor it, in which case the hard kill after the grace
      period takes over. That is expected behavior, not a bug.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TestAssembliesRoot,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AssemblyPattern,

    [string[]]$Category = @(),

    [ValidateNotNullOrEmpty()]
    [string]$ResultsDirectory = './TestResults',

    [ValidateRange(1, 1440)]
    [int]$TimeoutMinutes = 30,

    [ValidateRange(1, 600)]
    [int]$SoftKillGraceSeconds = 20,

    [switch]$Coverage,

    [string]$CoverletSettingsPath = './coverlet.runsettings',

    [string[]]$DotnetTestExtraArgs = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ======================================================================
# Helper functions
# ======================================================================

function Resolve-PathSafe {
    # Resolves a relative or absolute path against PowerShell's own current location,
    # WITHOUT requiring the path to already exist (Resolve-Path cannot do that).
    param([Parameter(Mandatory)][string]$Path)
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Write-TestStatusLine {
    # Colorizes the per-test lines produced by --logger "console;verbosity=detailed"
    # as they stream in, so pass/fail/skip is visible live instead of only at the end.
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return }

    switch -Regex ($Line) {
        '^\s*Passed!'   { Write-Host $Line -ForegroundColor Green;  break }
        '^\s*Failed!'   { Write-Host $Line -ForegroundColor Red;    break }
        '^\s*Passed\s'  { Write-Host $Line -ForegroundColor Green;  break }
        '^\s*Failed\s'  { Write-Host $Line -ForegroundColor Red;    break }
        '^\s*Skipped\s' { Write-Host $Line -ForegroundColor Yellow; break }
        default         { Write-Host $Line }
    }
}

function Initialize-CoverletSettings {
    # Generates a default coverlet ("XPlat Code Coverage") runsettings file if one
    # does not already exist at the given path. Idempotent - leaves an existing file alone.
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Write-Host "Coverlet settings file found: $Path" -ForegroundColor DarkCyan
        return
    }

    Write-Host "Coverlet settings file not found. Generating default: $Path" -ForegroundColor DarkCyan

    $defaultSettings = @'
<?xml version="1.0" encoding="utf-8"?>
<RunSettings>
  <DataCollectionRunSettings>
    <DataCollectors>
      <DataCollector friendlyName="XPlat code coverage">
        <Configuration>
          <Format>cobertura</Format>
          <Exclude>[*.Tests]*,[*.Test]*,[*Tests]*</Exclude>
          <ExcludeByAttribute>Obsolete,GeneratedCodeAttribute,CompilerGeneratedAttribute</ExcludeByAttribute>
          <SkipAutoProps>true</SkipAutoProps>
          <IncludeTestAssembly>false</IncludeTestAssembly>
        </Configuration>
      </DataCollector>
    </DataCollectors>
  </DataCollectionRunSettings>
</RunSettings>
'@

    $settingsDir = Split-Path -Path $Path -Parent
    if ($settingsDir -and -not (Test-Path -LiteralPath $settingsDir)) {
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
    }

    Set-Content -LiteralPath $Path -Value $defaultSettings -Encoding UTF8
}

function Stop-RunnerProcessTree {
    # Soft: best-effort graceful stop request (does not block).
    # Hard: force-kills the process AND every descendant (testhost, etc.).
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][ValidateSet('Soft', 'Hard')][string]$Mode
    )

    if ($Process.HasExited) { return }
    $targetProcessId = $Process.Id

    if ($Mode -eq 'Soft') {
        try {
            if ($IsWindows) {
                # Best effort only: a console process with no window frequently cannot
                # honor this, and taskkill will report it can only be force-terminated.
                # That is expected - the hard-kill fallback after the grace period covers it.
                & taskkill.exe /PID $targetProcessId *>$null
            } else {
                & kill -TERM $targetProcessId *>$null
            }
        } catch {
            Write-Verbose "Soft stop signal could not be delivered (will hard-kill if still running): $_"
        }
        return
    }

    try {
        $Process.Kill($true)   # PowerShell 7+ / .NET Core 3+: kills the process and every descendant
    } catch {
        Write-Verbose "Process.Kill(`$true) failed, falling back to OS-level tree kill: $_"
        if ($IsWindows) {
            & taskkill.exe /PID $targetProcessId /T /F *>$null
        } else {
            try { & pkill -KILL -P $targetProcessId *>$null } catch { }
            try { & kill -KILL $targetProcessId *>$null } catch { }
        }
    }
}

function Invoke-DotnetTestRunner {
    # Starts "dotnet <ArgumentList>" asynchronously, streams stdout/stderr live while
    # polling a stopwatch against $TimeoutMinutes, and on timeout stops the process tree
    # softly, then hard, per Stop-RunnerProcessTree.
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$ArgumentList,
        [Parameter(Mandatory)][int]$TimeoutMinutes,
        [Parameter(Mandatory)][int]$SoftKillGraceSeconds,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new('dotnet')
    $psi.Arguments              = $ArgumentList -join ' '
    $psi.WorkingDirectory       = $WorkingDirectory
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    Write-Host ">> dotnet $($ArgumentList -join ' ')" -ForegroundColor Cyan

    $started = $proc.Start()       # <-- async / non-blocking start of the runner
    if (-not $started) { throw "Failed to start the dotnet test process." }

    $outTask = $proc.StandardOutput.ReadLineAsync()
    $errTask = $proc.StandardError.ReadLineAsync()

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut  = $false

    # --- wait for completion while streaming test statuses live, bounded by the timeout ---
    while (-not $proc.HasExited) {

        if ($null -ne $outTask -and $outTask.IsCompleted) {
            $line = $outTask.Result
            if ($null -ne $line) {
                Write-TestStatusLine -Line $line
                $outTask = $proc.StandardOutput.ReadLineAsync()
            } else {
                $outTask = $null
            }
        }

        if ($null -ne $errTask -and $errTask.IsCompleted) {
            $eline = $errTask.Result
            if ($null -ne $eline) {
                Write-Host $eline -ForegroundColor Red
                $errTask = $proc.StandardError.ReadLineAsync()
            } else {
                $errTask = $null
            }
        }

        if ($stopwatch.Elapsed.TotalMinutes -ge $TimeoutMinutes) {
            $timedOut = $true
            break
        }

        Start-Sleep -Milliseconds 100
    }

    if ($timedOut) {
        Write-Warning "Timeout of $TimeoutMinutes minute(s) reached (PID $($proc.Id)). Requesting graceful stop..."
        Stop-RunnerProcessTree -Process $proc -Mode Soft

        $graceDeadline = (Get-Date).AddSeconds($SoftKillGraceSeconds)
        while (-not $proc.HasExited -and (Get-Date) -lt $graceDeadline) {
            Start-Sleep -Milliseconds 250
        }

        if (-not $proc.HasExited) {
            Write-Warning "Still running after ${SoftKillGraceSeconds}s grace period. Force killing the process tree..."
            Stop-RunnerProcessTree -Process $proc -Mode Hard
        } else {
            Write-Host "Runner exited gracefully after the soft stop request." -ForegroundColor Green
        }
    } else {
        # Natural completion: drain whatever is still buffered so the final summary line isn't lost.
        while ($null -ne $outTask -or $null -ne $errTask) {
            if ($null -ne $outTask) {
                if (-not $outTask.IsCompleted) { $outTask.Wait(2000) | Out-Null }
                if ($outTask.IsCompleted) {
                    $line = $outTask.Result
                    if ($null -ne $line) {
                        Write-TestStatusLine -Line $line
                        $outTask = $proc.StandardOutput.ReadLineAsync()
                    } else { $outTask = $null }
                } else { $outTask = $null }
            }
            if ($null -ne $errTask) {
                if (-not $errTask.IsCompleted) { $errTask.Wait(2000) | Out-Null }
                if ($errTask.IsCompleted) {
                    $eline = $errTask.Result
                    if ($null -ne $eline) {
                        Write-Host $eline -ForegroundColor Red
                        $errTask = $proc.StandardError.ReadLineAsync()
                    } else { $errTask = $null }
                } else { $errTask = $null }
            }
        }
    }

    if (-not $proc.HasExited) { $proc.WaitForExit(15000) | Out-Null }

    [PSCustomObject]@{
        ExitCode = if ($proc.HasExited) { $proc.ExitCode } else { -1 }
        TimedOut = $timedOut
        Duration = $stopwatch.Elapsed
    }
}

function Get-NUnitResultStats {
    # Parses one NUnit3-format XML report into one row per (test-case x Category),
    # so a test with two [Category] attributes counts once in each category's totals.
    param(
        [Parameter(Mandatory)][string]$ReportPath,
        [Parameter(Mandatory)][string]$AssemblyLabel
    )

    if (-not (Test-Path -LiteralPath $ReportPath)) {
        Write-Warning "NUnit report not found, skipped in summary: $ReportPath"
        return , @()
    }

    [xml]$doc = Get-Content -LiteralPath $ReportPath -Raw
    $cases = $doc.SelectNodes('//test-case')

    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($case in $cases) {
        $resultAttr = $case.Attributes['result']
        $result = if ($resultAttr) { $resultAttr.Value } else { 'Unknown' }

        $durationAttr = $case.Attributes['duration']
        $duration = 0.0
        if ($durationAttr) { [double]::TryParse($durationAttr.Value, [ref]$duration) | Out-Null }

        $categoryNodes = $case.SelectNodes("./properties/property[@name='Category']")
        $categories = @()
        foreach ($cn in $categoryNodes) {
            $valueAttr = $cn.Attributes['value']
            if ($valueAttr) { $categories += $valueAttr.Value }
        }
        if ($categories.Count -eq 0) { $categories = @('Uncategorized') }

        foreach ($cat in $categories) {
            $rows.Add([PSCustomObject]@{
                Assembly = $AssemblyLabel
                Category = $cat
                Result   = $result
                Duration = $duration
            })
        }
    }

    return , $rows
}

function Get-GroupedStats {
    # Turns Group-Object output into ordered summary rows: Total / Passed / Failed / Skipped / DurationSec.
    param(
        [Parameter(Mandatory)]$Groups,
        [Parameter(Mandatory)][string]$KeyName
    )

    foreach ($grp in @($Groups)) {
        $items = if ($grp.PSObject.Properties.Name -contains 'Group') { @($grp.Group) } else { @($grp) }
        $obj = [ordered]@{}
        $obj[$KeyName]      = $grp.Name
        $obj['Total']       = @($items).Count
        $obj['Passed']      = @($items | Where-Object { $_.Result -eq 'Passed' }).Count
        $obj['Failed']      = @($items | Where-Object { $_.Result -eq 'Failed' }).Count
        $obj['Skipped']     = @($items | Where-Object { $_.Result -in @('Skipped', 'Ignored') }).Count
        $obj['DurationSec'] = [math]::Round((@($items | Measure-Object -Property Duration -Sum)).Sum, 2)
        [PSCustomObject]$obj
    }
}

function Write-SummaryReport {
    # Prints and exports the global by-assembly and by-Category summaries.
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Rows,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    if ($Rows.Count -eq 0) {
        Write-Warning "No test-case results were parsed; skipping summary tables."
        return [PSCustomObject]@{ Total = 0; Passed = 0; Failed = 0; Skipped = 0 }
    }

    $byAssembly = Get-GroupedStats -Groups ($Rows | Group-Object Assembly) -KeyName 'Assembly' | Sort-Object Assembly
    $byCategory = Get-GroupedStats -Groups ($Rows | Group-Object Category) -KeyName 'Category' | Sort-Object Category

    Write-Host ""
    Write-Host "================ SUMMARY BY ASSEMBLY ================" -ForegroundColor Cyan
    Write-Host (($byAssembly | Format-Table -AutoSize | Out-String).Trim())

    Write-Host ""
    Write-Host "================ SUMMARY BY CATEGORY ================" -ForegroundColor Cyan
    Write-Host (($byCategory | Format-Table -AutoSize | Out-String).Trim())

    $grandTotal   = $Rows.Count
    $grandPassed  = @($Rows | Where-Object { $_.Result -eq 'Passed' }).Count
    $grandFailed  = @($Rows | Where-Object { $_.Result -eq 'Failed' }).Count
    $grandSkipped = @($Rows | Where-Object { $_.Result -in @('Skipped', 'Ignored') }).Count

    Write-Host ""
    Write-Host "================ GRAND TOTAL ================" -ForegroundColor Cyan
    $summaryColor = if ($grandFailed -gt 0) { 'Red' } else { 'Green' }
    Write-Host ("Total: {0}   Passed: {1}   Failed: {2}   Skipped: {3}" -f $grandTotal, $grandPassed, $grandFailed, $grandSkipped) -ForegroundColor $summaryColor

    $byAssembly | Export-Csv -Path (Join-Path $OutputDirectory 'summary-by-assembly.csv') -NoTypeInformation -Encoding UTF8
    $byCategory | Export-Csv -Path (Join-Path $OutputDirectory 'summary-by-category.csv') -NoTypeInformation -Encoding UTF8

    [PSCustomObject]@{
        Total   = $grandTotal
        Passed  = $grandPassed
        Failed  = $grandFailed
        Skipped = $grandSkipped
    }
}

# ======================================================================
# Main
# ======================================================================

try {
    $ResultsDirectory = Resolve-PathSafe -Path $ResultsDirectory
    $nunitDir    = Join-Path $ResultsDirectory 'NUnit'
    $coverageDir = Join-Path $ResultsDirectory 'Coverage'

    foreach ($dir in @($ResultsDirectory, $nunitDir, $coverageDir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ($Coverage) {
        $CoverletSettingsPath = Resolve-PathSafe -Path $CoverletSettingsPath
        Initialize-CoverletSettings -Path $CoverletSettingsPath
    }

    if (-not (Test-Path -LiteralPath $TestAssembliesRoot)) {
        throw "TestAssembliesRoot path does not exist: $TestAssembliesRoot"
    }

    Write-Host "Discovering test assemblies under '$TestAssembliesRoot' matching '$AssemblyPattern'..." -ForegroundColor Cyan

    $assemblies = @(
        Get-ChildItem -Path $TestAssembliesRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $AssemblyPattern -and $_.FullName -notmatch '[\\/]obj[\\/]' }
    )

    if ($assemblies.Count -eq 0) {
        throw "No test assemblies found matching pattern '$AssemblyPattern' under '$TestAssembliesRoot'."
    }

    Write-Host "Found $($assemblies.Count) test assembly(ies):" -ForegroundColor Cyan
    $assemblies | ForEach-Object { Write-Host "  - $($_.FullName)" }

    $allRows      = [System.Collections.Generic.List[object]]::new()
    $runSummaries = [System.Collections.Generic.List[object]]::new()
    $anyTimedOut   = $false
    $anyFailedExit = $false

    foreach ($asm in $assemblies) {
        $label        = $asm.BaseName
        $nunitXmlPath = Join-Path $nunitDir "${label}.xml"

        Write-Host ""
        Write-Host "=========================================================" -ForegroundColor Magenta
        Write-Host " Running tests: $label" -ForegroundColor Magenta
        Write-Host "=========================================================" -ForegroundColor Magenta

        $argList = [System.Collections.Generic.List[string]]::new()
        $argList.Add('test')
        $argList.Add($asm.FullName)
        $argList.Add('--nologo')
        $argList.Add('--logger'); $argList.Add('console;verbosity=detailed')
        $argList.Add('--logger'); $argList.Add("nunit;LogFilePath=$nunitXmlPath")
        $argList.Add('--results-directory'); $argList.Add($ResultsDirectory)

        if ($Category -and $Category.Count -gt 0) {
            $filterExpr = ($Category | ForEach-Object { "Category=$_" }) -join '|'
            $argList.Add('--filter'); $argList.Add($filterExpr)
        }

        if ($Coverage) {
            $argList.Add('--collect'); $argList.Add('XPlat Code Coverage')
            $argList.Add('--settings'); $argList.Add($CoverletSettingsPath)
        }

        foreach ($extra in $DotnetTestExtraArgs) { $argList.Add($extra) }

        $runResult = Invoke-DotnetTestRunner -ArgumentList $argList -TimeoutMinutes $TimeoutMinutes `
            -SoftKillGraceSeconds $SoftKillGraceSeconds -WorkingDirectory $asm.DirectoryName

        $status = if ($runResult.TimedOut) { 'TimedOut' } elseif ($runResult.ExitCode -eq 0) { 'Success' } else { 'Failed' }

        $runSummaries.Add([PSCustomObject]@{
            Assembly    = $label
            Status      = $status
            ExitCode    = $runResult.ExitCode
            DurationMin = [math]::Round($runResult.Duration.TotalMinutes, 2)
        })

        if ($runResult.TimedOut) {
            $anyTimedOut = $true
            Write-Warning "$label timed out after $TimeoutMinutes minute(s) and was terminated."
        } elseif ($runResult.ExitCode -ne 0) {
            $anyFailedExit = $true
            Write-Warning "$label finished with a non-zero exit code ($($runResult.ExitCode))."
        } else {
            Write-Host "$label completed successfully." -ForegroundColor Green
        }

        $allRows.AddRange((Get-NUnitResultStats -ReportPath $nunitXmlPath -AssemblyLabel $label))

        if ($Coverage) {
            $generatedCoverage = Get-ChildItem -Path $ResultsDirectory -Recurse -Filter 'coverage.cobertura.xml' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($generatedCoverage) {
                $destination = Join-Path $coverageDir "${label}.cobertura.xml"
                Copy-Item -Path $generatedCoverage.FullName -Destination $destination -Force
                Write-Host "Coverage report copied to: $destination" -ForegroundColor DarkCyan
            } else {
                Write-Warning "Coverage was requested but no coverage.cobertura.xml was produced for $label."
            }
        }
    }

    Write-Host ""
    Write-Host "================ RUNNER STATUS ================" -ForegroundColor Cyan
    Write-Host (($runSummaries | Format-Table -AutoSize | Out-String).Trim())
    $runSummaries | Export-Csv -Path (Join-Path $ResultsDirectory 'runner-status.csv') -NoTypeInformation -Encoding UTF8

    $totals = Write-SummaryReport -Rows $allRows -OutputDirectory $ResultsDirectory

    if ($anyTimedOut -or $anyFailedExit -or $totals.Failed -gt 0) {
        Write-Host ""
        Write-Host "Result: FAILURE" -ForegroundColor Red
        exit 1
    } else {
        Write-Host ""
        Write-Host "Result: SUCCESS" -ForegroundColor Green
        exit 0
    }
}
catch {
    Write-Host ""
    Write-Host "FATAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed }
    exit 1
}
