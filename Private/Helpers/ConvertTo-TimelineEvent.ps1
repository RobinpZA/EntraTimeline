function ConvertTo-TimelineEvent {
    <#
    .SYNOPSIS
        Normalises a raw Graph object into one or more unified timeline event objects.
    .DESCRIPTION
        Dispatches to a category-specific helper. A single sign-in may yield multiple
        events (the sign-in itself plus one CA child event per applied policy).
    .PARAMETER InputObject
        The raw Graph API response object.
    .PARAMETER Category
        Source category: SignIn | Audit | Risk | Provisioning
    .EXAMPLE
        $signIns | ConvertTo-TimelineEvent -Category SignIn
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [ValidateSet('SignIn', 'Audit', 'Risk', 'Provisioning')]
        [string]$Category
    )

    process {
        switch ($Category) {
            'SignIn'       { ConvertFrom-SignInEvent      -SignIn $InputObject }
            'Audit'        { ConvertFrom-AuditEvent       -Audit  $InputObject }
            'Risk'         { ConvertFrom-RiskEvent        -Risk   $InputObject }
            'Provisioning' { ConvertFrom-ProvisioningEvent -Prov  $InputObject }
        }
    }
}

# ── Sign-In ──────────────────────────────────────────────────────────────────
function ConvertFrom-SignInEvent {
    param([object]$SignIn)

    $errorCode = [int]($SignIn.status.errorCode ?? 0)
    $mfaCodes  = @(50074, 50076, 50079, 50097, 500121)

    $status = if ($errorCode -eq 0) { 'success' }
              elseif ($errorCode -in $mfaCodes)  { 'warning' }
              else  { 'failure' }

    $color = switch ($status) {
        'success' { '#a6e3a1' }
        'warning' { '#f9e2af' }
        'failure' { '#f38ba8' }
    }

    $browser  = $SignIn.deviceDetail.browser   ?? ''
    $city     = $SignIn.location.city          ?? ''
    $country  = $SignIn.location.countryOrRegion ?? ''
    $ip       = $SignIn.ipAddress              ?? 'unknown IP'
    $app      = if ($SignIn.appDisplayName) { $SignIn.appDisplayName } else { 'Unknown app' }
    $subcat   = if ($SignIn.isInteractive -eq $true) { 'Interactive' } else { 'Non-Interactive' }

    $summaryParts = @("From $ip")
    if ($browser) { $summaryParts += "via $browser" }
    if ($city -or $country) { $summaryParts += ($city, $country | Where-Object { $_ }) -join ', ' }
    $summary = $summaryParts -join ' · '

    $events = [System.Collections.Generic.List[object]]::new()

    $events.Add([PSCustomObject]@{
        id          = $SignIn.id
        timestamp   = $SignIn.createdDateTime
        category    = 'SignIn'
        subcategory = $subcat
        title       = "Sign-in to $app"
        status      = $status
        icon        = 'bi-box-arrow-in-right'
        color       = $color
        summary     = $summary
        detail      = [PSCustomObject]@{
            app                           = $app
            ipAddress                     = $ip
            clientAppUsed                 = $SignIn.clientAppUsed
            isInteractive                 = $SignIn.isInteractive
            conditionalAccessStatus       = $SignIn.conditionalAccessStatus
            errorCode                     = $errorCode
            failureReason                 = $SignIn.status.failureReason
            device                        = $SignIn.deviceDetail
            location                      = $SignIn.location
            appliedConditionalAccessPolicies = $SignIn.appliedConditionalAccessPolicies
            riskDetail                    = $SignIn.riskDetail
            riskLevelDuringSignIn         = $SignIn.riskLevelDuringSignIn
            riskState                     = $SignIn.riskState
            mfaDetail                     = $SignIn.mfaDetail
            resourceDisplayName           = $SignIn.resourceDisplayName
            correlationId                 = $SignIn.correlationId
        }
        source      = 'signIns'
        parentId    = $null
    })

    # One CA summary event per sign-in — per-policy detail stays in the detail panel.
    $caPolicies = $SignIn.appliedConditionalAccessPolicies
    if ($caPolicies -and @($caPolicies).Count -gt 0) {
        $caPoliciesArr = @($caPolicies)
        $applied = @($caPoliciesArr | Where-Object { $_.result -eq 'success' })
        $blocked = @($caPoliciesArr | Where-Object { $_.result -eq 'failure' })

        $caStatus = if ($blocked.Count -gt 0) { 'failure' }
                    elseif ($applied.Count -gt 0) { 'success' }
                    else { 'info' }

        $caColor = switch ($caStatus) {
            'success' { '#89b4fa' }
            'failure' { '#f38ba8' }
            'info'    { '#6c7086' }
        }
        $caIcon = if ($caStatus -eq 'failure') { 'bi-shield-x' } else { 'bi-shield-check' }

        $grants     = $applied | ForEach-Object { $_.enforcedGrantControls } | Where-Object { $_ } | Sort-Object -Unique
        $titleExtra = if ($blocked.Count -gt 0)  { "$($blocked.Count) blocked" }
                      elseif ($grants)            { ($grants -join ', ') }
                      else                        { "$($applied.Count) applied" }

        $notApplied = @($caPoliciesArr | Where-Object { $_.result -notin @('success', 'failure') }).Count
        $caTitle    = "CA: $($caPoliciesArr.Count) policies · $titleExtra"
        $caSummary  = "$($applied.Count) applied · $($blocked.Count) blocked · $notApplied not applied"

        $events.Add([PSCustomObject]@{
            id          = "$($SignIn.id)_ca"
            timestamp   = $SignIn.createdDateTime
            category    = 'CA'
            subcategory = $SignIn.conditionalAccessStatus ?? 'evaluated'
            title       = $caTitle
            status      = $caStatus
            icon        = $caIcon
            color       = $caColor
            summary     = $caSummary
            detail      = [PSCustomObject]@{
                policies                = $caPoliciesArr
                conditionalAccessStatus = $SignIn.conditionalAccessStatus
                parentSignInId          = $SignIn.id
                signInApp               = $app
            }
            source      = 'signIns'
            parentId    = $SignIn.id
        })
    }

    return $events
}

