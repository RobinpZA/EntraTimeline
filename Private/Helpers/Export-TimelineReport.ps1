function ConvertTo-TimelineCsv {
    <#
    .SYNOPSIS
        Renders normalized timeline events as CSV text.
    .PARAMETER Events
        Normalized timeline event objects (from Get-TimelineEvents).
    .EXAMPLE
        ConvertTo-TimelineCsv -Events $events
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Events
    )

    $rows = $Events | Select-Object timestamp, category, subcategory, title, status, summary, id, source, parentId
    return ($rows | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
}

function ConvertTo-TimelineHtml {
    <#
    .SYNOPSIS
        Renders normalized timeline events as a styled standalone HTML report.
    .PARAMETER Events
        Normalized timeline event objects (from Get-TimelineEvents).
    .PARAMETER UserDisplayName
        Display name for the report header.
    .PARAMETER UserPrincipalName
        UPN for the report header.
    .PARAMETER Days
        Reporting window in days, shown in the header.
    .PARAMETER TenantDomain
        Tenant domain for the report header.
    .EXAMPLE
        ConvertTo-TimelineHtml -Events $events -UserDisplayName 'Alice' -UserPrincipalName 'alice@contoso.com' -Days 30
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Events,
        [string]$UserDisplayName = 'Unknown user',
        [string]$UserPrincipalName = '',
        [int]$Days = 30,
        [string]$TenantDomain = ''
    )

    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]($s ?? '')) }

    $statusColor = @{
        success = '#a6e3a1'; warning = '#f9e2af'; failure = '#f38ba8'; info = '#89b4fa'
    }

    $counts = @{}
    foreach ($e in $Events) { $counts[$e.category] = ($counts[$e.category] ?? 0) + 1 }
    $statCards = foreach ($cat in @('SignIn', 'Audit', 'CA', 'Risk', 'Provisioning')) {
        if ($counts[$cat]) {
            "<div class='stat'><div class='stat-n'>$($counts[$cat])</div><div class='stat-l'>$cat</div></div>"
        }
    }

    $rowsHtml = foreach ($e in $Events) {
        $color = $statusColor[[string]$e.status] ?? '#6c7086'
        @"
<tr>
  <td class='mono'>$(& $enc $e.timestamp)</td>
  <td>$(& $enc $e.category)</td>
  <td>$(& $enc $e.title)</td>
  <td><span class='badge' style='color:$color;border-color:$color'>$(& $enc $e.status)</span></td>
  <td>$(& $enc $e.summary)</td>
</tr>
"@
    }

    $generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
    $upnLine   = if ($UserPrincipalName) { "<span class='upn'>$(& $enc $UserPrincipalName)</span>" } else { '' }
    $tenant    = if ($TenantDomain) { " · $(& $enc $TenantDomain)" } else { '' }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Entra Timeline — $(& $enc $UserDisplayName)</title>
<style>
  :root {
    --bg-base: #1e1e2e; --bg-surface: #181825; --bg-card: #313244;
    --text-primary: #cdd6f4; --text-muted: #6c7086; --accent: #89b4fa;
  }
  body { margin: 0; padding: 32px; background: var(--bg-base); color: var(--text-primary);
         font-family: 'Segoe UI', system-ui, sans-serif; font-size: 14px; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  .upn, .meta { color: var(--text-muted); font-size: 13px; }
  .stats { display: flex; gap: 12px; margin: 20px 0; }
  .stat { background: var(--bg-card); border-radius: 8px; padding: 10px 18px; text-align: center; }
  .stat-n { font-size: 20px; font-weight: 600; color: var(--accent); }
  .stat-l { font-size: 11px; color: var(--text-muted); text-transform: uppercase; }
  table { width: 100%; border-collapse: collapse; background: var(--bg-surface); border-radius: 8px; }
  th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid var(--bg-card); vertical-align: top; }
  th { font-size: 11px; text-transform: uppercase; color: var(--text-muted); }
  .mono { font-family: 'Consolas', monospace; font-size: 12px; white-space: nowrap; }
  .badge { border: 1px solid; border-radius: 10px; padding: 1px 8px; font-size: 11px; }
</style>
</head>
<body>
  <h1>Entra ID Activity Timeline — $(& $enc $UserDisplayName)</h1>
  $upnLine
  <div class="meta">Last $Days days$tenant · $($Events.Count) events · Generated $generated · EntraTimeline v$($script:TimelineVersion)</div>
  <div class="stats">$($statCards -join '')</div>
  <table>
    <thead><tr><th>Timestamp (UTC)</th><th>Category</th><th>Event</th><th>Status</th><th>Summary</th></tr></thead>
    <tbody>$($rowsHtml -join '')</tbody>
  </table>
</body>
</html>
"@
}
