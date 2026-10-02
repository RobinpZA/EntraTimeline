function Write-JsonResponse {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][object]$Data,
        [int]$StatusCode = 200
    )
    $json   = $Data | ConvertTo-Json -Depth 15 -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode     = $StatusCode
    $Context.Response.ContentType    = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $buffer.Length
    $Context.Response.Headers.Add('X-Content-Type-Options', 'nosniff')
    $Context.Response.Headers.Add('Cache-Control', 'no-store')
    $Context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Context.Response.OutputStream.Close()
}

function Get-ContentSecurityPolicy {
    <#
    .SYNOPSIS
        Returns the Content-Security-Policy sent with the portal page.
    .DESCRIPTION
        A backstop for the hand-escaped innerHTML rendering: if one esc() is ever missed,
        injected script still cannot run, load from elsewhere or send data off the machine.

        Scripts are 'self' only — the portal has no inline scripts, handlers or eval.
        Styles allow 'unsafe-inline' because the portal and vis-timeline both write
        style attributes (event colours, item positions); inline style cannot execute
        code, so the script rules still hold. Google Fonts is the one external origin.
    .OUTPUTS
        String — the header value.
    .EXAMPLE
        $Context.Response.Headers.Add('Content-Security-Policy', (Get-ContentSecurityPolicy))
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    @(
        "default-src 'none'"
        "script-src 'self'"
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com"
        "font-src 'self' https://fonts.gstatic.com"
        "img-src 'self' data:"
        "connect-src 'self'"
        "base-uri 'none'"
        "form-action 'none'"
        "frame-ancestors 'none'"
    ) -join '; '
}

function Resolve-WebAssetPath {
    <#
    .SYNOPSIS
        Resolves a requested asset path inside the web root, or $null if it escapes.
    .DESCRIPTION
        Canonicalizes the path and confirms it sits under the root. The comparison keeps
        the trailing separator attached — without it a sibling directory whose name merely
        starts with the root ('...\Webxyz') would satisfy the prefix test.
    .PARAMETER Root
        The web root directory.
    .PARAMETER RelativePath
        The requested path, relative to the root.
    .OUTPUTS
        The full path, or $null when the request resolves outside the root.
    .EXAMPLE
        $full = Resolve-WebAssetPath -Root $script:WebRoot -RelativePath 'css/styles.css'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RelativePath
    )

    # A rooted request ('C:\Windows\...', '/etc/passwd') is never a web asset. Join-Path
    # would glue it onto the root and yield a nonsense path that still passes the prefix
    # test, so reject it outright.
    if ([System.IO.Path]::IsPathRooted($RelativePath)) { return $null }

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') +
                [System.IO.Path]::DirectorySeparatorChar

    try {
        $requestedFull = [System.IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    } catch {
        Write-Verbose "Unresolvable asset path '$RelativePath': $($_.Exception.Message)"
        return $null
    }

    if (-not $requestedFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    return $requestedFull
}

function Get-FileETag {
    <#
    .SYNOPSIS
        Builds a validator for a file from its last-write time and size.
    .DESCRIPTION
        Cheap to compute and changes whenever the file is edited, which is what lets the
        portal be cached without ever serving a stale asset.
    .PARAMETER Path
        The file to build the tag for.
    .EXAMPLE
        $etag = Get-FileETag -Path $full
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $info = Get-Item -LiteralPath $Path -ErrorAction Stop
    return '"{0:x}-{1:x}"' -f $info.LastWriteTimeUtc.Ticks, $info.Length
}

function Get-AssetVersion {
    <#
    .SYNOPSIS
        Returns a token that changes whenever any portal asset changes.
    .DESCRIPTION
        The newest write time across the portal's scripts and stylesheets. Stamped onto
        asset URLs so an edit produces a URL the browser has never seen.
    .PARAMETER Root
        The web root to scan.
    .EXAMPLE
        $v = Get-AssetVersion -Root $script:WebRoot
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root
    )

    $newest = Get-ChildItem -Path $Root -Recurse -File -Include '*.js', '*.css' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTimeUtc -Descending |
              Select-Object -First 1

    if (-not $newest) { return '0' }
    return $newest.LastWriteTimeUtc.Ticks.ToString('x')
}

function Add-AssetVersion {
    <#
    .SYNOPSIS
        Stamps a version query onto local script and stylesheet references in HTML.
    .DESCRIPTION
        ETag revalidation only helps once the browser asks. An asset already cached
        under the old max-age=3600 header is not re-requested at all until that hour
        is up, which is how an edited app.js kept running as the previous version and
        made a working feature look broken. A changing URL cannot be served from a
        cache entry keyed on the old one.
    .PARAMETER Html
        The document text.
    .PARAMETER Version
        Token to append.
    .EXAMPLE
        $html = Add-AssetVersion -Html $html -Version (Get-AssetVersion -Root $root)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Html,
        [Parameter(Mandatory)][string]$Version
    )

    return $Html -replace '((?:src|href)="/(?:js|css|vendor)/[^"?]+)"', "`$1?v=$Version`""
}

