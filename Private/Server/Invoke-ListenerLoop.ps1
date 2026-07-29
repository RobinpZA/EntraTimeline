function Invoke-ListenerLoop {
    <#
    .SYNOPSIS
        Accepts HTTP requests and dispatches each to a runspace-pool worker.
    .DESCRIPTION
        The accept loop polls GetContextAsync in 200 ms slices so the shared stop flag
        is honoured even while idle. Each accepted request runs Invoke-RequestRouter
        inside a worker runspace's own module instance, so a slow Graph collection no
        longer blocks static files or other API calls. Workers receive the caller's
        synchronized ServerState, so /api/shutdown handled on any worker stops the loop.
    .PARAMETER Listener
        The started HttpListener to accept requests from.
    .EXAMPLE
        Invoke-ListenerLoop -Listener $server.Listener
    #>
    # The dispatch scriptblock receives its variables via AddArgument/param() — the
    # Using-scope rule misfires on that pattern.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListener]$Listener
    )

    $pool    = New-RequestRunspacePool
    $pending = [System.Collections.Generic.List[object]]::new()
    $task    = $null

    $reap = {
        for ($i = $pending.Count - 1; $i -ge 0; $i--) {
            if ($pending[$i].Handle.IsCompleted) {
                try { $null = $pending[$i].PS.EndInvoke($pending[$i].Handle) }
                catch { Write-TimelineLog -Level Warning -Message "Request worker error: $($_.Exception.Message)" }
                $pending[$i].PS.Dispose()
                $pending.RemoveAt($i)
            }
        }
    }

    try {
        while ($Listener.IsListening -and -not $script:ServerState.Stop) {
            if (-not $task) { $task = $Listener.GetContextAsync() }

            $completed = $false
            try { $completed = $task.Wait(200) }
            catch { break }   # listener torn down while waiting

            & $reap

            if (-not $completed) { continue }
            if ($task.IsFaulted -or $task.IsCanceled) { break }

            $context = $task.Result
            $task    = $null

            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            $null = $ps.AddScript({
                param($ctx, $state)
                $m = Get-Module EntraTimeline
                & $m {
                    param($c, $s)
                    $script:ServerState = $s
                    Invoke-RequestRouter -Context $c
                } $ctx $state
            }).AddArgument($context).AddArgument($script:ServerState)

            $pending.Add([PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() })
        }
    } finally {
        # Let in-flight requests finish briefly, then tear everything down
        foreach ($w in $pending) {
            try {
                if ($w.Handle.AsyncWaitHandle.WaitOne(1500)) { $null = $w.PS.EndInvoke($w.Handle) }
            } catch {
                Write-Verbose "In-flight worker ended with: $($_.Exception.Message)"
            }
            $w.PS.Dispose()
        }
        $pool.Close()
        $pool.Dispose()
    }
}
