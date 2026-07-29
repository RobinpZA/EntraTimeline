function Remove-ApiCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [System.Collections.Specialized.NameValueCollection]$Query
    )

    $userId = $Query['userId']
    $ctx    = Get-MgContext
    $tenantId = $ctx.TenantId ?? 'default'
    $safe   = $tenantId -replace '[^a-zA-Z0-9_-]', '_'

    if ($userId) {
        # Clear cache for specific user
        $safeUser = $userId -replace '[^a-zA-Z0-9_-]', '_'
        $pattern  = "${safeUser}_*"
        $cacheDir = Join-Path $script:CacheRoot $safe
        $removed  = 0
        if (Test-Path $cacheDir) {
            $files = Get-ChildItem -Path $cacheDir -Filter $pattern -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
                $removed++
            }
        }
        Write-TimelineLog -Level Info -Message "Cache cleared: $removed entries for user $userId"
        Write-JsonResponse -Context $Context -Data @{ cleared = $removed; userId = $userId }
    } else {
        # Clear all cache for tenant
        $cacheDir = Join-Path $script:CacheRoot $safe
        $removed  = 0
        if (Test-Path $cacheDir) {
            $files = Get-ChildItem -Path $cacheDir -Filter '*.json' -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
                $removed++
            }
        }
        # Also reset session-cached CA policies
        $script:CAPolicyCache = $null
        Write-TimelineLog -Level Info -Message "Cache cleared: $removed total entries"
        Write-JsonResponse -Context $Context -Data @{ cleared = $removed }
    }
}
