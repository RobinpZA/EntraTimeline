function Start-HttpListener {
    <#
    .SYNOPSIS
        Starts a local HTTP listener on 127.0.0.1. Tries ports in the configured range.
    #>
    [CmdletBinding()]
    param(
        [int]$Port,
        [int]$PortRangeStart = 8470,
        [int]$PortRangeEnd   = 8479
    )

    $script:ServerState.Stop = $false
    $listener  = [System.Net.HttpListener]::new()
    $boundPort = $null

    $portsToTry = if ($Port) { @($Port) } else { $PortRangeStart..$PortRangeEnd }

    foreach ($p in $portsToTry) {
        try {
            $listener.Prefixes.Clear()
            $listener.Prefixes.Add("http://127.0.0.1:$p/")
            $listener.Start()
            $boundPort = $p
            break
        } catch {
            Write-TimelineLog -Level Warning -Message "Port $p unavailable, trying next..."
        }
    }

    if (-not $boundPort) {
        throw "Could not bind to any port in range $PortRangeStart-$PortRangeEnd."
    }

    $url = "http://127.0.0.1:$boundPort/"

    $line1  = "EntraTimeline is running on $url"
    $line2  = 'Press Ctrl+C to stop'
    $pad    = 3
    $width  = ([Math]::Max($line1.Length, $line2.Length)) + ($pad * 2)
    $border = '═' * $width
    $empty  = ' ' * $width
    $padL1  = $line1.PadRight($width - $pad).PadLeft($width)
    $padL2  = $line2.PadRight($width - $pad).PadLeft($width)

    Write-Host ''
    Write-Host "  ╔${border}╗" -ForegroundColor DarkCyan
    Write-Host "  ║${empty}║" -ForegroundColor DarkCyan
    Write-Host "  ║${padL1}║" -ForegroundColor DarkCyan
    Write-Host "  ║${padL2}║" -ForegroundColor DarkCyan
    Write-Host "  ║${empty}║" -ForegroundColor DarkCyan
    Write-Host "  ╚${border}╝" -ForegroundColor DarkCyan
    Write-Host ''

    return @{
        Listener = $listener
        Port     = $boundPort
        Url      = $url
    }
}
