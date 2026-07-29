function Get-ConditionalAccessPolicies {
    <#
    .SYNOPSIS
        Returns all Conditional Access policies in the tenant. Results are cached per session.
    .EXAMPLE
        Get-ConditionalAccessPolicies
    #>
    [CmdletBinding()]
    param()

    if ($script:CAPolicyCache) {
        Write-TimelineLog -Level Debug -Message 'CA policies served from session cache'
        return $script:CAPolicyCache
    }

    $select  = 'id,displayName,state,conditions,grantControls,sessionControls'
    $results = [System.Collections.Generic.List[object]]::new()
    $uri = "/v1.0/identity/conditionalAccess/policies?`$select=$select"

    try {
        do {
            $response = Invoke-GraphRequestWithRetry -Uri $uri
            foreach ($item in $response.value) { $results.Add($item) }
            $uri = $response.'@odata.nextLink'
        } while ($uri)

        $script:CAPolicyCache = $results
        Write-TimelineLog -Level Info -Message "CA policies: $($results.Count) policies loaded"
    } catch {
        Write-TimelineLog -Level Warning -Message "CA policies unavailable: $($_.Exception.Message)"
    }

    return $results
}
