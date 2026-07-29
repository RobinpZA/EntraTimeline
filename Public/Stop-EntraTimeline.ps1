function Stop-EntraTimeline {
    <#
    .SYNOPSIS
        Gracefully stops the EntraTimeline HTTP listener.
    .DESCRIPTION
        Sets the stop flag and closes the listener socket. Module state is per-session,
        so this only works in the same PowerShell session that ran Start-EntraTimeline —
        and that session is blocked while the server runs. To stop the server, press
        Ctrl+C in the console or click the Shutdown button in the portal. This function
        exists for programmatic use (e.g., when the request loop is hosted in a runspace).
    .EXAMPLE
        Stop-EntraTimeline
    #>
    [CmdletBinding()]
    param()

    $script:ServerState.Stop = $true

    if ($script:Listener -and $script:Listener.IsListening) {
        $script:Listener.Stop()
        Write-TimelineLog -Level Info -Message 'EntraTimeline listener stopped.'
    } else {
        Write-Host 'EntraTimeline is not running.' -ForegroundColor Yellow
    }
}
