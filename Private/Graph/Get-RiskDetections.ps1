function Get-RiskDetections {
    <#
    .SYNOPSIS
        Retrieves risk detection events for a specific user. Requires Entra ID P2.
    .DESCRIPTION
        A tenant without P2 (or a caller without IdentityRiskEvent.Read.All) gets 401/403/404
        here. That is a licensing fact, not a failed collection, so the lane simply stays
        empty and the result still counts as complete — otherwise the timeline would never
        be cacheable on a P1 tenant.
    .PARAMETER UserId
        The Entra user object ID (GUID).
    .PARAMETER Days
        How many days back to query. Default 30.
    .OUTPUTS
        PSCustomObject with Items (List) and Complete (bool).
    .EXAMPLE
        Get-RiskDetections -UserId '00000000-0000-0000-0000-000000000000' -Days 30
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserId,
        [int]$Days = 30
    )

    $startDate = (Get-Date).AddDays(-$Days).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $results   = [System.Collections.Generic.List[object]]::new()

    # identityProtection/riskDetections requires ConsistencyLevel: eventual for any $filter query.
    # Max page size is 500 (not 999) for this endpoint.
    $r = Read-GraphCollection -Into $results -Label 'Risk detections' `
        -Headers @{ 'ConsistencyLevel' = 'eventual' } `
        -Uri "/v1.0/identityProtection/riskDetections?`$filter=userId eq '$UserId' and activityDateTime ge $startDate&`$top=500"

    $complete = $r.Complete -or ($r.StatusCode -in @(401, 403, 404))

    Write-TimelineLog -Level Info -Message "Risk detections: $($results.Count) events for user $UserId (last $Days days)"
    return [PSCustomObject]@{ Items = $results; Complete = $complete }
}
