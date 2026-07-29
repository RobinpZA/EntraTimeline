#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Unit tests for the pure helper functions. The Graph collectors and HTTP server
    are exercised manually via Start-EntraTimeline; these tests cover everything
    that can run without a Graph connection.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'Private\Helpers\ConvertTo-TimelineEvent.ps1')
    . (Join-Path $root 'Private\Helpers\Get-QueryDays.ps1')
    . (Join-Path $root 'Private\Helpers\Export-TimelineReport.ps1')
    . (Join-Path $root 'Private\Helpers\Get-CacheToken.ps1')
    . (Join-Path $root 'Private\Helpers\Get-CachedData.ps1')
    . (Join-Path $root 'Private\Helpers\Set-CachedData.ps1')
    . (Join-Path $root 'Private\Helpers\Clear-ExpiredCache.ps1')
    . (Join-Path $root 'Private\Helpers\Get-TimelineEvents.ps1')
    . (Join-Path $root 'Private\Graph\Invoke-GraphRequestWithRetry.ps1')
    . (Join-Path $root 'Private\Server\Write-HttpResponse.ps1')
    . (Join-Path $root 'Public\Connect-EntraTimeline.ps1')

    $script:TimelineVersion = 'test'

    # Module-scope paths the cache helpers read, redirected into a scratch folder.
    $script:CacheRoot = Join-Path ([System.IO.Path]::GetTempPath()) "EntraTimelineTests_$([guid]::NewGuid().ToString('N'))"
    New-Item -Path $script:CacheRoot -ItemType Directory -Force | Out-Null
}