# ── Directory Audit ───────────────────────────────────────────────────────────
function ConvertFrom-AuditEvent {
    param([object]$Audit)

    $auditResult = ($Audit.result ?? 'success').ToLower()
    $status      = if ($auditResult -eq 'success') { 'success' } else { 'failure' }
    $color       = if ($status -eq 'success') { '#a6e3a1' } else { '#f38ba8' }

    $icon = switch ($Audit.category) {
        'UserManagement'        { 'bi-person-gear' }
        'GroupManagement'       { 'bi-people' }
        'ApplicationManagement' { 'bi-app-indicator' }
        'RoleManagement'        { 'bi-shield-lock' }
        'Policy'                { 'bi-file-earmark-lock' }
        'Authentication'        { 'bi-key' }
        default                 { 'bi-pencil-square' }
    }

    # Build human-readable summary from modified properties and target resources
    $summaryParts = [System.Collections.Generic.List[string]]::new()
    $targets      = @($Audit.targetResources)
    if ($targets.Count -gt 0) {
        $targetNames = ($targets | Where-Object { $_.displayName } | ForEach-Object { $_.displayName }) -join ', '
        if ($targetNames) { $summaryParts.Add("Target: $targetNames") }
    }

    $initiatedBy = $Audit.initiatedBy
    $initiatorName = if ($initiatedBy.user.displayName) { $initiatedBy.user.displayName }
                     elseif ($initiatedBy.app.displayName)  { $initiatedBy.app.displayName }
                     else { 'System' }

    $summaryParts.Add("By: $initiatorName")
    $summary = $summaryParts -join ' · '

    # Extract modified property old/new value pairs
    $modifiedProps = [System.Collections.Generic.List[object]]::new()
    foreach ($target in $targets) {
        foreach ($prop in @($target.modifiedProperties)) {
            if ($prop) {
                $modifiedProps.Add([PSCustomObject]@{
                    property  = $prop.displayName
                    oldValue  = $prop.oldValue
                    newValue  = $prop.newValue
                })
            }
        }
    }

    return @([PSCustomObject]@{
        id          = $Audit.id
        timestamp   = $Audit.activityDateTime
        category    = 'Audit'
        subcategory = $Audit.category ?? 'Unknown'
        title       = $Audit.activityDisplayName ?? 'Directory change'
        status      = $status
        icon        = $icon
        color       = $color
        summary     = $summary
        detail      = [PSCustomObject]@{
            activity          = $Audit.activityDisplayName
            category          = $Audit.category
            result            = $Audit.result
            resultReason      = $Audit.resultReason
            loggedByService   = $Audit.loggedByService
            initiatedBy       = $initiatedBy
            initiatorName     = $initiatorName
            targetResources   = $targets
            modifiedProperties = $modifiedProps
            correlationId     = $Audit.correlationId
        }
        source      = 'directoryAudits'
        parentId    = $null
    })
}

