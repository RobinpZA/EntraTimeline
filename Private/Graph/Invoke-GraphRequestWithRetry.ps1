function Invoke-GraphRequestWithRetry {
    <#
    .SYNOPSIS
        Invokes a Microsoft Graph request, retrying on throttling and transient errors.
    .DESCRIPTION
        Wraps Invoke-MgGraphRequest with bounded retries for HTTP 429 (throttled) and the
        transient 503 / 504 responses. The service-supplied Retry-After header is honoured
        when present; otherwise the delay backs off exponentially (2, 4, 8, 16 s). Every
        other status — including 400 and 403 — throws straight away so callers keep their
        existing handling (the $select fallback, the P2-licence probe, and so on).

        The four timeline collectors run in parallel and page at $top=999, so a busy tenant
        will hit 429 sooner or later; without this, a single throttled page discarded the
        whole lane.
    .PARAMETER Uri
        Graph URI, absolute or relative (e.g. '/v1.0/auditLogs/signIns?...').
    .PARAMETER Method
        HTTP method. Default GET.
    .PARAMETER Headers
        Optional request headers, e.g. @{ ConsistencyLevel = 'eventual' }.
    .PARAMETER MaxRetries
        Retry attempts allowed after the first try. Default 4.
    .EXAMPLE
        Invoke-GraphRequestWithRetry -Uri '/v1.0/auditLogs/signIns?$top=999'
    .EXAMPLE
        Invoke-GraphRequestWithRetry -Uri $uri -Headers @{ ConsistencyLevel = 'eventual' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,

        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string]$Method = 'GET',

        [hashtable]$Headers,

        [ValidateRange(0, 10)][int]$MaxRetries = 4
    )

    $retryable = @(429, 503, 504)
    $attempt   = 0

    while ($true) {
        try {
            $params = @{ Method = $Method; Uri = $Uri; ErrorAction = 'Stop' }
            if ($Headers) { $params['Headers'] = $Headers }
            return Invoke-MgGraphRequest @params
        } catch {
            $status = Get-GraphStatusCode -ErrorRecord $_
            if ($attempt -ge $MaxRetries -or $status -notin $retryable) { throw }

            $attempt++
            $delay = Get-GraphRetryDelay -ErrorRecord $_ -Attempt $attempt
            Write-TimelineLog -Level Warning `
                -Message "Graph HTTP $status — retry $attempt/$MaxRetries in ${delay}s"
            Start-Sleep -Seconds $delay
        }
    }
}

function Read-GraphCollection {
    <#
    .SYNOPSIS
        Pages a Graph collection into a list, keeping whatever was gathered if it fails.
    .DESCRIPTION
        Follows @odata.nextLink to the end. When a page fails, the records already
        collected stay in the target list and the failure is reported rather than thrown —
        losing pages 1-6 because page 7 was rejected is worse than showing a partial
        timeline with a warning.
    .PARAMETER Uri
        First page URI.
    .PARAMETER Into
        List the records are appended to.
    .PARAMETER FallbackUri
        Optional alternative URI, used once if the FIRST page fails (e.g. a $select the
        tenant rejects). Later failures never fall back.
    .PARAMETER Headers
        Optional request headers, e.g. @{ ConsistencyLevel = 'eventual' }.
    .PARAMETER Label
        Human-readable collection name, used in log messages.
    .OUTPUTS
        PSCustomObject with Complete (bool) and StatusCode (int, 0 when unknown).
    .EXAMPLE
        $r = Read-GraphCollection -Uri $uri -Into $results -Label 'Sign-in logs'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        # AllowEmptyCollection is required: callers always pass a freshly created list, and
        # a mandatory parameter rejects an empty collection without it.
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Into,
        [string]$FallbackUri,
        [hashtable]$Headers,
        [string]$Label = 'Graph collection'
    )

    $next  = $Uri
    $first = $true

    Write-TimelineLog -Level Debug -Message "$Label GET $Uri"

    try {
        do {
            try {
                $response = Invoke-GraphRequestWithRetry -Uri $next -Headers $Headers
            } catch {
                if (-not ($first -and $FallbackUri)) { throw }
                Write-TimelineLog -Level Warning `
                    -Message "$Label query rejected, retrying with the fallback query: $($_.Exception.Message)"
                $next     = $FallbackUri
                $response = Invoke-GraphRequestWithRetry -Uri $next -Headers $Headers
            }

            $first = $false
            foreach ($item in $response.value) { $Into.Add($item) }
            $next = $response.'@odata.nextLink'
        } while ($next)

        return [PSCustomObject]@{ Complete = $true; StatusCode = 200 }
    } catch {
        $status = Get-GraphStatusCode -ErrorRecord $_
        Write-TimelineLog -Level Warning `
            -Message "$Label stopped after $($Into.Count) records (HTTP $status): $($_.Exception.Message)"
        return [PSCustomObject]@{ Complete = $false; StatusCode = $status }
    }
}

function Get-GraphStatusCode {
    <#
    .SYNOPSIS
        Extracts the HTTP status code from a Graph error, or 0 when there isn't one.
    .PARAMETER ErrorRecord
        The caught ErrorRecord. Typed as object because only .Exception.Response.StatusCode
        is read, and that shape differs between the SDK's HttpResponseMessage and
        HttpWebResponse.
    .EXAMPLE
        $status = Get-GraphStatusCode -ErrorRecord $_
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$ErrorRecord
    )

    try {
        $code = $ErrorRecord.Exception.Response.StatusCode
        if ($null -ne $code) { return [int]$code }
    } catch {
        Write-Verbose "No HTTP status on this error: $($_.Exception.Message)"
    }
    return 0
}

function Get-GraphRetryDelay {
    <#
    .SYNOPSIS
        Returns how many seconds to wait before retrying a throttled Graph request.
    .DESCRIPTION
        Prefers the service's Retry-After header. HttpResponseMessage exposes it as a typed
        RetryAfter value; HttpWebResponse only as a raw string — both shapes are probed.
        Falls back to exponential backoff, and always clamps to 1-120 seconds so a stray
        header cannot stall a request indefinitely.
    .PARAMETER ErrorRecord
        The caught ErrorRecord.
    .PARAMETER Attempt
        1-based retry number, used for the backoff fallback.
    .EXAMPLE
        $delay = Get-GraphRetryDelay -ErrorRecord $_ -Attempt 1
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$ErrorRecord,
        [Parameter(Mandatory)][int]$Attempt
    )

    $seconds = 0

    try {
        $headers = $ErrorRecord.Exception.Response.Headers
        if ($headers) {
            $delta = $headers.RetryAfter.Delta
            if ($delta) {
                $seconds = [int]$delta.TotalSeconds
            } else {
                $parsed = 0
                if ([int]::TryParse([string]$headers['Retry-After'], [ref]$parsed)) { $seconds = $parsed }
            }
        }
    } catch {
        Write-Verbose "No usable Retry-After header: $($_.Exception.Message)"
    }

    if ($seconds -le 0) { $seconds = [Math]::Pow(2, $Attempt) }

    return [int][Math]::Clamp([double]$seconds, 1.0, 120.0)
}
