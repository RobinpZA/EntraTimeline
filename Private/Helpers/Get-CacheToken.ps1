function Get-CacheToken {
    <#
    .SYNOPSIS
        Turns arbitrary text into a stable, filesystem-safe cache-key fragment.
    .DESCRIPTION
        Collapsing punctuation to underscores made distinct inputs collide: 'a.b', 'a b'
        and 'a_b' all produced the same key, so one search served another's results. A
        truncated SHA-256 keeps keys short while staying collision-free in practice.

        The value is lower-cased first because the Graph queries this keys are themselves
        case-insensitive — 'Alice' and 'alice' should share a cache entry.
    .PARAMETER Value
        Text to tokenize.
    .EXAMPLE
        $cacheKey = "usersearch_$(Get-CacheToken -Value $query)"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant())
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hex = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
        return $hex.Substring(0, 16)
    } finally {
        $sha.Dispose()
    }
}
