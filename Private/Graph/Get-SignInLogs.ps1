function Get-SignInLogs {
    <#
    .SYNOPSIS
        Retrieves sign-in logs for a specific user from Microsoft Graph.
    .DESCRIPTION
        v1.0/auditLogs/signIns returns interactive sign-ins and successful federated
        sign-ins ONLY — despite what the endpoint name suggests, non-interactive sign-ins
        (token refreshes, background client activity, SSO on a joined device) are not
        included. Those live behind the beta endpoint's signInEventTypes filter, which
        does not exist in v1.0, so -IncludeNonInteractive issues a second beta query.

        It is opt-in because non-interactive volume routinely dwarfs interactive volume
        and would swamp the timeline for everyday use.
    .PARAMETER UserId
        The Entra user object ID (GUID).
    .PARAMETER Days
        How many days back to query. Default 30.
    .PARAMETER IncludeNonInteractive
        Also collect non-interactive sign-ins from the beta endpoint.
    .OUTPUTS
        PSCustomObject with Items (List) and Complete (bool).
    .EXAMPLE
        Get-SignInLogs -UserId '00000000-0000-0000-0000-000000000000' -Days 30
    .EXAMPLE
        Get-SignInLogs -UserId $id -Days 7 -IncludeNonInteractive
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserId,
        [int]$Days = 30,
        [switch]$IncludeNonInteractive
    )

    $startDate = (Get-Date).AddDays(-$Days).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $results   = [System.Collections.Generic.List[object]]::new()
    $complete  = $true

    # Selecting appliedConditionalAccessPolicies requires Policy.Read.ConditionalAccess in
    # the delegated token (Connect-EntraTimeline always requests it); if the select is
    # rejected anyway, the fallback URI fetches the full payload instead of failing.
    $select = 'id,createdDateTime,appDisplayName,ipAddress,clientAppUsed,isInteractive,' +
              'conditionalAccessStatus,status,deviceDetail,location,appliedConditionalAccessPolicies,' +
              'riskDetail,riskLevelDuringSignIn,riskState,resourceDisplayName,correlationId'
    $filter = "userId eq '$UserId' and createdDateTime ge $startDate"

    $r = Read-GraphCollection -Into $results -Label 'Sign-in logs' `
        -Uri         "/v1.0/auditLogs/signIns?`$filter=$filter&`$select=$select&`$top=999" `
        -FallbackUri "/v1.0/auditLogs/signIns?`$filter=$filter&`$top=999"
    if (-not $r.Complete) { $complete = $false }

    $interactiveCount = $results.Count

    if ($IncludeNonInteractive) {
        $niFilter = "$filter and signInEventTypes/any(t: t eq 'nonInteractiveUser')"

        $ni = Read-GraphCollection -Into $results -Label 'Non-interactive sign-ins' `
            -Uri         "/beta/auditLogs/signIns?`$filter=$niFilter&`$select=$select&`$top=999" `
            -FallbackUri "/beta/auditLogs/signIns?`$filter=$niFilter&`$top=999"

        # Logged separately: merged into the total, a zero here is invisible, and "no
        # non-interactive sign-ins" and "the beta query never ran" look identical.
        $niCount = $results.Count - $interactiveCount
        Write-TimelineLog -Level Info `
            -Message "Non-interactive sign-ins: $niCount events (beta, HTTP $($ni.StatusCode))"

        # Surface an empty result to the operator too, so a working toggle that finds
        # nothing is distinguishable from a toggle that did nothing.
        if ($niCount -eq 0 -and $ni.Complete) {
            Write-TimelineLog -Level Warning `
                -Message "No non-interactive sign-ins found for this user in the last $Days days."
        }

        # A tenant without access to the beta endpoint leaves the lane thinner, but that
        # is a licensing/permission fact rather than a truncated collection.
        if (-not $ni.Complete -and $ni.StatusCode -notin @(401, 403, 404)) { $complete = $false }
    }

    # The two passes can overlap — Entra files some non-interactive events (FIDO2, certain
    # Exchange clients) in the interactive log as well.
    $seen    = [System.Collections.Generic.HashSet[string]]::new()
    $deduped = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $results) {
        if ($seen.Add([string]$item.id)) { $deduped.Add($item) }
    }

    Write-TimelineLog -Level Info -Message "Sign-in logs: $($deduped.Count) events for user $UserId (last $Days days, interactive: $interactiveCount)"
    return [PSCustomObject]@{ Items = $deduped; Complete = $complete }
}
