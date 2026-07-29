function Get-UserSearch {
    <#
    .SYNOPSIS
        Searches users by display name or UPN prefix for type-ahead results.
    .PARAMETER Query
        Search string (minimum 2 characters recommended).
    .EXAMPLE
        Get-UserSearch -Query 'alice'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateLength(1, 100)]
        [string]$Query
    )

    # Escape single quotes to prevent filter injection
    $safeQuery = $Query -replace "'", "''"
    $select    = 'id,displayName,userPrincipalName,jobTitle,department,accountEnabled,mail'

    $filterEnc = [System.Uri]::EscapeDataString("startsWith(displayName,'$safeQuery') or startsWith(userPrincipalName,'$safeQuery')")
    $uri = "/v1.0/users?`$filter=$filterEnc&`$top=20&`$select=$select&`$count=true"

    try {
        # ConsistencyLevel: eventual required for advanced queries
        $response = Invoke-GraphRequestWithRetry -Uri $uri `
            -Headers @{ 'ConsistencyLevel' = 'eventual' }

        return @($response.value)
    } catch {
        Write-TimelineLog -Level Warning -Message "User search failed: $($_.Exception.Message)"
        return @()
    }
}