AfterAll {
    if ($script:CacheRoot -and (Test-Path $script:CacheRoot)) {
        Remove-Item $script:CacheRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-QueryDays' {
    It 'returns the default when the query collection is null' {
        Get-QueryDays -Query $null | Should -Be 30
    }

    It 'returns the default when days is missing' {
        $q = [System.Collections.Specialized.NameValueCollection]::new()
        Get-QueryDays -Query $q | Should -Be 30
    }

    It 'returns the default when days is not a number' {
        $q = [System.Collections.Specialized.NameValueCollection]::new()
        $q.Add('days', 'abc')
        Get-QueryDays -Query $q | Should -Be 30
    }

    It 'parses a valid value' {
        $q = [System.Collections.Specialized.NameValueCollection]::new()
        $q.Add('days', '14')
        Get-QueryDays -Query $q | Should -Be 14
    }

    It 'clamps values above 180' {
        $q = [System.Collections.Specialized.NameValueCollection]::new()
        $q.Add('days', '999')
        Get-QueryDays -Query $q | Should -Be 180
    }

    It 'clamps values below 1' {
        $q = [System.Collections.Specialized.NameValueCollection]::new()
        $q.Add('days', '0')
        Get-QueryDays -Query $q | Should -Be 1
    }

    It 'honours a custom default' {
        Get-QueryDays -Query $null -Default 7 | Should -Be 7
    }
}

Describe 'ConvertTo-TimelineEvent — SignIn' {
    BeforeAll {
        function New-TestSignIn {
            param([int]$ErrorCode = 0, [object[]]$CAPolicies = $null)
            [PSCustomObject]@{
                id              = 'si-001'
                createdDateTime = '2026-06-01T08:00:00Z'
                appDisplayName  = 'Office 365'
                ipAddress       = '203.0.113.10'
                clientAppUsed   = 'Browser'
                isInteractive   = $true
                conditionalAccessStatus = 'success'
                status          = [PSCustomObject]@{ errorCode = $ErrorCode; failureReason = $null }
                deviceDetail    = [PSCustomObject]@{ browser = 'Edge 137'; operatingSystem = 'Windows 11' }
                location        = [PSCustomObject]@{ city = 'Johannesburg'; countryOrRegion = 'ZA' }
                appliedConditionalAccessPolicies = $CAPolicies
                correlationId   = 'corr-001'
            }
        }
    }

    It 'maps a successful sign-in to status success' {
        $result = @(ConvertTo-TimelineEvent -InputObject (New-TestSignIn) -Category 'SignIn')
        $result.Count            | Should -Be 1
        $result[0].category      | Should -Be 'SignIn'
        $result[0].status        | Should -Be 'success'
        $result[0].subcategory   | Should -Be 'Interactive'
        $result[0].title         | Should -Be 'Sign-in to Office 365'
        $result[0].summary       | Should -Match '203\.0\.113\.10'
    }

    It 'maps an MFA-required error code to status warning' {
        $result = @(ConvertTo-TimelineEvent -InputObject (New-TestSignIn -ErrorCode 50076) -Category 'SignIn')
        $result[0].status | Should -Be 'warning'
    }

    It 'maps other error codes to status failure' {
        $result = @(ConvertTo-TimelineEvent -InputObject (New-TestSignIn -ErrorCode 50126) -Category 'SignIn')
        $result[0].status | Should -Be 'failure'
    }

    It 'emits a CA child event when policies were applied' {
        $policies = @(
            [PSCustomObject]@{ id = 'p1'; displayName = 'Require MFA'; result = 'success'; enforcedGrantControls = @('Mfa') }
            [PSCustomObject]@{ id = 'p2'; displayName = 'Not in scope'; result = 'notApplied'; enforcedGrantControls = @() }
        )
        $result = @(ConvertTo-TimelineEvent -InputObject (New-TestSignIn -CAPolicies $policies) -Category 'SignIn')
        $result.Count          | Should -Be 2
        $ca = $result | Where-Object category -eq 'CA'
        $ca.parentId           | Should -Be 'si-001'
        $ca.status             | Should -Be 'success'
        $ca.detail.policies.Count | Should -Be 2
    }

    It 'marks the CA child event as failure when a policy blocked' {
        $policies = @(
            [PSCustomObject]@{ id = 'p1'; displayName = 'Block legacy auth'; result = 'failure'; enforcedGrantControls = @('Block') }
        )
        $result = @(ConvertTo-TimelineEvent -InputObject (New-TestSignIn -CAPolicies $policies) -Category 'SignIn')
        $ca = $result | Where-Object category -eq 'CA'
        $ca.status | Should -Be 'failure'
        $ca.icon   | Should -Be 'bi-shield-x'
    }

    It 'works via the pipeline' {
        $result = @((New-TestSignIn) | ConvertTo-TimelineEvent -Category 'SignIn')
        $result.Count | Should -Be 1
    }
}

Describe 'ConvertTo-TimelineEvent — Audit' {
    BeforeAll {
        $script:testAudit = [PSCustomObject]@{
            id                  = 'au-001'
            activityDateTime    = '2026-06-02T10:00:00Z'
            activityDisplayName = 'Update user'
            category            = 'UserManagement'
            result              = 'success'
            resultReason        = ''
            loggedByService     = 'Core Directory'
            correlationId       = 'corr-002'
            initiatedBy         = [PSCustomObject]@{
                user = [PSCustomObject]@{ displayName = 'Admin Alice' }
                app  = $null
            }
            targetResources     = @(
                [PSCustomObject]@{
                    id = 'u-1'; displayName = 'Bob Builder'; type = 'User'
                    modifiedProperties = @(
                        [PSCustomObject]@{ displayName = 'JobTitle'; oldValue = '"Tech"'; newValue = '"Lead"' }
                    )
                }
            )
        }
    }

    It 'maps a successful audit and extracts modified properties' {
        $result = @(ConvertTo-TimelineEvent -InputObject $script:testAudit -Category 'Audit')
        $result.Count                          | Should -Be 1
        $result[0].category                    | Should -Be 'Audit'
        $result[0].status                      | Should -Be 'success'
        $result[0].title                       | Should -Be 'Update user'
        $result[0].summary                     | Should -Match 'Admin Alice'
        $result[0].detail.modifiedProperties.Count | Should -Be 1
        $result[0].detail.modifiedProperties[0].property | Should -Be 'JobTitle'
    }

    It 'falls back to System when there is no initiator' {
        $audit = [PSCustomObject]@{
            id = 'au-002'; activityDateTime = '2026-06-02T11:00:00Z'
            activityDisplayName = 'Sync'; category = 'Other'; result = 'failure'
            initiatedBy = [PSCustomObject]@{ user = $null; app = $null }
            targetResources = @()
        }
        $result = @(ConvertTo-TimelineEvent -InputObject $audit -Category 'Audit')
        $result[0].status  | Should -Be 'failure'
        $result[0].summary | Should -Match 'System'
    }
}

Describe 'ConvertTo-TimelineEvent — Risk' {
    It 'maps a high-risk detection to status failure' {
        $risk = [PSCustomObject]@{
            id = 'rk-001'; activityDateTime = '2026-06-03T09:00:00Z'
            riskEventType = 'unfamiliarFeatures'; riskLevel = 'high'; riskState = 'atRisk'
            ipAddress = '198.51.100.7'
            location = [PSCustomObject]@{ city = 'Lagos'; countryOrRegion = 'NG' }
        }
        $result = @(ConvertTo-TimelineEvent -InputObject $risk -Category 'Risk')
        $result[0].category | Should -Be 'Risk'
        $result[0].status   | Should -Be 'failure'
        $result[0].title    | Should -Match '^Risk:'
        $result[0].summary  | Should -Match '198\.51\.100\.7'
    }

    It 'falls back to detectedDateTime when activityDateTime is missing' {
        $risk = [PSCustomObject]@{
            id = 'rk-002'; activityDateTime = $null; detectedDateTime = '2026-06-03T10:00:00Z'
            riskEventType = 'anonymizedIPAddress'; riskLevel = 'medium'
        }
        $result = @(ConvertTo-TimelineEvent -InputObject $risk -Category 'Risk')
        $result[0].timestamp | Should -Be '2026-06-03T10:00:00Z'
        $result[0].status    | Should -Be 'warning'
    }
}

Describe 'ConvertTo-TimelineEvent — Provisioning' {
    It 'maps a successful provisioning event' {
        $prov = [PSCustomObject]@{
            id = 'pv-001'; activityDateTime = '2026-06-04T07:00:00Z'; action = 'Update'
            provisioningStatusInfo = [PSCustomObject]@{ status = 'success'; errorInformation = $null }
            provisionedIdentity    = [PSCustomObject]@{ id = 'u-1'; displayName = 'Bob Builder' }
            sourceSystem           = [PSCustomObject]@{ displayName = 'Entra ID' }
            targetSystem           = [PSCustomObject]@{ displayName = 'Salesforce' }
            jobId = 'job-1'; cycleId = 'cyc-1'
        }
        $result = @(ConvertTo-TimelineEvent -InputObject $prov -Category 'Provisioning')
        $result[0].category | Should -Be 'Provisioning'
        $result[0].status   | Should -Be 'success'
        $result[0].title    | Should -Match 'Bob Builder'
        $result[0].summary  | Should -Be 'Entra ID → Salesforce'
    }

    It 'maps a failed provisioning event with error detail' {
        $prov = [PSCustomObject]@{
            id = 'pv-002'; activityDateTime = '2026-06-04T08:00:00Z'; action = 'Create'
            provisioningStatusInfo = [PSCustomObject]@{
                status = 'failure'
                errorInformation = [PSCustomObject]@{ errorCode = 'DuplicateTargetEntries'; reason = 'Duplicate found' }
            }
            provisionedIdentity = [PSCustomObject]@{ id = 'u-2'; displayName = 'Carol' }
            sourceSystem        = [PSCustomObject]@{ displayName = 'Workday' }
            targetSystem        = [PSCustomObject]@{ displayName = 'Entra ID' }
        }
        $result = @(ConvertTo-TimelineEvent -InputObject $prov -Category 'Provisioning')
        $result[0].status                  | Should -Be 'failure'
        $result[0].detail.statusErrorCode  | Should -Be 'DuplicateTargetEntries'
    }
}

Describe 'Get-GraphStatusCode' {
    It 'extracts the status from an HttpResponseMessage-shaped error' {
        $err = [PSCustomObject]@{
            Exception = [PSCustomObject]@{
                Response = [PSCustomObject]@{ StatusCode = [System.Net.HttpStatusCode]::TooManyRequests }
            }
        }
        Get-GraphStatusCode -ErrorRecord $err | Should -Be 429
    }

    It 'extracts a plain integer status' {
        $err = [PSCustomObject]@{ Exception = [PSCustomObject]@{ Response = [PSCustomObject]@{ StatusCode = 503 } } }
        Get-GraphStatusCode -ErrorRecord $err | Should -Be 503
    }

    It 'returns 0 when the error carries no response' {
        $err = [PSCustomObject]@{ Exception = [PSCustomObject]@{ Message = 'network down' } }
        Get-GraphStatusCode -ErrorRecord $err | Should -Be 0
    }

    It 'returns 0 for a null error' {
        Get-GraphStatusCode -ErrorRecord $null | Should -Be 0
    }
}

Describe 'Get-GraphRetryDelay' {
    It 'honours a typed RetryAfter.Delta' {
        $err = [PSCustomObject]@{
            Exception = [PSCustomObject]@{
                Response = [PSCustomObject]@{
                    Headers = [PSCustomObject]@{
                        RetryAfter = [PSCustomObject]@{ Delta = [timespan]::FromSeconds(37) }
                    }
                }
            }
        }
        Get-GraphRetryDelay -ErrorRecord $err -Attempt 1 | Should -Be 37
    }

    It 'honours a raw Retry-After header string' {
        $headers = @{ 'Retry-After' = '12' }
        $err = [PSCustomObject]@{
            Exception = [PSCustomObject]@{ Response = [PSCustomObject]@{ Headers = $headers } }
        }
        Get-GraphRetryDelay -ErrorRecord $err -Attempt 1 | Should -Be 12
    }

    It 'backs off exponentially when no header is present' {
        $err = [PSCustomObject]@{ Exception = [PSCustomObject]@{ Response = $null } }
        Get-GraphRetryDelay -ErrorRecord $err -Attempt 1 | Should -Be 2
        Get-GraphRetryDelay -ErrorRecord $err -Attempt 2 | Should -Be 4
        Get-GraphRetryDelay -ErrorRecord $err -Attempt 4 | Should -Be 16
    }

    It 'clamps an absurd Retry-After to 120 seconds' {
        $headers = @{ 'Retry-After' = '99999' }
        $err = [PSCustomObject]@{
            Exception = [PSCustomObject]@{ Response = [PSCustomObject]@{ Headers = $headers } }
        }
        Get-GraphRetryDelay -ErrorRecord $err -Attempt 1 | Should -Be 120
    }
}

Describe 'Invoke-GraphRequestWithRetry' {
    BeforeAll {
        # Stubs so the tests can run without Microsoft.Graph.Authentication installed.
        # Parameters are unused by design — they exist so Mock can bind and so
        # Should -Invoke -ParameterFilter has something to assert against.
        function Invoke-MgGraphRequest {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param($Method, $Uri, $Headers, $ErrorAction)
        }
        function Write-TimelineLog {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param($Level, $Message, $Source)
        }
    }

    BeforeEach {
        Mock Start-Sleep {}
        Mock Write-TimelineLog {}
    }

    It 'returns the response when the first attempt succeeds' {
        Mock Invoke-MgGraphRequest { @{ value = @('ok') } }
        $r = Invoke-GraphRequestWithRetry -Uri '/v1.0/me'
        $r.value | Should -Be 'ok'
        Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly
    }

    It 'retries a throttled request and returns the eventual success' {
        $script:calls = 0
        Mock Get-GraphStatusCode { 429 }
        Mock Invoke-MgGraphRequest {
            $script:calls++
            if ($script:calls -lt 3) { throw 'throttled' }
            @{ value = @('recovered') }
        }

        $r = Invoke-GraphRequestWithRetry -Uri '/v1.0/me'
        $r.value | Should -Be 'recovered'
        $script:calls | Should -Be 3
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'throws immediately on a non-retryable status' {
        Mock Get-GraphStatusCode { 403 }
        Mock Invoke-MgGraphRequest { throw 'forbidden' }

        { Invoke-GraphRequestWithRetry -Uri '/v1.0/me' } | Should -Throw
        Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'gives up after MaxRetries and rethrows' {
        Mock Get-GraphStatusCode { 429 }
        Mock Invoke-MgGraphRequest { throw 'throttled' }

        { Invoke-GraphRequestWithRetry -Uri '/v1.0/me' -MaxRetries 2 } | Should -Throw
        Should -Invoke Invoke-MgGraphRequest -Times 3 -Exactly   # first try + 2 retries
    }

    It 'passes headers through to Graph' {
        Mock Invoke-MgGraphRequest { @{ value = @() } }
        Invoke-GraphRequestWithRetry -Uri '/v1.0/users' -Headers @{ ConsistencyLevel = 'eventual' }
        Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter {
            $Headers.ConsistencyLevel -eq 'eventual'
        }
    }
}

Describe 'Connect-EntraTimeline' {
    BeforeAll {
        # Stub parameters are unused by design — see the note in Invoke-GraphRequestWithRetry.
        function Get-MgContext {}
        function Connect-MgGraph {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param($Scopes, $TenantId, $ErrorAction)
        }
        function Write-TimelineLog {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param($Level, $Message, $Source)
        }

        $script:allScopes = @(
            'AuditLog.Read.All', 'Directory.Read.All', 'Policy.Read.ConditionalAccess',
            'IdentityRiskEvent.Read.All', 'Policy.Read.All', 'User.Read.All'
        )
    }

    BeforeEach {
        Mock Write-TimelineLog {}
        Mock Connect-MgGraph {}
    }

    It 're-uses a fully scoped session when no tenant is requested' {
        Mock Get-MgContext { [PSCustomObject]@{
            Account = 'a@contoso.com'; TenantId = 't-1'; TenantDomain = 'contoso.onmicrosoft.com'
            Scopes  = $script:allScopes
        } }

        Connect-EntraTimeline
        Should -Invoke Connect-MgGraph -Times 0 -Exactly
    }

    It 're-uses the session when the requested tenant id matches' {
        Mock Get-MgContext { [PSCustomObject]@{
            Account = 'a@contoso.com'; TenantId = 't-1'; TenantDomain = 'contoso.onmicrosoft.com'
            Scopes  = $script:allScopes
        } }

        Connect-EntraTimeline -TenantId 't-1'
        Should -Invoke Connect-MgGraph -Times 0 -Exactly
    }

    It 're-uses the session when the requested tenant domain matches' {
        Mock Get-MgContext { [PSCustomObject]@{
            Account = 'a@contoso.com'; TenantId = 't-1'; TenantDomain = 'contoso.onmicrosoft.com'
            Scopes  = $script:allScopes
        } }

        Connect-EntraTimeline -TenantId 'contoso.onmicrosoft.com'
        Should -Invoke Connect-MgGraph -Times 0 -Exactly
    }

    It 'reconnects when a different tenant is requested' {
        Mock Get-MgContext { [PSCustomObject]@{
            Account = 'a@contoso.com'; TenantId = 't-1'; TenantDomain = 'contoso.onmicrosoft.com'
            Scopes  = $script:allScopes
        } }

        Connect-EntraTimeline -TenantId 'client.onmicrosoft.com'
        Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter {
            $TenantId -eq 'client.onmicrosoft.com'
        }
    }

    It 'reconnects when scopes are missing' {
        Mock Get-MgContext { [PSCustomObject]@{
            Account = 'a@contoso.com'; TenantId = 't-1'; TenantDomain = 'contoso.onmicrosoft.com'
            Scopes  = @('User.Read.All')
        } }

        Connect-EntraTimeline
        Should -Invoke Connect-MgGraph -Times 1 -Exactly
    }

    It 'connects when there is no session at all' {
        Mock Get-MgContext { $null }

        Connect-EntraTimeline
        Should -Invoke Connect-MgGraph -Times 1 -Exactly
    }

    It 'drops the cached CA policies after connecting' {
        Mock Get-MgContext { $null }
        $script:CAPolicyCache = @('stale-policy')

        Connect-EntraTimeline
        $script:CAPolicyCache | Should -BeNullOrEmpty
    }
}

Describe 'Get-CacheToken' {
    It 'gives punctuation variants distinct tokens' {
        $a = Get-CacheToken -Value 'a.b'
        $b = Get-CacheToken -Value 'a b'
        $c = Get-CacheToken -Value 'a_b'
        @($a, $b, $c) | Select-Object -Unique | Should -HaveCount 3
    }

    It 'is case-insensitive, matching the Graph queries it keys' {
        Get-CacheToken -Value 'Alice' | Should -Be (Get-CacheToken -Value 'alice')
    }

    It 'is stable across calls' {
        Get-CacheToken -Value 'bob@contoso.com' | Should -Be (Get-CacheToken -Value 'bob@contoso.com')
    }

    It 'produces a filesystem-safe fixed-length token' {
        Get-CacheToken -Value 'a/b\c:*?"<>|' | Should -Match '^[0-9a-f]{16}$'
    }
}

Describe 'Cache helpers' {
    BeforeAll {
        function Write-TimelineLog {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param($Level, $Message, $Source)
        }
    }

    It 'round-trips data through the cache' {
        Set-CachedData -TenantId 't1' -Key 'roundtrip' -Data @('a', 'b') -TtlMinutes 15
        $cached = Get-CachedData -TenantId 't1' -Key 'roundtrip'
        @($cached) | Should -Be @('a', 'b')
    }

    It 'returns null for a key that was never written' {
        Get-CachedData -TenantId 't1' -Key 'missing' | Should -BeNullOrEmpty
    }

    It 'expires an entry past its TTL and deletes it' {
        Set-CachedData -TenantId 't1' -Key 'expiring' -Data @('x') -TtlMinutes 15
        # A TtlMinutes of 0 makes any stored entry immediately too old
        Get-CachedData -TenantId 't1' -Key 'expiring' -TtlMinutes 0 | Should -BeNullOrEmpty
        Join-Path $script:CacheRoot 't1\expiring.json' | Should -Not -Exist
    }

    It 'honours an explicit TTL over the stored one' {
        Set-CachedData -TenantId 't1' -Key 'shortttl' -Data @('x') -TtlMinutes 1
        Get-CachedData -TenantId 't1' -Key 'shortttl' -TtlMinutes 600 | Should -Not -BeNullOrEmpty
    }

    It 'survives a corrupt cache file' {
        $dir = Join-Path $script:CacheRoot 't2'
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $dir 'corrupt.json') -Value '{ not json'
        Get-CachedData -TenantId 't2' -Key 'corrupt' | Should -BeNullOrEmpty
    }

    It 'sanitizes the tenant id into the directory name' {
        Set-CachedData -TenantId 'ten/ant:1' -Key 'safe' -Data @('x')
        Join-Path $script:CacheRoot 'ten_ant_1\safe.json' | Should -Exist
    }

    It 'leaves no temp files behind after a successful write' {
        Set-CachedData -TenantId 't3' -Key 'atomic' -Data @('x')
        @(Get-ChildItem -Path (Join-Path $script:CacheRoot 't3') -Filter '*.tmp') | Should -HaveCount 0
    }
}

Describe 'Clear-ExpiredCache' {
    BeforeAll {
        function Write-TimelineLog {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param($Level, $Message, $Source)
        }
    }

    It 'removes expired entries, orphaned temp files and corrupt files, but keeps fresh ones' {
        $dir = Join-Path $script:CacheRoot 'sweep'
        New-Item -Path $dir -ItemType Directory -Force | Out-Null

        $stale = @{ cachedAt = (Get-Date).AddHours(-5).ToUniversalTime().ToString('o'); ttlMinutes = 15; data = @('x') }
        $fresh = @{ cachedAt = (Get-Date).ToUniversalTime().ToString('o');              ttlMinutes = 15; data = @('x') }
        $stale | ConvertTo-Json -Compress | Set-Content (Join-Path $dir 'stale.json')
        $fresh | ConvertTo-Json -Compress | Set-Content (Join-Path $dir 'fresh.json')
        Set-Content -Path (Join-Path $dir 'broken.json') -Value '{ nope'
        Set-Content -Path (Join-Path $dir 'orphan.json.abc.tmp') -Value 'partial'

        Clear-ExpiredCache

        Join-Path $dir 'fresh.json'           | Should -Exist
        Join-Path $dir 'stale.json'           | Should -Not -Exist
        Join-Path $dir 'broken.json'          | Should -Not -Exist
        Join-Path $dir 'orphan.json.abc.tmp'  | Should -Not -Exist
    }
}

Describe 'Resolve-WebAssetPath' {
    BeforeAll {
        $script:webRoot = Join-Path $script:CacheRoot 'Web'
        New-Item -Path $script:webRoot -ItemType Directory -Force | Out-Null
    }

    It 'resolves a normal asset inside the root' {
        $r = Resolve-WebAssetPath -Root $script:webRoot -RelativePath 'css/styles.css'
        $r | Should -Not -BeNullOrEmpty
        $r | Should -BeLike "$script:webRoot*"
    }

    It 'rejects a traversal outside the root' {
        Resolve-WebAssetPath -Root $script:webRoot -RelativePath '..\..\secrets.txt' | Should -BeNullOrEmpty
    }

    It 'rejects a traversal that climbs back down' {
        Resolve-WebAssetPath -Root $script:webRoot -RelativePath 'css/../../elsewhere/x.js' | Should -BeNullOrEmpty
    }

    It 'rejects a sibling directory that merely shares the root prefix' {
        # 'Webxyz' starts with 'Web' — the guard must compare with the separator attached
        Resolve-WebAssetPath -Root $script:webRoot -RelativePath '..\Webxyz\app.js' | Should -BeNullOrEmpty
    }

    It 'rejects an absolute path' {
        Resolve-WebAssetPath -Root $script:webRoot -RelativePath 'C:\Windows\win.ini' | Should -BeNullOrEmpty
    }
}

Describe 'Get-FileETag' {
    BeforeAll {
        $script:etagFile = Join-Path $script:CacheRoot 'etag-probe.txt'
        Set-Content -Path $script:etagFile -Value 'one'
    }

    It 'is stable while the file is unchanged' {
        Get-FileETag -Path $script:etagFile | Should -Be (Get-FileETag -Path $script:etagFile)
    }

    It 'changes when the file is edited' {
        $before = Get-FileETag -Path $script:etagFile
        Start-Sleep -Milliseconds 20
        Set-Content -Path $script:etagFile -Value 'one plus more'
        Get-FileETag -Path $script:etagFile | Should -Not -Be $before
    }

    It 'is a quoted validator, as HTTP requires' {
        Get-FileETag -Path $script:etagFile | Should -Match '^"[0-9a-f]+-[0-9a-f]+"$'
    }
}

Describe 'Asset versioning' {
    BeforeAll {
        $script:assetRoot = Join-Path $script:CacheRoot 'WebAssets'
        New-Item -Path (Join-Path $script:assetRoot 'js')  -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $script:assetRoot 'css') -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $script:assetRoot 'js\app.js')      -Value 'console.log(1)'
        Set-Content -Path (Join-Path $script:assetRoot 'css\styles.css') -Value 'body{}'
    }

    Context 'Get-AssetVersion' {
        It 'returns a token for a populated root' {
            Get-AssetVersion -Root $script:assetRoot | Should -Match '^[0-9a-f]+$'
        }

        It 'is stable while nothing changes' {
            Get-AssetVersion -Root $script:assetRoot | Should -Be (Get-AssetVersion -Root $script:assetRoot)
        }

        It 'moves when any asset is edited' {
            $before = Get-AssetVersion -Root $script:assetRoot
            Start-Sleep -Milliseconds 20
            Set-Content -Path (Join-Path $script:assetRoot 'js\app.js') -Value 'console.log(2)'
            Get-AssetVersion -Root $script:assetRoot | Should -Not -Be $before
        }

        It 'copes with a root that has no assets' {
            $empty = Join-Path $script:CacheRoot 'EmptyWeb'
            New-Item -Path $empty -ItemType Directory -Force | Out-Null
            Get-AssetVersion -Root $empty | Should -Be '0'
        }
    }

    Context 'Add-AssetVersion' {
        It 'stamps scripts, stylesheets and vendor assets' {
            $html = '<script src="/js/app.js"></script><link href="/css/styles.css" rel="stylesheet">' +
                    '<script src="/vendor/vis-timeline/vis.min.js"></script>'
            $out  = Add-AssetVersion -Html $html -Version 'abc123'

            $out | Should -BeLike '*src="/js/app.js?v=abc123"*'
            $out | Should -BeLike '*href="/css/styles.css?v=abc123"*'
            $out | Should -BeLike '*src="/vendor/vis-timeline/vis.min.js?v=abc123"*'
        }

        It 'leaves external references alone' {
            $html = '<link href="https://fonts.googleapis.com/css2?family=Poppins" rel="stylesheet">'
            Add-AssetVersion -Html $html -Version 'abc123' | Should -Be $html
        }

        It 'does not double-stamp an already versioned reference' {
            $once  = Add-AssetVersion -Html '<script src="/js/app.js"></script>' -Version 'v1'
            $twice = Add-AssetVersion -Html $once -Version 'v1'
            $twice | Should -Be $once
        }

        It 'handles a document with no assets' {
            { Add-AssetVersion -Html '<p>nothing</p>' -Version 'v1' } | Should -Not -Throw
        }
    }
}

