<#
.SYNOPSIS
    EntraTimeline build script — Analyse, Test, Build.
.PARAMETER Task
    The task to run: Analyze, Test, Build, CI (all), Clean.
.EXAMPLE
    .\build.ps1 -Task CI
#>
param(
    [ValidateSet('Analyze', 'Test', 'UITest', 'Build', 'CI', 'Clean')]
    [string]$Task = 'CI'
)

$moduleName = 'EntraTimeline'
$buildDir   = Join-Path $PSScriptRoot 'build' $moduleName

switch ($Task) {
    'Analyze' {
        Write-Host '─── PSScriptAnalyzer ───' -ForegroundColor Cyan
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        $results = Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse -Settings "$PSScriptRoot\PSScriptAnalyzerSettings.psd1" -ExcludeRule PSUseToExportFieldsInManifest
        $results | Format-Table -AutoSize
        $errors = $results | Where-Object Severity -eq 'Error'
        if ($errors) {
            Write-Host "  ✗ $($errors.Count) error(s) found" -ForegroundColor Red
            throw 'PSScriptAnalyzer found errors'
        } else {
            Write-Host '  ✓ No errors' -ForegroundColor Green
        }
    }
    'Test' {
        Write-Host '─── Pester Tests ───' -ForegroundColor Cyan
        Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
        $config = New-PesterConfiguration
        $config.Run.Path = "$PSScriptRoot\Tests"
        $config.Run.PassThru = $true
        $config.Output.Verbosity = 'Detailed'
        $config.TestResult.Enabled = $true
        $config.TestResult.OutputPath = "$PSScriptRoot\build\TestResults.xml"

        $result = Invoke-Pester -Configuration $config
        if ($result.FailedCount -gt 0) {
            Write-Host "  ✗ $($result.FailedCount) test(s) failed" -ForegroundColor Red
            throw "Pester reported $($result.FailedCount) failure(s)"
        }
        Write-Host "  ✓ $($result.PassedCount) test(s) passed" -ForegroundColor Green
    }
    'UITest' {
        Write-Host '─── Frontend checks ───' -ForegroundColor Cyan
        $node = Get-Command node -ErrorAction SilentlyContinue
        if (-not $node) {
            Write-Host '  ! node not found — frontend checks skipped' -ForegroundColor Yellow
            return
        }

        & node (Join-Path -Path $PSScriptRoot -ChildPath 'Tests\ui-checks.js') (Join-Path -Path $PSScriptRoot -ChildPath 'Web')
        if ($LASTEXITCODE -ne 0) { throw 'Frontend checks failed' }
    }
    'Build' {
        Write-Host '─── Build ───' -ForegroundColor Cyan
        if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
        New-Item $buildDir -ItemType Directory -Force | Out-Null
        $items = @('Public', 'Private', 'Web', "$moduleName.psd1", "$moduleName.psm1")
        foreach ($item in $items) {
            $src = Join-Path $PSScriptRoot $item
            if (Test-Path $src) {
                Copy-Item $src -Destination $buildDir -Recurse -Force
            }
        }
        Write-Host "  ✓ Build output: $buildDir" -ForegroundColor Green
    }
    'CI' {
        & $PSScriptRoot\build.ps1 -Task Analyze
        & $PSScriptRoot\build.ps1 -Task Test
        & $PSScriptRoot\build.ps1 -Task UITest
        & $PSScriptRoot\build.ps1 -Task Build
    }
    'Clean' {
        $cleanDir = Join-Path $PSScriptRoot 'build'
        if (Test-Path $cleanDir) { Remove-Item $cleanDir -Recurse -Force }
        . (Join-Path $PSScriptRoot 'Private\Helpers\Get-TimelineDataRoot.ps1')
        $logsDir = Join-Path (Get-TimelineDataRoot) 'Logs'
        if (Test-Path $logsDir) { Get-ChildItem $logsDir -Filter '*.log' | Remove-Item -Force }
        Write-Host '  ✓ Cleaned.' -ForegroundColor Green
    }
}
