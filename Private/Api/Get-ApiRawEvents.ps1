function Get-ApiRawEvents {
    <#
    .SYNOPSIS
        Serves raw, un-normalized Graph records for one source and user.
    .DESCRIPTION
        Replaces four near-identical handlers that differed only by collector and cache
        key. Returns the untouched Graph payload — the portal renders the normalized
        /api/timeline instead, but these endpoints stay available for scripted pulls.
    .PARAMETER Context
        The request context.
    .PARAMETER Source
        One of signins | audits | risks | provisioning.
    .PARAMETER UserId
        The Entra user object ID (GUID).
    .PARAMETER Query
        The request query-string collection (days, refresh).
    .EXAMPLE
        Get-ApiRawEvents -Context $ctx -Source 'signins' -UserId $id -Query $query
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][ValidateSet('signins', 'audits', 'risks', 'provisioning')]
        [string]$Source,
        [Parameter(Mandatory)][string]$UserId,
        [System.Collections.Specialized.NameValueCollection]$Query
    )

    $collectors = @{
        signins      = @{ Fn = 'Get-SignInLogs';       Label = 'sign-in logs' }
        audits       = @{ Fn = 'Get-DirectoryAudits';  Label = 'directory audits' }
        risks        = @{ Fn = 'Get-RiskDetections';   Label = 'risk detections' }
        provisioning = @{ Fn = 'Get-ProvisioningLogs'; Label = 'provisioning logs' }
    }
    $collector = $collectors[$Source]

    $days     = Get-QueryDays -Query $Query
    $refresh  = $Query['refresh'] -eq 'true'
    $ctx      = Get-MgContext
    $tenantId = $ctx.TenantId ?? 'default'
    $cacheKey = "${UserId}_${Source}_d${days}"

    if (-not $refresh) {
        $cached = Get-CachedData -TenantId $tenantId -Key $cacheKey -TtlMinutes 15
        if ($cached) {
            Write-JsonResponse -Context $Context -Data @{ data = $cached; cached = $true; complete = $true }
            return
        }
    }

    try {
        $result = & $collector.Fn -UserId $UserId -Days $days
        $arr    = @($result.Items)

        # A partial pull is served but never cached, so the next request retries.
        if ($result.Complete) {
            Set-CachedData -TenantId $tenantId -Key $cacheKey -Data $arr -TtlMinutes 15
        }

        Write-JsonResponse -Context $Context -Data @{
            data     = $arr
            cached   = $false
            complete = $result.Complete
        }
    } catch {
        Write-ErrorResponse -Context $Context -StatusCode 500 -Message "Failed to retrieve $($collector.Label)" `
            -InternalDetail $_.Exception.Message
    }
}
