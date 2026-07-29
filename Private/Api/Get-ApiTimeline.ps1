function Get-ApiTimeline {
    <#
    .SYNOPSIS
        Serves the normalized, unified timeline for one user.
    .PARAMETER Context
        The request context.
    .PARAMETER UserId
        The Entra user object ID (GUID).
    .PARAMETER Query
        Query-string collection: days, refresh, categories, nonInteractive.
    .EXAMPLE
        Get-ApiTimeline -Context $ctx -UserId $id -Query $query
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string]$UserId,
        [System.Collections.Specialized.NameValueCollection]$Query
    )

    $days      = Get-QueryDays -Query $Query
    $refresh   = $Query['refresh'] -eq 'true'
    $nonInt    = $Query['nonInteractive'] -eq 'true'
    $catFilter = if ($Query['categories']) { $Query['categories'] -split ',' } else { @('SignIn','Audit','CA','Risk','Provisioning') }

    $result   = Get-TimelineEvents -UserId $UserId -Days $days -Refresh:$refresh -IncludeNonInteractive:$nonInt
    $filtered = @($result.Events | Where-Object { $_.category -in $catFilter })

    Write-JsonResponse -Context $Context -Data @{
        events     = $filtered
        cached     = $result.Cached
        count      = $filtered.Count
        complete   = $result.Complete
        truncated  = $result.Truncated
        totalCount = $result.TotalCount
        warnings   = @($result.Warnings)
        retrieved  = (Get-Date).ToUniversalTime().ToString('o')
    }
}