function Write-StaticFile {
    <#
    .SYNOPSIS
        Serves a static file from the Web root. Path is canonicalized to prevent traversal.
    .DESCRIPTION
        Assets are cached with revalidation (no-cache + ETag) rather than a fixed lifetime.
        A max-age meant an edited app.js kept being served from the browser cache for an
        hour afterwards, so portal changes appeared to do nothing until a hard refresh —
        the revalidation round-trip is free on loopback and 304s keep loads instant.
    .PARAMETER Context
        The request context.
    .PARAMETER FilePath
        Path of the asset relative to the web root.
    .EXAMPLE
        Write-StaticFile -Context $Context -FilePath 'js/app.js'
    #>
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string]$FilePath
    )

    $requestedFull = Resolve-WebAssetPath -Root $script:WebRoot -RelativePath $FilePath

    if (-not $requestedFull) {
        Write-TimelineLog -Level Error -Message "BLOCKED path traversal: $FilePath" -Source 'Security'
        Write-ErrorResponse -Context $Context -StatusCode 403 -Message 'Forbidden'
        return
    }

    if (-not (Test-Path $requestedFull)) {
        Write-ErrorResponse -Context $Context -StatusCode 404 -Message 'Not found'
        return
    }

    $ext = [System.IO.Path]::GetExtension($requestedFull).ToLower()
    $contentType = switch ($ext) {
        '.html' { 'text/html; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        '.js'   { 'application/javascript; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' }
        '.svg'  { 'image/svg+xml' }
        '.png'  { 'image/png' }
        '.ico'  { 'image/x-icon' }
        '.woff2' { 'font/woff2' }
        '.woff'  { 'font/woff' }
        default { 'application/octet-stream' }
    }

    try {
        # index.html carries the asset version, so its own validator has to move when
        # any script or stylesheet moves — otherwise a 304 would serve a document
        # still pointing at the previous version's URLs.
        $etag = if ($ext -eq '.html') {
            '"{0}-{1}"' -f (Get-FileETag -Path $requestedFull).Trim('"'), (Get-AssetVersion -Root $script:WebRoot)
        } else {
            Get-FileETag -Path $requestedFull
        }

        # Unchanged since the browser last fetched it — answer 304 and send no body.
        if ($Context.Request.Headers['If-None-Match'] -eq $etag) {
            $Context.Response.StatusCode      = 304
            $Context.Response.ContentLength64 = 0
            $Context.Response.Headers.Add('ETag', $etag)
            $Context.Response.Headers.Add('Cache-Control', 'no-cache')
            $Context.Response.OutputStream.Close()
            return
        }

        $buffer = if ($ext -eq '.html') {
            $html = [System.IO.File]::ReadAllText($requestedFull)
            $html = Add-AssetVersion -Html $html -Version (Get-AssetVersion -Root $script:WebRoot)
            [System.Text.Encoding]::UTF8.GetBytes($html)
        } else {
            [System.IO.File]::ReadAllBytes($requestedFull)
        }
        $Context.Response.StatusCode      = 200
        $Context.Response.ContentType     = $contentType
        $Context.Response.ContentLength64 = $buffer.Length
        $Context.Response.Headers.Add('X-Content-Type-Options', 'nosniff')
        $Context.Response.Headers.Add('ETag', $etag)
        $Context.Response.Headers.Add('Cache-Control', 'no-cache')
        if ($ext -eq '.html') {
            $Context.Response.Headers.Add('Content-Security-Policy', (Get-ContentSecurityPolicy))
            $Context.Response.Headers.Add('Referrer-Policy', 'no-referrer')
        }
        $Context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
        $Context.Response.OutputStream.Close()
    } catch {
        Write-ErrorResponse -Context $Context -StatusCode 500 -Message 'Internal error'
    }
}

function Write-DownloadResponse {
    <#
    .SYNOPSIS
        Writes a string payload as a file download (Content-Disposition: attachment).
    #>
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$ContentType,
        [Parameter(Mandatory)][string]$FileName
    )
    $buffer   = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $safeName = $FileName -replace '[^a-zA-Z0-9@._-]', '_'
    $Context.Response.StatusCode      = 200
    $Context.Response.ContentType     = $ContentType
    $Context.Response.ContentLength64 = $buffer.Length
    $Context.Response.Headers.Add('X-Content-Type-Options', 'nosniff')
    $Context.Response.Headers.Add('Cache-Control', 'no-store')
    $Context.Response.Headers.Add('Content-Disposition', "attachment; filename=`"$safeName`"")
    $Context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Context.Response.OutputStream.Close()
}

function Close-HttpResponse {
    <#
    .SYNOPSIS
        Force-closes a response stream, ignoring the fact that it may already be closed.
    .DESCRIPTION
        Last-resort cleanup for a request that failed after its headers were written. A
        connection left open makes the browser hang until it times out, which reads to the
        operator as "the portal froze" rather than "that request failed".
    .PARAMETER Context
        The request context whose response should be closed.
    .EXAMPLE
        Close-HttpResponse -Context $Context
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context
    )

    try {
        $Context.Response.OutputStream.Close()
    } catch {
        Write-Verbose "Response already closed: $($_.Exception.Message)"
    }
}

function Write-ErrorResponse {
    <#
    .SYNOPSIS
        Writes a JSON error response. Internal detail is logged server-side only.
    #>
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [int]$StatusCode    = 500,
        [string]$Message    = 'Internal Server Error',
        [string]$InternalDetail
    )

    if ($InternalDetail) {
        Write-TimelineLog -Level Error -Message "HTTP $StatusCode — $InternalDetail"
    }

    $safeMessage = switch ($StatusCode) {
        400 { $Message }
        403 { 'Forbidden' }
        404 { $Message }
        405 { $Message }
        409 { $Message }
        default { 'An error occurred. Check the server log for details.' }
    }

    $data = @{ error = $true; statusCode = $StatusCode; message = $safeMessage }
    Write-JsonResponse -Context $Context -Data $data -StatusCode $StatusCode
}
