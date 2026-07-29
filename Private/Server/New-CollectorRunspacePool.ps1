function New-CollectorRunspacePool {
    <#
    .SYNOPSIS
        Creates the runspace pool the parallel Graph collectors run on.
    .DESCRIPTION
        The pool's session state pre-imports Microsoft.Graph.Authentication, so a collector
        never pays the module auto-load cost on first Invoke-MgGraphRequest. Previously
        every timeline load built four throwaway runspaces that each imported the module
        from cold — seconds of avoidable latency on each uncached load.

        The Graph SDK auth context is process-wide, so pooled runspaces share the session
        Connect-EntraTimeline established.
    .PARAMETER MinRunspaces
        Minimum pool size. Default 1.
    .PARAMETER MaxRunspaces
        Maximum pool size. Default 4 — one per collector.
    .EXAMPLE
        $pool = New-CollectorRunspacePool
    #>
    [CmdletBinding()]
    param(
        [int]$MinRunspaces = 1,
        [int]$MaxRunspaces = 4
    )

    $iss = [initialsessionstate]::CreateDefault2()
    $iss.ImportPSModule(@('Microsoft.Graph.Authentication'))

    $pool = [runspacefactory]::CreateRunspacePool($MinRunspaces, $MaxRunspaces, $iss, $Host)
    $pool.Open()
    return $pool
}

function Get-CollectorRunspacePool {
    <#
    .SYNOPSIS
        Returns the shared collector runspace pool, creating it on first use.
    .DESCRIPTION
        Cached per module instance. Each HTTP worker runspace holds its own module
        instance and therefore its own pool; they are released when the module unloads.
    .EXAMPLE
        $pool = Get-CollectorRunspacePool
    #>
    [CmdletBinding()]
    param()

    if (-not $script:CollectorPool) {
        $script:CollectorPool = New-CollectorRunspacePool
        Write-TimelineLog -Level Debug -Message 'Collector runspace pool opened'
    }
    return $script:CollectorPool
}
