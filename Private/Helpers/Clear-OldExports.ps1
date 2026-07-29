function Clear-OldExports {
    <#
    .SYNOPSIS
        Trims the saved copies under Output/AuditLogs to a bounded set.
    .DESCRIPTION
        Every export drops a timestamped copy in Output/AuditLogs. Nothing removed them,
        so a folder of real tenant activity grew without limit. Files past the retention
        window are deleted, and the newest MaxFiles are always kept regardless of age so a
        burst of exports on one day is never wiped by the next run.
    .PARAMETER RetentionDays
        Age beyond which an export is removed. Default 30.
    .PARAMETER MaxFiles
        Newest files always retained, whatever their age. Default 200.
    .EXAMPLE
        Clear-OldExports
    .EXAMPLE
        Clear-OldExports -RetentionDays 7 -MaxFiles 50
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateRange(1, 3650)][int]$RetentionDays = 30,
        [ValidateRange(1, 10000)][int]$MaxFiles     = 200
    )

    if (-not (Test-Path $script:OutputRoot)) { return }

    $cutoff  = (Get-Date).AddDays(-$RetentionDays)
    $files   = @(Get-ChildItem -Path $script:OutputRoot -File -Filter 'EntraTimeline_*' -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending)

    $removed = 0
    foreach ($file in ($files | Select-Object -Skip $MaxFiles)) {
        if ($file.LastWriteTime -ge $cutoff) { continue }
        if ($PSCmdlet.ShouldProcess($file.FullName, 'Remove expired export')) {
            Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }

    if ($removed -gt 0) {
        Write-TimelineLog -Level Info -Message "Export sweep: removed $removed export(s) older than $RetentionDays days"
    }
}
