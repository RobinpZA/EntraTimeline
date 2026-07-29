function Get-ApiCAPolicies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context
    )

    try {
        $policies = Get-ConditionalAccessPolicies
        Write-JsonResponse -Context $Context -Data @{ policies = @($policies); count = @($policies).Count }
    } catch {
        Write-ErrorResponse -Context $Context -StatusCode 500 -Message 'Failed to retrieve CA policies' `
            -InternalDetail $_.Exception.Message
    }
}
