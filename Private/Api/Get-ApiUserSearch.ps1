function Get-ApiUserSearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [System.Collections.Specialized.NameValueCollection]$Query
    )

    $q = $Query['q']
    if (-not $q -or $q.Length -lt 1) {
        Write-ErrorResponse -Context $Context -StatusCode 400 -Message 'Query parameter q is required'
        return
    }
    if ($q.Length -gt 100) {
        Write-ErrorResponse -Context $Context -StatusCode 400 -Message 'Query too long'
        return
    }

    $ctx      = Get-MgContext
    $tenantId = $ctx.TenantId ?? 'default'
    $cacheKey = "usersearch_$(Get-CacheToken -Value $q)"

    $cached = Get-CachedData -TenantId $tenantId -Key $cacheKey -TtlMinutes 5
    if ($cached) {
        Write-JsonResponse -Context $Context -Data @{ users = $cached; cached = $true }
        return
    }

    $users = @(Get-UserSearch -Query $q)
    Set-CachedData -TenantId $tenantId -Key $cacheKey -Data $users -TtlMinutes 5
    Write-JsonResponse -Context $Context -Data @{ users = $users; cached = $false }
}