Describe 'Read-GraphCollection' {
    BeforeAll {
        function Invoke-GraphRequestWithRetry {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param($Uri, $Method, $Headers, $MaxRetries)
        }
        function Write-TimelineLog {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param($Level, $Message, $Source)
        }
    }

    It 'follows nextLink to the end and reports complete' {
        Mock Invoke-GraphRequestWithRetry {
            if ($Uri -eq 'page1') { return @{ value = @('a', 'b'); '@odata.nextLink' = 'page2' } }
            return @{ value = @('c') }
        }

        $into = [System.Collections.Generic.List[object]]::new()
        $r = Read-GraphCollection -Uri 'page1' -Into $into

        $r.Complete | Should -BeTrue
        $into       | Should -HaveCount 3
    }

    It 'keeps the records already gathered when a later page fails' {
        Mock Get-GraphStatusCode { 500 }
        Mock Invoke-GraphRequestWithRetry {
            if ($Uri -eq 'page1') { return @{ value = @('a', 'b'); '@odata.nextLink' = 'page2' } }
            throw 'page 2 exploded'
        }

        $into = [System.Collections.Generic.List[object]]::new()
        $r = Read-GraphCollection -Uri 'page1' -Into $into

        $r.Complete   | Should -BeFalse
        $r.StatusCode | Should -Be 500
        $into         | Should -HaveCount 2   # partial, not discarded
    }

    It 'falls back when the FIRST page is rejected' {
        Mock Invoke-GraphRequestWithRetry {
            if ($Uri -eq 'withSelect') { throw 'select rejected' }
            return @{ value = @('a') }
        }

        $into = [System.Collections.Generic.List[object]]::new()
        $r = Read-GraphCollection -Uri 'withSelect' -FallbackUri 'plain' -Into $into

        $r.Complete | Should -BeTrue
        $into       | Should -HaveCount 1
    }

    It 'does not fall back once past the first page' {
        Mock Get-GraphStatusCode { 503 }
        Mock Invoke-GraphRequestWithRetry {
            if ($Uri -eq 'page1') { return @{ value = @('a'); '@odata.nextLink' = 'page2' } }
            if ($Uri -eq 'page2') { throw 'later page failed' }
            return @{ value = @('fallback-should-not-be-used') }
        }

        $into = [System.Collections.Generic.List[object]]::new()
        $r = Read-GraphCollection -Uri 'page1' -FallbackUri 'plain' -Into $into

        $r.Complete | Should -BeFalse
        $into       | Should -HaveCount 1
    }

    It 'reports complete for an empty collection' {
        Mock Invoke-GraphRequestWithRetry { @{ value = @() } }

        $into = [System.Collections.Generic.List[object]]::new()
        (Read-GraphCollection -Uri 'empty' -Into $into).Complete | Should -BeTrue
        $into | Should -HaveCount 0
    }
}

