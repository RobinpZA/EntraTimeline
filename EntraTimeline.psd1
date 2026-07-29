@{
    RootModule        = 'EntraTimeline.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a3f7c2d1-84e5-4b09-9f3c-6d2e1a8b5c70'
    Author            = 'Robin Pieterse'
    CompanyName       = 'Turrito Networks'
    Copyright         = '(c) 2026 Robin Pieterse. MIT License.'
    Description       = 'Interactive Entra ID activity timeline viewer — sign-ins, directory audits, CA evaluations, risk detections and provisioning events in a single zoomable SPA.'
    PowerShellVersion = '7.2'
    RequiredModules   = @('Microsoft.Graph.Authentication')
    FunctionsToExport = @('Start-EntraTimeline', 'Stop-EntraTimeline', 'Connect-EntraTimeline')
    CmdletsToExport   = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Entra', 'AzureAD', 'M365', 'Timeline', 'SignIn', 'ConditionalAccess')
            ProjectUri = ''
        }
    }
}
