function Set-CachedData {
    <#
    .SYNOPSIS
        Writes data to a local JSON cache file with TTL metadata.
    .PARAMETER TenantId
        Tenant scope for the cache key.
    .PARAMETER Key
        Cache entry identifier.
    .PARAMETER Data
        Data to persist.
    .PARAMETER TtlMinutes
        TTL in minutes. Default 15.
    .EXAMPLE
        Set-CachedData -TenantId $tenantId -Key "${userId}_signins_d30" -Data $signIns -TtlMinutes 15
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object]$Data,
        [int]$TtlMinutes = 15
    )

    $safe     = $TenantId -replace '[^a-zA-Z0-9_-]', '_'
    $cacheDir = Join-Path $script:CacheRoot $safe

    if (-not (Test-Path $cacheDir)) {
        New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
    }

    $cacheFile = Join-Path $cacheDir "$Key.json"
    $payload   = @{
        cachedAt   = (Get-Date).ToUniversalTime().ToString('o')
        ttlMinutes = $TtlMinutes
        key        = $Key
        tenantId   = $TenantId
        data       = $Data
    }

    # Write to a temp file and move it into place. Requests run concurrently, so two
    # workers writing the same key directly could interleave and leave a truncated file.
    $tempFile = "$cacheFile.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $payload | ConvertTo-Json -Depth 20 -Compress | Out-File -FilePath $tempFile -Encoding utf8 -Force
        Move-Item -LiteralPath $tempFile -Destination $cacheFile -Force -ErrorAction Stop
    } catch {
        Write-TimelineLog -Level Warning -Message "Cache write failed for $Key : $($_.Exception.Message)"
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}