# ── Risk Detection ────────────────────────────────────────────────────────────
function ConvertFrom-RiskEvent {
    param([object]$Risk)

    $level  = ($Risk.riskLevel ?? 'unknown').ToLower()
    $status = switch ($level) {
        'high'   { 'failure' }
        'medium' { 'warning' }
        'low'    { 'info' }
        default  { 'info' }
    }
    $color = switch ($level) {
        'high'   { '#f38ba8' }
        'medium' { '#fab387' }
        'low'    { '#f9e2af' }
        default  { '#6c7086' }
    }

    # Humanise camelCase risk type  e.g. 'anonymizedIPAddress' → 'Anonymized IP Address'
    $rawType     = $Risk.riskEventType ?? 'Unknown'
    $humanType   = ($rawType -creplace '([a-z])([A-Z])', '$1 $2') -replace '^.', { $_.Value.ToUpper() }

    $ip       = $Risk.ipAddress ?? ''
    $city     = $Risk.location.city ?? ''
    $country  = $Risk.location.countryOrRegion ?? ''
    $locParts = @($city, $country) | Where-Object { $_ }
    $summary  = "Level: $level" + $(if ($ip) { " · $ip" }) + $(if ($locParts) { " · $($locParts -join ', ')" })

    return @([PSCustomObject]@{
        id          = $Risk.id
        timestamp   = $Risk.activityDateTime ?? $Risk.detectedDateTime
        category    = 'Risk'
        subcategory = $rawType
        title       = "Risk: $humanType"
        status      = $status
        icon        = 'bi-exclamation-triangle'
        color       = $color
        summary     = $summary
        detail      = [PSCustomObject]@{
            riskEventType        = $rawType
            riskLevel            = $level
            riskState            = $Risk.riskState
            detectionTimingType  = $Risk.detectionTimingType
            ipAddress            = $ip
            location             = $Risk.location
            correlationId        = $Risk.correlationId
            requestId            = $Risk.requestId
            userDisplayName      = $Risk.userDisplayName
            userPrincipalName    = $Risk.userPrincipalName
        }
        source      = 'riskDetections'
        parentId    = $null
    })
}

# ── Provisioning ──────────────────────────────────────────────────────────────
function ConvertFrom-ProvisioningEvent {
    param([object]$Prov)

    $statusInfo  = $Prov.provisioningStatusInfo
    $provStatus  = ($statusInfo.status ?? 'unknown').ToLower()
    $status      = switch ($provStatus) {
        'success'  { 'success' }
        'failure'  { 'failure' }
        'skipped'  { 'info' }
        'warning'  { 'warning' }
        default    { 'info' }
    }
    $color = switch ($status) {
        'success' { '#a6e3a1' }
        'failure' { '#f38ba8' }
        'warning' { '#f9e2af' }
        'info'    { '#89b4fa' }
    }

    $target   = $Prov.provisionedIdentity.displayName ?? $Prov.provisionedIdentity.id ?? 'unknown'
    $source   = $Prov.sourceSystem.displayName ?? 'Unknown source'
    $dest     = $Prov.targetSystem.displayName ?? 'Unknown target'
    $action   = $Prov.action ?? 'Provision'
    $summary  = "$source → $dest"

    return @([PSCustomObject]@{
        id          = $Prov.id
        timestamp   = $Prov.activityDateTime
        category    = 'Provisioning'
        subcategory = $action
        title       = "$action : $target"
        status      = $status
        icon        = 'bi-arrow-repeat'
        color       = $color
        summary     = $summary
        detail      = [PSCustomObject]@{
            action              = $action
            status              = $provStatus
            statusErrorCode     = $statusInfo.errorInformation.errorCode
            statusErrorReason   = $statusInfo.errorInformation.reason
            provisionedIdentity = $Prov.provisionedIdentity
            sourceSystem        = $Prov.sourceSystem
            targetSystem        = $Prov.targetSystem
            jobId               = $Prov.jobId
            cycleId             = $Prov.cycleId
        }
        source      = 'provisioning'
        parentId    = $null
    })
}
