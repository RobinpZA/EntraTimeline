# Manual harness: runs the HTTP server without a Graph connection so the threaded
# listener, static files, vendor assets and shutdown flow can be exercised end to end.
# Started by the test run; exits when POST /api/shutdown is received.
param([int]$Port = 8478)

Import-Module (Join-Path $PSScriptRoot '..\EntraTimeline.psd1') -Force

& (Get-Module EntraTimeline) {
    param($p)
    $server = Start-HttpListener -Port $p
    $script:Listener = $server.Listener
    try {
        Invoke-ListenerLoop -Listener $server.Listener
    } finally {
        if ($server.Listener.IsListening) { $server.Listener.Stop() }
        $server.Listener.Dispose()
    }
} $Port

Write-Host 'HARNESS-EXITED-CLEANLY'
