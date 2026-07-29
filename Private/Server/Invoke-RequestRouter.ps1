function Invoke-RequestRouter {
    <#
    .SYNOPSIS
        Routes one HTTP request to its handler and guarantees the response is closed.
    .DESCRIPTION
        Every branch ends in `break`: without it PowerShell's switch -Regex runs the body
        of every matching pattern, and a second handler writing to a closed response would
        take down the worker.

        State-changing endpoints (shutdown, cache clear) require POST plus a custom header.
        The header forces a CORS preflight that is never granted, so a page you happen to
        be browsing cannot fire one of these at the local port.
    .PARAMETER Context
        The accepted HttpListener request context.
    .EXAMPLE
        Invoke-RequestRouter -Context $context
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context)

    $request = $Context.Request
    $method  = $request.HttpMethod
    $path    = $request.Url.LocalPath
    $query   = $request.QueryString
    $guid    = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

    Write-TimelineLog -Level Debug -Message "$method $path"

    try {
        if ($method -eq 'OPTIONS') {
            $Context.Response.StatusCode = 204
            $Context.Response.Headers.Add('Allow', 'GET, POST, OPTIONS')
            return
        }

        switch -Regex ($path) {

            # ── Static files ────────────────────────────────────────────────────
            '^/$'                  { Write-StaticFile -Context $Context -FilePath 'index.html'; break }
            '^/(css|js|vendor)/.+' { Write-StaticFile -Context $Context -FilePath $path.TrimStart('/'); break }
            '^/favicon\.ico$'      { Write-ErrorResponse -Context $Context -StatusCode 404 -Message 'Not found'; break }

            # ── User search / lookup ────────────────────────────────────────────
            '^/api/users/search$'  { Get-ApiUserSearch -Context $Context -Query $query; break }
            "^/api/users/($guid)$" { Get-ApiUserById -Context $Context -UserId $Matches[1]; break }

            # ── Timeline (unified) ──────────────────────────────────────────────
            "^/api/timeline/($guid)$" {
                Get-ApiTimeline -Context $Context -UserId $Matches[1] -Query $query
                break
            }

            # ── Raw data endpoints ──────────────────────────────────────────────
            "^/api/(signins|audits|risks|provisioning)/($guid)$" {
                Get-ApiRawEvents -Context $Context -Source $Matches[1] -UserId $Matches[2] -Query $query
                break
            }

            # ── Export ──────────────────────────────────────────────────────────
            "^/api/export/($guid)$" {
                Get-ApiExport -Context $Context -UserId $Matches[1] -Query $query
                break
            }

            # ── CA policies ─────────────────────────────────────────────────────
            '^/api/ca-policies$' { Get-ApiCAPolicies -Context $Context; break }

            # ── Status ──────────────────────────────────────────────────────────
            '^/api/status$' { Get-ApiStatus -Context $Context; break }

            # ── Cache management (state-changing) ───────────────────────────────
            '^/api/cache/clear$' {
                if (Test-PortalRequest -Context $Context -Method $method) {
                    Remove-ApiCache -Context $Context -Query $query
                }
                break
            }

            # ── Shutdown (state-changing) ───────────────────────────────────────
            '^/api/shutdown$' {
                if (Test-PortalRequest -Context $Context -Method $method) {
                    Write-TimelineLog -Level Info -Message 'Shutdown requested via API'
                    Write-JsonResponse -Context $Context -Data @{ status = 'shutting down' }
                    $script:ServerState.Stop = $true
                }
                break
            }

            # ── 404 ─────────────────────────────────────────────────────────────
            default {
                Write-ErrorResponse -Context $Context -StatusCode 404 -Message "Not found: $path"
                break
            }
        }
    } catch {
        Write-TimelineLog -Level Error -Message "Router error on $path : $($_.Exception.Message)"
        try {
            Write-ErrorResponse -Context $Context -StatusCode 500 -Message 'Internal error' `
                -InternalDetail "Router error on ${path}: $($_.Exception.Message)"
        } catch {
            # Headers were already on the wire — nothing left to say, just let the
            # finally close the socket so the browser stops waiting.
            Write-Verbose "Could not write error response: $($_.Exception.Message)"
        }
    } finally {
        Close-HttpResponse -Context $Context
    }
}

function Test-PortalRequest {
    <#
    .SYNOPSIS
        Verifies a state-changing request came from the portal, replying if it did not.
    .DESCRIPTION
        Requires POST plus the X-EntraTimeline header. Writes the 405/403 itself and
        returns $false so the caller can simply skip the action.
    .PARAMETER Context
        The request context.
    .PARAMETER Method
        The request's HTTP method.
    .OUTPUTS
        Boolean — $true when the request may proceed.
    .EXAMPLE
        if (Test-PortalRequest -Context $Context -Method $method) { Remove-ApiCache ... }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string]$Method
    )

    if ($Method -ne 'POST') {
        Write-ErrorResponse -Context $Context -StatusCode 405 -Message 'Method not allowed'
        return $false
    }

    if ($Context.Request.Headers['X-EntraTimeline'] -ne '1') {
        Write-TimelineLog -Level Warning -Source 'Security' `
            -Message "$($Context.Request.Url.LocalPath) requested without portal header — blocked"
        Write-ErrorResponse -Context $Context -StatusCode 403 -Message 'Forbidden'
        return $false
    }

    return $true
}
