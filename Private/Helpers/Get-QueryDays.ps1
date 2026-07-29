function Get-QueryDays {
    <#
    .SYNOPSIS
        Safely parses the 'days' query-string parameter.
    .DESCRIPTION
        Returns the parsed value clamped to 1-180, or the default when the
        parameter is missing or not a valid integer.
    .PARAMETER Query
        The request query-string collection.
    .PARAMETER Default
        Value used when 'days' is absent or unparsable. Default 30.
    .EXAMPLE
        $days = Get-QueryDays -Query $Query
    #>
    [CmdletBinding()]
    param(
        [System.Collections.Specialized.NameValueCollection]$Query,
        [int]$Default = 30
    )

    $parsed = 0
    if ($Query -and [int]::TryParse($Query['days'], [ref]$parsed)) {
        return [Math]::Clamp($parsed, 1, 180)
    }
    return $Default
}
