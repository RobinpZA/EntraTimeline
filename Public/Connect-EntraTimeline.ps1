function Connect-EntraTimeline {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph with all scopes required by EntraTimeline.
    .DESCRIPTION
        Wraps Connect-MgGraph and requests the delegated permissions needed to read
        sign-in logs, directory audits, CA policies, risk detections and user profiles.
        An existing session is re-used only when it targets the requested tenant AND
        already holds every required scope — otherwise a fresh Connect-MgGraph runs.
    .PARAMETER TenantId
        Optional tenant ID or domain name for multi-tenant / partner scenarios.
    .EXAMPLE
        Connect-EntraTimeline
    .EXAMPLE
        Connect-EntraTimeline -TenantId 'contoso.onmicrosoft.com'
    #>
    [CmdletBinding()]
    param(
        [string]$TenantId
    )

    $requiredScopes = @(
        'AuditLog.Read.All',
        'Directory.Read.All',
        'Policy.Read.ConditionalAccess',
        'IdentityRiskEvent.Read.All',
        'Policy.Read.All',
        'User.Read.All'
    )

    # Re-use the current session only when it is BOTH the requested tenant and fully
    # scoped. Skipping the tenant check would silently ignore -TenantId for an existing
    # session, leaving a partner staring at their own tenant's data under a client's name.
    # An unrecognised domain form (a verified domain rather than the initial one) simply
    # forces a reconnect, which lands on the right tenant either way.
    $ctx = Get-MgContext
    if ($ctx) {
        $tenantMatches = (-not $TenantId) -or
                         ($TenantId -eq $ctx.TenantId) -or
                         ($TenantId -eq $ctx.TenantDomain)
        $missing = @($requiredScopes | Where-Object { $_ -notin $ctx.Scopes })

        if ($tenantMatches -and -not $missing) {
            Write-TimelineLog -Level Info -Message "Already connected as $($ctx.Account) (tenant: $($ctx.TenantId))"
            return
        }

        if (-not $tenantMatches) {
            Write-TimelineLog -Level Info -Message "Switching tenant: connected to $($ctx.TenantId), '$TenantId' requested"
        } else {
            Write-TimelineLog -Level Info -Message "Re-connecting to add missing scopes: $($missing -join ', ')"
        }
    }

    $connectParams = @{ Scopes = $requiredScopes }
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }

    Connect-MgGraph @connectParams -ErrorAction Stop

    # The CA policy list is tenant-specific and cached for the session — drop it so a
    # tenant switch cannot serve the previous tenant's policies.
    $script:CAPolicyCache = $null

    $ctx = Get-MgContext
    Write-TimelineLog -Level Info -Message "Connected to Microsoft Graph as $($ctx.Account) (tenant: $($ctx.TenantId))"
}