Describe 'New-TimelineResult' {
    BeforeAll {
        $script:manyEvents = 1..120 | ForEach-Object {
            [PSCustomObject]@{ id = "e$_"; timestamp = '2026-06-01T08:00:00Z' }
        }
    }

    It 'returns everything when under the cap' {
        $r = New-TimelineResult -All @($script:manyEvents) -Cached $false -Complete $true -MaxEvents 500
        $r.Events     | Should -HaveCount 120
        $r.Truncated  | Should -BeFalse
        $r.TotalCount | Should -Be 120
        $r.Warnings   | Should -HaveCount 0
    }

    It 'truncates to the cap and says so' {
        $r = New-TimelineResult -All @($script:manyEvents) -Cached $false -Complete $true -MaxEvents 50
        $r.Events     | Should -HaveCount 50
        $r.Truncated  | Should -BeTrue
        $r.TotalCount | Should -Be 120
        $r.Warnings   | Should -HaveCount 1
        $r.Warnings[0] | Should -Match '50 most recent of 120'
    }

    It 'keeps the newest events when truncating' {
        $r = New-TimelineResult -All @($script:manyEvents) -Cached $false -Complete $true -MaxEvents 3
        $r.Events[0].id | Should -Be 'e1'   # caller sorts newest-first before calling
        $r.Events       | Should -HaveCount 3
    }

    It 'disables the cap when MaxEvents is 0' {
        $r = New-TimelineResult -All @($script:manyEvents) -Cached $false -Complete $true -MaxEvents 0
        $r.Events    | Should -HaveCount 120
        $r.Truncated | Should -BeFalse
    }

    It 'flags an incomplete collection' {
        $r = New-TimelineResult -All @() -Cached $false -Complete $false -MaxEvents 500
        $r.Complete | Should -BeFalse
        ($r.Warnings -join ' ') | Should -Match 'may be incomplete'
    }

    It 'carries collector warnings through' {
        $r = New-TimelineResult -All @() -Cached $false -Complete $true -MaxEvents 500 `
            -Warnings @('Risk detections unavailable')
        $r.Warnings | Should -Contain 'Risk detections unavailable'
    }

    It 'handles an empty event set' {
        $r = New-TimelineResult -All @() -Cached $true -Complete $true
        $r.Events     | Should -HaveCount 0
        $r.TotalCount | Should -Be 0
        $r.Cached     | Should -BeTrue
    }
}

Describe 'Export builders' {
    BeforeAll {
        $script:exportEvents = @(
            [PSCustomObject]@{
                id = 'e1'; timestamp = '2026-06-01T08:00:00Z'; category = 'SignIn'
                subcategory = 'Interactive'; title = 'Sign-in to Office 365'
                status = 'success'; summary = 'From 203.0.113.10'; source = 'signIns'; parentId = $null
            }
            [PSCustomObject]@{
                id = 'e2'; timestamp = '2026-06-01T09:00:00Z'; category = 'Audit'
                subcategory = 'UserManagement'; title = 'Update user <script>'
                status = 'failure'; summary = 'By: Admin & Co'; source = 'directoryAudits'; parentId = $null
            }
        )
    }

    Context 'ConvertTo-TimelineCsv' {
        It 'produces a header plus one row per event' {
            $csv   = ConvertTo-TimelineCsv -Events $script:exportEvents
            $lines = $csv -split "`r`n"
            $lines.Count    | Should -Be 3
            $lines[0]       | Should -Match 'timestamp'
            $lines[1]       | Should -Match 'SignIn'
        }

        It 'handles an empty event list' {
            { ConvertTo-TimelineCsv -Events @() } | Should -Not -Throw
        }
    }

    Context 'ConvertTo-TimelineHtml' {
        It 'produces a standalone document with header info and rows' {
            $html = ConvertTo-TimelineHtml -Events $script:exportEvents `
                -UserDisplayName 'Bob Builder' -UserPrincipalName 'bob@contoso.com' -Days 30
            $html | Should -Match '<!DOCTYPE html>'
            $html | Should -Match 'Bob Builder'
            $html | Should -Match 'bob@contoso\.com'
            $html | Should -Match 'Last 30 days'
        }

        It 'HTML-encodes event content' {
            $html = ConvertTo-TimelineHtml -Events $script:exportEvents -UserDisplayName 'X'
            $html | Should -Not -Match '<script>'
            $html | Should -Match '&lt;script&gt;'
            $html | Should -Match 'Admin &amp; Co'
        }

        It 'handles an empty event list' {
            { ConvertTo-TimelineHtml -Events @() -UserDisplayName 'X' } | Should -Not -Throw
        }
    }
}
