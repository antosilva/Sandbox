
# Exploration test, may not work

param (
    [Parameter(Mandatory=$true)]
    [string]$AssemblyPattern,

    [Parameter(Mandatory=$false)]
    [string]$Category = "",

    [Parameter(Mandatory=$false)]
    [int]$TimeoutMinutes = 10,

    [Parameter(Mandatory=$false)]
    [switch]$EnableCoverage,

    [Parameter(Mandatory=$false)]
    [string]$CoverageFile = "coverlet.xml"
)

# Function to stop a process tree
function Stop-ProcessTree {
    param (
        [System.Diagnostics.Process]$Process,
        [bool]$Force
    )

    if ($null -eq $Process) { return }

    try {
        if ($Force) {
            $Process.Kill()
        } else {
            $Process.CloseMainWindow() | Out-Null
        }
    } catch {
        Write-Warning "Failed to stop process $($Process.Id): $_"
    }

    $children = Get-ChildProcess -ParentId $Process.Id
    foreach ($child in $children) {
        Stop-ProcessTree -Process $child -Force:$Force
    }
}

# Function to get child processes
function Get-ChildProcess {
    param ([int]$ParentId)
    Get-WmiObject Win32_Process -Filter "ParentProcessId = $ParentId" | ForEach-Object {
        $process = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
        if ($process) { $process }
    }
}

# Function to parse and display real-time test output
function Parse-TestOutput {
    param ([string]$Line)

    if ($Line -match "Test run for (.+)\.dll") {
        Write-Host "--- Assembly: $($matches[1])" -ForegroundColor Cyan
    }
    elseif ($Line -match "  Passed: (\d+)") {
        Write-Host "  [PASS] $($matches[1])" -ForegroundColor Green
    }
    elseif ($Line -match "  Failed: (\d+)") {
        Write-Host "  [FAIL] $($matches[1])" -ForegroundColor Red
    }
    elseif ($Line -match "  Skipped: (\d+)") {
        Write-Host "  [SKIP] $($matches[1])" -ForegroundColor Yellow
    }
    elseif ($Line -match "  Total: (\d+)") {
        Write-Host "  Total: $($matches[1])" -ForegroundColor White
    }
    elseif ($Line -match "  Category: (.+)") {
        Write-Host "  Category: $($matches[1])" -ForegroundColor Magenta
    }
    elseif ($Line -match "  (.+)\s+\[(.+)\]") {
        Write-Host "  $($matches[1]) [$($matches[2])]" -ForegroundColor Gray
    }
}

# Function to generate a summary
function Publish-Summary {
    param ([string]$LogPath)

    if (-not (Test-Path $LogPath)) {
        Write-Warning "Log file not found: $LogPath"
        return
    }

    $logContent = Get-Content $LogPath -Raw
    $assemblies = @{}
    $categories = @{}

    $logContent -split "`r`n" | ForEach-Object {
        if ($_ -match "Test run for (.+)\.dll") {
            $currentAssembly = $matches[1]
            $assemblies[$currentAssembly] = @{ Passed=0; Failed=0; Skipped=0; Total=0 }
        }
        elseif ($_ -match "  Passed: (\d+)") {
            $assemblies[$currentAssembly].Passed += [int]$matches[1]
            if ($currentCategory) {
                $categories[$currentCategory].Passed += [int]$matches[1]
            }
        }
        elseif ($_ -match "  Failed: (\d+)") {
            $assemblies[$currentAssembly].Failed += [int]$matches[1]
            if ($currentCategory) {
                $categories[$currentCategory].Failed += [int]$matches[1]
            }
        }
        elseif ($_ -match "  Skipped: (\d+)") {
            $assemblies[$currentAssembly].Skipped += [int]$matches[1]
            if ($currentCategory) {
                $categories[$currentCategory].Skipped += [int]$matches[1]
            }
        }
        elseif ($_ -match "  Total: (\d+)") {
            $assemblies[$currentAssembly].Total += [int]$matches[1]
            if ($currentCategory) {
                $categories[$currentCategory].Total += [int]$matches[1]
            }
        }
        elseif ($_ -match "  Category: (.+)") {
            $currentCategory = $matches[1]
            if (-not $categories.ContainsKey($currentCategory)) {
                $categories[$currentCategory] = @{ Passed=0; Failed=0; Skipped=0; Total=0 }
            }
        }
    }

    Write-Host "`n--- Summary by Assembly ---" -ForegroundColor Cyan
    $assemblies.GetEnumerator() | Sort-Object Name | ForEach-Object {
        $assembly = $_.Key
        $stats = $_.Value
        Write-Host ($assembly + ": Passed=" + $stats.Passed + ", Failed=" + $stats.Failed + ", Skipped=" + $stats.Skipped + ", Total=" + $stats.Total)
    }

    Write-Host "`n--- Summary by Category ---" -ForegroundColor Cyan
    $categories.GetEnumerator() | Sort-Object Name | ForEach-Object {
        $category = $_.Key
        $stats = $_.Value
        Write-Host ($category + ": Passed=" + $stats.Passed + ", Failed=" + $stats.Failed + ", Skipped=" + $stats.Skipped + ", Total=" + $stats.Total)
    }
}

