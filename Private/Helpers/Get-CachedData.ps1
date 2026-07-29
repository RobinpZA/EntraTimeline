function Get-CachedData {
    <#
    .SYNOPSIS
        Reads a cache entry. Returns $null if missing or expired.
    .PARAMETER TenantId
        Tenant scope for the cache key.
    .PARAMETER Key
        Cache entry identifier (e.g., 'userId_signins_d30').
    .PARAMETER TtlMinutes
        Maximum acceptable age in minutes. When specified it overrides the TTL the
        entry was written with; otherwise the stored TTL applies.
    .EXAMPLE
        Get-CachedData -TenantId $tenantId -Key "${userId}_signins_d30"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Key,
        [int]$TtlMinutes
    )

    $safe      = $TenantId -replace '[^a-zA-Z0-9_-]', '_'
    $cacheFile = Join-Path $script:CacheRoot $safe "$Key.json"

    if (-not (Test-Path $cacheFile)) { return $null }

    try {
        $cached = Get-Content $cacheFile -Raw -ErrorAction Stop | ConvertFrom-Json

        # cachedAt is stored in UTC, and ConvertFrom-Json hands it back as a UTC DateTime
        # rather than a string. Comparing that against a local Get-Date added the machine's
        # UTC offset to every entry's age — at UTC+2 a 15-minute TTL expired on write.
        $age    = (Get-Date).ToUniversalTime() - ([datetime]$cached.cachedAt).ToUniversalTime()
        $maxAge = if ($PSBoundParameters.ContainsKey('TtlMinutes')) { $TtlMinutes } else { $cached.ttlMinutes }

        if ($age.TotalMinutes -gt $maxAge) {
            Remove-Item $cacheFile -Force -ErrorAction SilentlyContinue
            return $null
        }

        return $cached.data
    } catch {
        Write-TimelineLog -Level Warning -Message "Cache read failed for $Key : $($_.Exception.Message)"
        return $null
    }
}
