function Get-ApiExport {
    <#
    .SYNOPSIS
        Exports a user's timeline as CSV or HTML — served as a download and also
        saved to Output/AuditLogs/.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string]$UserId,
        [System.Collections.Specialized.NameValueCollection]$Query
    )

    $days   = Get-QueryDays -Query $Query
    $nonInt = $Query['nonInteractive'] -eq 'true'
    $format = ([string]($Query['format'] ?? 'html')).ToLower()
    if ($format -notin @('csv', 'html', 'json')) {
        Write-ErrorResponse -Context $Context -StatusCode 400 -Message "Unsupported format '$format' — use csv, html or json"
        return
    }

    # MaxEvents 0: an export is expected to be the whole set, not the screen's worth.
    $result = Get-TimelineEvents -UserId $UserId -Days $days -IncludeNonInteractive:$nonInt -MaxEvents 0
    $events = @($result.Events)

    $displayName = $UserId
    $upn         = ''
    try {
        $user        = Invoke-MgGraphRequest -Method GET -Uri "/v1.0/users/${UserId}?`$select=displayName,userPrincipalName" -ErrorAction Stop
        $displayName = $user.displayName ?? $UserId
        $upn         = $user.userPrincipalName ?? ''
    } catch {
        Write-TimelineLog -Level Warning -Message "Export: could not resolve user ${UserId}: $($_.Exception.Message)"
    }

    $tenantDomain = (Get-MgContext).TenantDomain ?? ''

    $content = switch ($format) {
        'csv'  { ConvertTo-TimelineCsv -Events $events }
        'json' {
            [PSCustomObject]@{
                user       = [PSCustomObject]@{ id = $UserId; displayName = $displayName; userPrincipalName = $upn }
                tenant     = $tenantDomain
                days       = $days
                complete   = $result.Complete
                count      = $events.Count
                generated  = (Get-Date).ToUniversalTime().ToString('o')
                events     = $events
            } | ConvertTo-Json -Depth 20
        }
        default {
            ConvertTo-TimelineHtml -Events $events -UserDisplayName $displayName `
                -UserPrincipalName $upn -Days $days -TenantDomain $tenantDomain
        }
    }

    $contentType = switch ($format) {
        'csv'   { 'text/csv; charset=utf-8' }
        'json'  { 'application/json; charset=utf-8' }
        default { 'text/html; charset=utf-8' }
    }

    $stamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
    $nameBase = ($upn ? $upn : $UserId) -replace '[^a-zA-Z0-9@._-]', '_'
    $fileName = "EntraTimeline_${nameBase}_d${days}_${stamp}.${format}"

    # Keep a copy under Output/AuditLogs (convention) — non-fatal if it fails
    try {
        if (-not (Test-Path $script:OutputRoot)) {
            New-Item -Path $script:OutputRoot -ItemType Directory -Force | Out-Null
        }
        $content | Out-File -FilePath (Join-Path $script:OutputRoot $fileName) -Encoding utf8 -Force
        Clear-OldExports
    } catch {
        Write-TimelineLog -Level Warning -Message "Export: could not save copy to Output/AuditLogs: $($_.Exception.Message)"
    }

    Write-TimelineLog -Level Info -Message "Export: $($events.Count) events for $($upn ? $upn : $UserId) as $format"
    Write-DownloadResponse -Context $Context -Content $content -ContentType $contentType -FileName $fileName
}
