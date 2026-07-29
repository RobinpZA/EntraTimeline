function Get-ApiUserById {
    <#
    .SYNOPSIS
        Returns one user's profile by object ID — used to restore deep links.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string]$UserId
    )

    $select = 'id,displayName,userPrincipalName,jobTitle,department,accountEnabled,mail'
    try {
        $user = Invoke-MgGraphRequest -Method GET -Uri "/v1.0/users/${UserId}?`$select=$select" -ErrorAction Stop
        Write-JsonResponse -Context $Context -Data @{ user = $user }
    } catch {
        Write-ErrorResponse -Context $Context -StatusCode 404 -Message 'User not found' `
            -InternalDetail "User lookup failed for ${UserId}: $($_.Exception.Message)"
    }
}
