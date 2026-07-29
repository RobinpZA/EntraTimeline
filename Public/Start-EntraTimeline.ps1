function Start-EntraTimeline {
    <#
    .SYNOPSIS
        Starts the EntraTimeline web portal.
    .DESCRIPTION
        Authenticates to Microsoft Graph (if not already connected), starts a local HTTP
        listener, and opens the interactive Entra ID timeline SPA in the default browser.
        Press Ctrl+C or click Shutdown in the portal to stop.
    .PARAMETER Port
        Specific port to bind to. If omitted, auto-selects from the range 8470-8479.
    .PARAMETER NoBrowser
        Suppress auto-opening the browser.
    .PARAMETER TenantId
        Target tenant ID or domain for multi-tenant use. Triggers a fresh Connect-MgGraph.
    .EXAMPLE
        Start-EntraTimeline
    .EXAMPLE
        Start-EntraTimeline -Port 8470 -NoBrowser
    .EXAMPLE
        Start-EntraTimeline -TenantId 'client.onmicrosoft.com'
    #>
    [CmdletBinding()]
    param(
        [int]$Port,
        [switch]$NoBrowser,
        [string]$TenantId
    )

    # ── Banner ──────────────────────────────────────────────────────────────────
    $v = $script:TimelineVersion
    Write-Host ''
    Write-Host '  ┌──────────────────────────────────────────────┐' -ForegroundColor Cyan
    Write-Host ("  │ {0,-44}│" -f "EntraTimeline  v$v") -ForegroundColor Cyan
    Write-Host '  │   Entra ID Activity Timeline Viewer          │' -ForegroundColor Cyan
    Write-Host '  │   Author: Robin Pieterse · Turrito Networks  │' -ForegroundColor Cyan
    Write-Host '  └──────────────────────────────────────────────┘' -ForegroundColor Cyan
    Write-Host ''

    # ── Graph connection ─────────────────────────────────────────────────────────
    # Always go through Connect-EntraTimeline: it re-uses a session only when all
    # required scopes are present, so an existing under-scoped session gets upgraded.
    Write-Host '  [1/3] Connecting to Microsoft Graph...' -ForegroundColor DarkCyan
    Connect-EntraTimeline -TenantId $TenantId
    $ctx = Get-MgContext
    Write-Host "        Connected as $($ctx.Account)" -ForegroundColor Green

    # ── Reset CA policy cache when tenant changes ────────────────────────────────
    $script:CAPolicyCache = $null

    # ── Directories ──────────────────────────────────────────────────────────────
    Write-Host '  [2/3] Checking runtime directories...' -ForegroundColor DarkCyan
    foreach ($dir in @($script:CacheRoot, $script:LogRoot)) {
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    }
    Clear-ExpiredCache

    # ── Start HTTP listener ───────────────────────────────────────────────────────
    Write-Host '  [3/3] Starting HTTP listener...' -ForegroundColor DarkCyan
    $listenerParams = if ($Port) {
        @{ Port = $Port }
    } else {
        @{ PortRangeStart = 8470; PortRangeEnd = 8479 }
    }

    $server = Start-HttpListener @listenerParams
    $script:Listener = $server.Listener

    # ── Open browser ──────────────────────────────────────────────────────────────
    if (-not $NoBrowser) {
        Start-Sleep -Milliseconds 400
        try {
            Start-Process $server.Url
        } catch {
            Write-TimelineLog -Level Warning -Message "Could not open browser automatically. Navigate to $($server.Url) manually."
        }
    }

    # ── Blocking request loop (workers handle requests concurrently) ────────────
    try {
        Invoke-ListenerLoop -Listener $server.Listener
    } finally {
        Write-TimelineLog -Level Info -Message 'EntraTimeline shutting down...'
        if ($server.Listener.IsListening) { $server.Listener.Stop() }
        $server.Listener.Dispose()
        $script:Listener         = $null
        $script:ServerState.Stop = $false
        Write-Host ''
        Write-Host '  EntraTimeline stopped.' -ForegroundColor DarkCyan
        Write-Host ''
    }
}