# Main script
$ErrorActionPreference = "Stop"

if ($EnableCoverage) {
    $coveragePath = if ([System.IO.Path]::IsPathRooted($CoverageFile)) {
        $CoverageFile
    } else {
        Join-Path (Get-Location) $CoverageFile
    }

    $coverageDir = Split-Path -Parent $coveragePath
    if ($coverageDir -and -not (Test-Path $coverageDir)) {
        New-Item -ItemType Directory -Path $coverageDir -Force | Out-Null
    }

    if (-not (Test-Path $coveragePath)) {
        @"
<?xml version="1.0" encoding="utf-8"?>
<coverage line-rate="0" branch-rate="0" version="1" timestamp="0">
  <sources />
  <packages />
</coverage>
"@ | Set-Content -Path $coveragePath -Encoding UTF8
    }

    Write-Host "Generating Coverlet file: $coveragePath" -ForegroundColor Yellow
}

$dotnetArgs = @(
    "test",
    "--logger:nunit",
    "--no-build"
)

if ($AssemblyPattern) {
    $dotnetArgs += @(
        "--filter",
        "FullyQualifiedName~$AssemblyPattern"
    )
}

if ($Category) {
    $dotnetArgs += @(
        "--filter",
        "TestCategory=$Category"
    )
}

if ($EnableCoverage) {
    $dotnetArgs += @(
        "/p:CollectCoverage=true",
        "/p:CoverageOutput=$CoverageFile"
    )
}

$dotnetArgs = $dotnetArgs -join " "

Write-Host "Starting dotnet test with args: $dotnetArgs" -ForegroundColor Yellow
$processInfo = New-Object System.Diagnostics.ProcessStartInfo
$processInfo.FileName = "dotnet"
$processInfo.Arguments = $dotnetArgs
$processInfo.RedirectStandardOutput = $true
$processInfo.RedirectStandardError = $true
$processInfo.UseShellExecute = $false
$processInfo.CreateNoWindow = $true

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $processInfo

$outputReader = $process.StandardOutput
$errorReader = $process.StandardError

$outputJob = Start-Job -ScriptBlock {
    param($reader)
    while (($line = $reader.ReadLine()) -ne $null) {
        Parse-TestOutput -Line $line
    }
} -ArgumentList $outputReader

$errorJob = Start-Job -ScriptBlock {
    param($reader)
    while (($line = $reader.ReadLine()) -ne $null) {
        Write-Host ("ERROR: " + $line) -ForegroundColor Red
    }
} -ArgumentList $errorReader

$process.Start() | Out-Null

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$timeout = [TimeSpan]::FromMinutes($TimeoutMinutes)
$timedOut = $false


while (-not $process.HasExited) {
    if ($stopwatch.Elapsed -ge $timeout) {
        $timeoutMessage = "Timeout reached (" + $TimeoutMinutes + " minutes). Stopping process..."
        Write-Host $timeoutMessage -ForegroundColor Red
        Stop-ProcessTree -Process $process -Force:$false
        Start-Sleep -Seconds 5
        if (-not $process.HasExited) {
            Write-Host "Process did not stop gracefully. Killing..." -ForegroundColor Red
            Stop-ProcessTree -Process $process -Force:$true
        }
        $timedOut = $true
        break
    }
    Start-Sleep -Milliseconds 100
}

Stop-Job $outputJob -ErrorAction SilentlyContinue
Stop-Job $errorJob -ErrorAction SilentlyContinue
Remove-Job $outputJob -ErrorAction SilentlyContinue
Remove-Job $errorJob -ErrorAction SilentlyContinue

$outputReader.Close()
$errorReader.Close()

if (-not $timedOut) {
    Publish-Summary -LogPath "TestResults.xml"
}

if ($timedOut) {
    Write-Host "Tests timed out." -ForegroundColor Red
    exit 1
}
elseif ($process.ExitCode -ne 0) {
    Write-Host ("Tests failed with exit code: " + $process.ExitCode) -ForegroundColor Red
    exit $process.ExitCode
}
else {
    Write-Host "Tests completed successfully." -ForegroundColor Green
    exit 0
}
