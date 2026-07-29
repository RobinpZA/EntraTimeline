function New-RequestRunspacePool {
    <#
    .SYNOPSIS
        Creates the runspace pool used to handle HTTP requests concurrently.
    .DESCRIPTION
        Each worker runspace imports its own instance of the EntraTimeline module, so
        all private functions and module state (paths, version) are available there.
        The Graph SDK auth context is process-wide, so workers share the session that
        Connect-EntraTimeline established. Per-runspace module state that must be
        shared (the stop flag) is injected per request by Invoke-ListenerLoop.
    .PARAMETER MinRunspaces
        Minimum pool size. Default 1.
    .PARAMETER MaxRunspaces
        Maximum pool size. Default 4.
    .EXAMPLE
        $pool = New-RequestRunspacePool
    #>
    [CmdletBinding()]
    param(
        [int]$MinRunspaces = 1,
        [int]$MaxRunspaces = 4
    )

    $iss = [initialsessionstate]::CreateDefault2()
    $iss.ImportPSModule(@((Join-Path $script:TimelineRoot 'EntraTimeline.psd1')))

    $pool = [runspacefactory]::CreateRunspacePool($MinRunspaces, $MaxRunspaces, $iss, $Host)
    $pool.Open()
    return $pool
}
