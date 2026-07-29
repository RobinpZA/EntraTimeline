function Get-DirectoryAudits {
    <#
    .SYNOPSIS
        Retrieves directory audit logs that target OR were initiated by a specific user.
    .DESCRIPTION
        Runs two queries: events where the user is the TARGET (e.g., admin changed their
        license) and events the user INITIATED (e.g., they changed something themselves).
        The initiatedBy/user/id filter silently matches nothing in v1.0, but filtering on
        initiatedBy/user/userPrincipalName works, so the user's UPN is resolved first.
        Results are deduplicated by event id.
    .PARAMETER UserId
        The Entra user object ID (GUID).
    .PARAMETER Days
        How many days back to query. Default 30.
    .OUTPUTS
        PSCustomObject with Items (List) and Complete (bool).
    .EXAMPLE
        Get-DirectoryAudits -UserId '00000000-0000-0000-0000-000000000000' -Days 30
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserId,
        [int]$Days = 30
    )

    $startDate = (Get-Date).AddDays(-$Days).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $results   = [System.Collections.Generic.List[object]]::new()
    $complete  = $true

    # Changes TARGETING this user (e.g., license assigned, group membership, password reset)
    $r = Read-GraphCollection -Into $results -Label 'Directory audits (target)' `
        -Uri "/v1.0/auditLogs/directoryAudits?`$filter=targetResources/any(t:t/id eq '$UserId') and activityDateTime ge $startDate&`$top=999"
    if (-not $r.Complete) { $complete = $false }

    # Changes INITIATED BY this user. initiatedBy/user/id matches nothing server-side in
    # v1.0, but the UPN filter works — resolve it first. A deleted user just skips this
    # half; the lookup failing is not a truncated collection.
    try {
        $u   = Invoke-GraphRequestWithRetry -Uri "/v1.0/users/${UserId}?`$select=userPrincipalName"
        $upn = $u.userPrincipalName -replace "'", "''"

        $r2 = Read-GraphCollection -Into $results -Label 'Directory audits (initiator)' `
            -Uri "/v1.0/auditLogs/directoryAudits?`$filter=initiatedBy/user/userPrincipalName eq '$upn' and activityDateTime ge $startDate&`$top=999"
        if (-not $r2.Complete) { $complete = $false }
    } catch {
        Write-TimelineLog -Level Warning -Message "Initiator-side audit query skipped: $($_.Exception.Message)"
    }

    # Deduplicate — an event can both target and be initiated by the same user
    $seen    = [System.Collections.Generic.HashSet[string]]::new()
    $deduped = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $results) {
        if ($seen.Add($item.id)) { $deduped.Add($item) }
    }

    Write-TimelineLog -Level Info -Message "Directory audits: $($deduped.Count) events targeting or initiated by user $UserId (last $Days days)"
    return [PSCustomObject]@{ Items = $deduped; Complete = $complete }
}
