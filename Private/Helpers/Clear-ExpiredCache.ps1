function Clear-ExpiredCache {
    <#
    .SYNOPSIS
        Removes expired or unreadable cache entries from the cache root.
    .DESCRIPTION
        Entries are only deleted lazily on read, so short-TTL files (e.g. type-ahead
        user searches) accumulate. This sweep runs at startup and removes any entry
        past its TTL, plus entries that can no longer be parsed.
    .EXAMPLE
        Clear-ExpiredCache
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path $script:CacheRoot)) { return }

    $removed = 0

    # Orphaned temp files from an interrupted cache write
    foreach ($tmp in Get-ChildItem -Path $script:CacheRoot -Recurse -Filter '*.tmp' -ErrorAction SilentlyContinue) {
        Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue
        $removed++
    }

    foreach ($file in Get-ChildItem -Path $script:CacheRoot -Recurse -Filter '*.json' -ErrorAction SilentlyContinue) {
        try {
            $cached = Get-Content $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            # Compare in UTC — see the note in Get-CachedData.
            $age    = (Get-Date).ToUniversalTime() - ([datetime]$cached.cachedAt).ToUniversalTime()
            if ($age.TotalMinutes -gt $cached.ttlMinutes) {
                Remove-Item $file.FullName -Force -ErrorAction Stop
                $removed++
            }
        } catch {
            # Corrupt or unreadable entry — discard it
            Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }

    if ($removed -gt 0) {
        Write-TimelineLog -Level Info -Message "Cache sweep: removed $removed expired entries"
    }
}
