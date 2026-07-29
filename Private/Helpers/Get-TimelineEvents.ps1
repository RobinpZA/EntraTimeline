function Get-TimelineEvents {
    <#
    .SYNOPSIS
        Collects, normalizes and caches the unified timeline for a user.
    .DESCRIPTION
        Runs the four Graph collectors in parallel on a shared runspace pool that
        pre-imports Microsoft.Graph.Authentication. Collector log calls are captured
        per-runspace via a shim and replayed through the real logger; warnings are also
        returned so the portal can tell the operator when a lane came back short.

        A collection that stopped early is NOT cached — caching a partial timeline for
        15 minutes would hide the gap behind a "Cached" badge.
    .PARAMETER UserId
        The Entra user object ID (GUID).
    .PARAMETER Days
        How many days back to query. Default 30.
    .PARAMETER Refresh
        Skip the cache and re-query Graph.
    .PARAMETER IncludeNonInteractive
        Also collect non-interactive sign-ins (beta endpoint). Cached separately.
    .PARAMETER MaxEvents
        Cap on returned events, newest first. 0 disables the cap (used by export).
        The cache always holds the full set.
    .EXAMPLE
        $result = Get-TimelineEvents -UserId $userId -Days 30
    .EXAMPLE
        $result = Get-TimelineEvents -UserId $userId -Days 90 -MaxEvents 0
    #>
    # The worker scriptblock receives its variables via AddArgument/param(), and
    # $logBag is used inside the worker's nested function — both rules misfire here.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'logBag')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserId,
        [int]$Days = 30,
        [switch]$Refresh,
        [switch]$IncludeNonInteractive,
        [ValidateRange(0, 100000)][int]$MaxEvents = 5000
    )

    $ctx      = Get-MgContext
    $tenantId = $ctx.TenantId ?? 'default'
    $cacheKey = "${UserId}_timeline_d${Days}$(if ($IncludeNonInteractive) { '_ni' })"

    if (-not $Refresh) {
        $cached = Get-CachedData -TenantId $tenantId -Key $cacheKey -TtlMinutes 15
        if ($cached) {
            # Only complete collections are ever written, so a cache hit is complete.
            return New-TimelineResult -All @($cached) -Cached $true -Complete $true -MaxEvents $MaxEvents
        }
    }

    $events   = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $graphDir = Join-Path $script:TimelineRoot 'Private\Graph'
    $logBag   = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $complete = $true

    # Pooled runspaces get Microsoft.Graph.Authentication but not this module, so the
    # shared request/paging helpers are dot-sourced alongside each collector script.
    $retryPath = Join-Path $graphDir 'Invoke-GraphRequestWithRetry.ps1'
    $pool      = Get-CollectorRunspacePool

    $collectors = @(
        @{ Category = 'SignIn';       Script = 'Get-SignInLogs.ps1';       Fn = 'Get-SignInLogs'
           Extra    = @{ IncludeNonInteractive = [bool]$IncludeNonInteractive } }
        @{ Category = 'Audit';        Script = 'Get-DirectoryAudits.ps1';  Fn = 'Get-DirectoryAudits';  Extra = @{} }
        @{ Category = 'Risk';         Script = 'Get-RiskDetections.ps1';   Fn = 'Get-RiskDetections';   Extra = @{} }
        @{ Category = 'Provisioning'; Script = 'Get-ProvisioningLogs.ps1'; Fn = 'Get-ProvisioningLogs'; Extra = @{} }
    )

    $workers = foreach ($c in $collectors) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript({
            param($retryPath, $scriptPath, $fnName, $userId, $days, $extra, $logBag)
            function Write-TimelineLog {
                param([string]$Level, [string]$Message, [string]$Source = 'EntraTimeline')
                $logBag.Enqueue([PSCustomObject]@{ Level = $Level; Message = $Message; Source = $Source })
            }
            . $retryPath
            . $scriptPath
            & $fnName -UserId $userId -Days $days @extra
        }).
            AddArgument($retryPath).
            AddArgument((Join-Path $graphDir $c.Script)).
            AddArgument($c.Fn).
            AddArgument($UserId).
            AddArgument($Days).
            AddArgument($c.Extra).
            AddArgument($logBag)

        [PSCustomObject]@{ Category = $c.Category; PS = $ps; Handle = $ps.BeginInvoke() }
    }

    foreach ($w in $workers) {
        try {
            $payload = @($w.PS.EndInvoke($w.Handle))[0]
            if (-not $payload.Complete) { $complete = $false }

            foreach ($item in $payload.Items) {
                $normalized = ConvertTo-TimelineEvent -InputObject $item -Category $w.Category
                foreach ($e in $normalized) { $events.Add($e) }
            }
        } catch {
            $complete = $false
            $warnings.Add("$($w.Category) collection failed: $($_.Exception.Message)")
            Write-TimelineLog -Level Warning -Message "$($w.Category) collection error: $($_.Exception.Message)"
        } finally {
            $w.PS.Dispose()
        }
    }

    $entry = $null
    while ($logBag.TryDequeue([ref]$entry)) {
        Write-TimelineLog -Level $entry.Level -Message $entry.Message -Source $entry.Source
        if ($entry.Level -eq 'Warning') { $warnings.Add($entry.Message) }
    }

    # Sort on parsed dates — Graph mixes '...:00Z' and '...:00.1234567Z' forms, which do
    # not order correctly as plain strings.
    $sorted = @($events | Sort-Object -Descending -Property @{
        Expression = { if ($_.timestamp) { [datetime]$_.timestamp } else { [datetime]::MinValue } }
    })

    if ($complete) {
        Set-CachedData -TenantId $tenantId -Key $cacheKey -Data $sorted -TtlMinutes 15
    } else {
        Write-TimelineLog -Level Warning -Message "Timeline for $UserId incomplete — not cached"
    }

    return New-TimelineResult -All $sorted -Cached $false -Complete $complete `
        -MaxEvents $MaxEvents -Warnings $warnings
}

function New-TimelineResult {
    <#
    .SYNOPSIS
        Applies the event cap and packages the timeline result for the API layer.
    .PARAMETER All
        Full, sorted event set (newest first).
    .PARAMETER Cached
        Whether the set came from the local cache.
    .PARAMETER Complete
        Whether every collector finished its pagination.
    .PARAMETER MaxEvents
        Cap on returned events. 0 disables the cap.
    .PARAMETER Warnings
        Operator-facing warnings gathered during collection.
    .EXAMPLE
        New-TimelineResult -All $sorted -Cached $false -Complete $true -MaxEvents 5000
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$All,
        [Parameter(Mandatory)][bool]$Cached,
        [Parameter(Mandatory)][bool]$Complete,
        [int]$MaxEvents = 5000,
        [object[]]$Warnings = @()
    )

    $notes     = [System.Collections.Generic.List[string]]::new()
    foreach ($w in $Warnings) { $notes.Add([string]$w) }

    $events    = $All
    $truncated = $false

    if ($MaxEvents -gt 0 -and $All.Count -gt $MaxEvents) {
        $truncated = $true
        $events    = $All[0..($MaxEvents - 1)]
        $notes.Add("Showing the $MaxEvents most recent of $($All.Count) events — narrow the time range to see the rest.")
    }

    if (-not $Complete) {
        $notes.Add('Some activity could not be retrieved — this timeline may be incomplete.')
    }

    return [PSCustomObject]@{
        Events     = @($events)
        Cached     = $Cached
        Complete   = $Complete
        Truncated  = $truncated
        TotalCount = $All.Count
        Warnings   = @($notes)
    }
}
