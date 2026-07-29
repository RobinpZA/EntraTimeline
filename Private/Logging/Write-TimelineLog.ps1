function Write-TimelineLog {
    <#
    .SYNOPSIS
        Writes a structured log entry to the console and session log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Source = 'EntraTimeline'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = [PSCustomObject]@{
        Timestamp = $timestamp
        Level     = $Level
        Source    = $Source
        Message   = $Message
    }

    $script:LogSession.Add($entry)

    $colour = switch ($Level) {
        'Debug'   { 'DarkGray' }
        'Info'    { 'Cyan' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $colour

    # Requests run on multiple runspaces — serialize file appends with a named mutex.
    # Logging must never take down a request, hence the broad catch.
    $logFile = Join-Path $script:LogRoot "EntraTimeline_$(Get-Date -Format 'yyyyMMdd').log"
    $mutex   = [System.Threading.Mutex]::new($false, 'Local\EntraTimelineLog')
    try {
        $null = $mutex.WaitOne(2000)
        "$timestamp`t$Level`t$Source`t$Message" | Out-File -FilePath $logFile -Append -Encoding utf8
    } catch {
        Write-Verbose "Log file write skipped: $($_.Exception.Message)"
    } finally {
        try { $mutex.ReleaseMutex() } catch { Write-Verbose 'Mutex was not held' }
        $mutex.Dispose()
    }
}
