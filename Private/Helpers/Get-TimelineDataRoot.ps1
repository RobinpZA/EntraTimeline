function Get-TimelineDataRoot {
    <#
    .SYNOPSIS
        Returns the folder that holds Cache, Logs and Output (all real tenant data).
    .DESCRIPTION
        Defaults to %LOCALAPPDATA%\EntraTimeline, never the module folder: the module
        usually lives in a cloned repo, and a repo under OneDrive would sync sign-ins,
        IPs and user GUIDs to the cloud. LOCALAPPDATA is not part of a roaming profile.

        Set ENTRATIMELINE_DATA to override. It is an environment variable rather than a
        parameter because every request and collector runspace imports the module
        afresh, and only process-wide state reaches them.
    .OUTPUTS
        String — the data root path (not created here).
    .EXAMPLE
        $root = Get-TimelineDataRoot
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($env:ENTRATIMELINE_DATA) { return $env:ENTRATIMELINE_DATA }

    $local = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $local) { $local = [System.IO.Path]::GetTempPath() }
    return Join-Path $local 'EntraTimeline'
}
