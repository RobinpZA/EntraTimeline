function Get-ProvisioningLogs {
    <#
    .SYNOPSIS
        Retrieves provisioning (app sync) events for a specific user.
    .DESCRIPTION
        A tenant with no provisioning jobs configured, or a caller without access to the
        endpoint, gets 401/403/404 — treated as "nothing to show" rather than a truncated
        collection so the timeline stays cacheable.
    .PARAMETER UserId
        The Entra user object ID (GUID).
    .PARAMETER Days
        How many days back to query. Default 30.
    .OUTPUTS
        PSCustomObject with Items (List) and Complete (bool).
    .EXAMPLE
        Get-ProvisioningLogs -UserId '00000000-0000-0000-0000-000000000000' -Days 30
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserId,
        [int]$Days = 30
    )

    $startDate = (Get-Date).AddDays(-$Days).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $results   = [System.Collections.Generic.List[object]]::new()
    $complete  = $true

    # provisionedIdentity/id is NOT filterable. Use sourceIdentity/id (Entra→SaaS outbound)
    # and targetIdentity/id (HR→Entra inbound). Both require ConsistencyLevel: eventual.
    $headers = @{ 'ConsistencyLevel' = 'eventual' }

    foreach ($filterPath in @('sourceIdentity/id', 'targetIdentity/id')) {
        $r = Read-GraphCollection -Into $results -Headers $headers -Label "Provisioning logs ($filterPath)" `
            -Uri "/v1.0/auditLogs/provisioning?`$filter=$filterPath eq '$UserId' and activityDateTime ge $startDate&`$top=999"

        if (-not $r.Complete -and $r.StatusCode -notin @(401, 403, 404)) { $complete = $false }
    }

    # Deduplicate — a user can appear in both source and target logs
    $seen    = [System.Collections.Generic.HashSet[string]]::new()
    $deduped = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $results) {
        if ($seen.Add($item.id)) { $deduped.Add($item) }
    }

    Write-TimelineLog -Level Info -Message "Provisioning logs: $($deduped.Count) events for user $UserId (last $Days days)"
    return [PSCustomObject]@{ Items = $deduped; Complete = $complete }
}
