function Get-ApiStatus {
    <#
    .SYNOPSIS
        Reports connection, tenant and cache state for the portal header.
    .DESCRIPTION
        Also resolves the signed-in user so the empty state can offer "investigate my
        own account" as a starting point rather than an empty search box. App-only or
        otherwise /me-less sessions simply omit it.
    .PARAMETER Context
        The request context.
    .EXAMPLE
        Get-ApiStatus -Context $Context
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context
    )

    $ctx = Get-MgContext
    $me  = $null
    if ($ctx) {
        $connected    = $true
        $account      = $ctx.Account
        $tenantId     = $ctx.TenantId
        $tenantDomain = $ctx.TenantDomain
        $scopes       = @($ctx.Scopes)

        try {
            $me = Invoke-GraphRequestWithRetry -Uri '/v1.0/me?$select=id,displayName,userPrincipalName,accountEnabled'
        } catch {
            Write-TimelineLog -Level Debug -Message "Signed-in user not resolvable: $($_.Exception.Message)"
        }
    } else {
        $connected    = $false
        $account      = $null
        $tenantId     = $null
        $tenantDomain = $null
        $scopes       = @()
    }

    # Count cache entries
    $cacheCount = 0
    if (Test-Path $script:CacheRoot) {
        $cacheCount = (Get-ChildItem -Path $script:CacheRoot -Recurse -Filter '*.json' -ErrorAction SilentlyContinue).Count
    }

    Write-JsonResponse -Context $Context -Data @{
        connected    = $connected
        account      = $account
        me           = $me
        tenantId     = $tenantId
        tenantDomain = $tenantDomain
        scopes       = $scopes
        version      = $script:TimelineVersion
        cacheEntries = $cacheCount
        outputPath   = $script:OutputRoot
        serverTime   = (Get-Date).ToUniversalTime().ToString('o')
    }
}
