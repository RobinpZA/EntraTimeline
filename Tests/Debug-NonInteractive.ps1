<#
.SYNOPSIS
    Probes the beta sign-in queries to find which filter form returns non-interactive
    sign-ins in this tenant.
.DESCRIPTION
    Run in a session that is already connected (Connect-EntraTimeline). Each variant is
    issued directly against Graph and reported with its row count or its error, so the
    difference between "the tenant has none" and "the query is wrong" is visible.

    Nothing is written to the cache or the timeline; this only reads.
.PARAMETER UserId
    The Entra user object ID to probe. Defaults to the signed-in account.
.PARAMETER Days
    Look-back window. Default 30.
.EXAMPLE
    .\Tests\Debug-NonInteractive.ps1
.EXAMPLE
    .\Tests\Debug-NonInteractive.ps1 -UserId '8484af7c-b04a-4b33-8f0e-e43e78cd2b1c' -Days 7
#>
[CmdletBinding()]
param(
    [string]$UserId,
    [int]$Days = 30
)

$ctx = Get-MgContext
if (-not $ctx) { throw 'Not connected. Run Connect-EntraTimeline first.' }

if (-not $UserId) {
    $UserId = (Invoke-MgGraphRequest -Method GET -Uri "/v1.0/users/$($ctx.Account)?`$select=id").id
}

$start = (Get-Date).AddDays(-$Days).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$base  = "userId eq '$UserId' and createdDateTime ge $start"

Write-Host ''
Write-Host "  Tenant : $($ctx.TenantId)" -ForegroundColor DarkCyan
Write-Host "  User   : $UserId" -ForegroundColor DarkCyan
Write-Host "  Window : last $Days days (since $start)" -ForegroundColor DarkCyan
Write-Host "  Scopes : $($ctx.Scopes -join ', ')" -ForegroundColor DarkCyan
Write-Host ''

$variants = [ordered]@{
    'v1.0 baseline (interactive)' =
        "/v1.0/auditLogs/signIns?`$filter=$base&`$top=5"

    'beta, no event-type filter' =
        "/beta/auditLogs/signIns?`$filter=$base&`$top=5"

    'beta, nonInteractiveUser (current implementation)' =
        "/beta/auditLogs/signIns?`$filter=$base and signInEventTypes/any(t: t eq 'nonInteractiveUser')&`$top=5"

    'beta, nonInteractiveUser, no space after colon' =
        "/beta/auditLogs/signIns?`$filter=$base and signInEventTypes/any(t:t eq 'nonInteractiveUser')&`$top=5"

    'beta, ne interactiveUser (docs example form)' =
        "/beta/auditLogs/signIns?`$filter=$base and (signInEventTypes/any(t: t ne 'interactiveUser'))&`$top=5"

    'beta, event-type filter only (no userId)' =
        "/beta/auditLogs/signIns?`$filter=createdDateTime ge $start and signInEventTypes/any(t: t eq 'nonInteractiveUser')&`$top=5"

    'beta, isInteractive eq false' =
        "/beta/auditLogs/signIns?`$filter=$base and isInteractive eq false&`$top=5"
}

foreach ($name in $variants.Keys) {
    $uri = $variants[$name]
    try {
        $r     = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        $rows  = @($r.value)
        $more  = if ($r.'@odata.nextLink') { ' (more pages available)' } else { '' }
        $colour = if ($rows.Count -gt 0) { 'Green' } else { 'Yellow' }

        Write-Host ("  {0,-52} {1,4} rows{2}" -f $name, $rows.Count, $more) -ForegroundColor $colour

        if ($rows.Count -gt 0) {
            $sample = $rows[0]
            Write-Host ("      first: {0} | isInteractive={1} | types={2}" -f `
                $sample.createdDateTime, $sample.isInteractive, ($sample.signInEventTypes -join '/')) -ForegroundColor DarkGray
        }
    } catch {
        $status = $_.Exception.Response.StatusCode.value__ ?? '?'
        Write-Host ("  {0,-52} HTTP {1}" -f $name, $status) -ForegroundColor Red
        $detail = $_.ErrorDetails.Message
        if ($detail) { Write-Host "      $($detail -replace '\s+', ' ')" -ForegroundColor DarkRed }
        else         { Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkRed }
    }
}

Write-Host ''
Write-Host '  A green row that the current implementation misses tells us which form to adopt.' -ForegroundColor DarkCyan
Write-Host '  All-zero on beta with a healthy v1.0 baseline means the tenant genuinely has none.' -ForegroundColor DarkCyan
Write-Host ''
