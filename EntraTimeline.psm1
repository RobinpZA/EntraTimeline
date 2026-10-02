# ─────────────────────────────────────────────────────────────
# EntraTimeline — Root Module Loader
# ─────────────────────────────────────────────────────────────

$script:TimelineRoot  = $PSScriptRoot
$script:WebRoot       = Join-Path $PSScriptRoot 'Web'
$script:Listener      = $null
$script:CAPolicyCache = $null
$script:CollectorPool = $null
$script:LogSession    = [System.Collections.Generic.List[PSCustomObject]]::new()

# Shared across the listener loop and request-worker runspaces (workers receive this
# same synchronized hashtable, so a Stop set anywhere is seen everywhere).
$script:ServerState   = [hashtable]::Synchronized(@{ Stop = $false })

$manifestPath = Join-Path $PSScriptRoot 'EntraTimeline.psd1'
try {
    $script:TimelineVersion = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion.ToString()
} catch {
    $script:TimelineVersion = '0.0.0'
}

$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private" -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue)
$Public  = @(Get-ChildItem -Path "$PSScriptRoot\Public"  -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in @($Private + $Public)) {
    try   { . $file.FullName }
    catch { Write-Error "Failed to import $($file.FullName): $_" }
}

# Runtime data holds real tenant activity, so it lives outside the module folder
# (see Get-TimelineDataRoot).
$script:DataRoot      = Get-TimelineDataRoot
$script:CacheRoot     = Join-Path $script:DataRoot 'Cache'
$script:LogRoot       = Join-Path $script:DataRoot 'Logs'
$script:OutputRoot    = Join-Path $script:DataRoot 'Output' 'AuditLogs'

foreach ($dir in @($script:CacheRoot, $script:LogRoot)) {
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
}

# Each module instance may hold a collector runspace pool — release it on unload.
$ExecutionContext.SessionState.Module.OnRemove = {
    if ($script:CollectorPool) {
        try {
            $script:CollectorPool.Close()
            $script:CollectorPool.Dispose()
        } catch {
            Write-Verbose "Collector pool already disposed: $($_.Exception.Message)"
        }
        $script:CollectorPool = $null
    }
}

Export-ModuleMember -Function $Public.BaseName
