<#
.SYNOPSIS
    M365 groups inventory orchestrator: Graph export (app-only, parallel) + SharePoint site URLs, staged in a
    durable SQLite run database by the C# engine, reconciled, sealed and exported as CSV or HTML.

.DESCRIPTION
    Requires PowerShell 7.4+. PowerShell owns configuration, authentication and every Graph / SharePoint call;
    the offline C# engine (engine\GroupInventory.Engine, .NET 8 + SQLite, built by .\Build-Engine.ps1) owns
    staging, reconciliation and the streaming exports. Sized for at least 400,000 cumulative objects (groups,
    owners, members): rows are streamed, never accumulated in memory.

    Steps (all of them recorded in <WorkDir>\run_<yyyyMMdd_HHmmss>\inventory.sqlite):
      1) SharePoint site URLs: from -SiteUrlsCsv (GroupId/Url, recommended), or collected in a NEW WINDOW through
         SharePoint Admin (Get-SPOSite -Template GROUP#0, interactive sign-in). The interactive path has not been
         qualified outside a lab; its prerequisites are checked up front and the run fails clearly when missing.
      2) Group enumeration (Graph, Unified groups) with a checkpoint per committed page.
      3) Owners / members of every group (Graph $batch, runspace-parallel), written page by page through a single
         bounded writer; every list is checkpointed after commit and de-duplicated by directory object id.
      4) Reconciliation and seal. FAIL-CLOSED: if any source, page, worker or list is incomplete or any count does
         not reconcile, the run is NOT sealed and NO final file is produced (owners/members are never assumed
         empty). Problems are listed in _inv_graph_errors.csv; the run folder and database are kept.
      5) Export of the sealed run in Report.Formats (CSV and HTML default); optional -GridView.

    Resume: an interrupted or incomplete run (crash, throttling, Ctrl+C, failed lists) is continued with
    -ResumeRun <run folder>: completed lists are kept, only incomplete or failed lists (and an unfinished
    enumeration / site source) are collected again. A sealed run is only re-exported. Credentials are never stored
    in the database.

    Formats: CSV (UTF-8 with BOM, 12 columns: displayName, alias, primarySmtpAddress, groupType, sharePointUrl,
    visibility, externalDirectoryObjectId, owners, members, ownersCount, membersCount, ownerless) and HTML only.
    JSON and JSONL are no longer produced (the previous -Format JSON and -JsonArrayMax were removed on purpose:
    PowerShell rejects them with an explicit error). HTML is self-contained, split into interactive compressed
    chunks in one self-contained file by default. With -HtmlPartitioned it uses -HtmlRowsPerPart pages with an index. It supports search, relation filtering, sorting, virtual
    scrolling, group details and filtered CSV export. -HtmlMaxRelations controls only the visible relation preview;
    complete owner/member lists remain embedded in the compressed page data. The previous -HtmlMax (total row cap)
    no longer exists: all groups are in the HTML report.

    Auth: prefer Certificate; ClientSecretFile and ClientSecretEnvironment remain compatibility/lab modes.
    Secrets remain external. -ClientSecret is deprecated; never place a secret on a command line.

.PARAMETER WorkDir
    Compatibility override: base folder for run_<timestamp> snapshots and their exports/logs.
.PARAMETER DatabasePath
    Overrides Storage.DatabasePath (database basename and snapshot parent directory).
.PARAMETER OutputPath
    Overrides Report.OutputPath; one report subdirectory per snapshot.
.PARAMETER LogPath
    Overrides Logging.Path; one log subdirectory per snapshot.
.PARAMETER AuthMode
    Certificate, ClientSecretFile or ClientSecretEnvironment; overrides Authentication.Mode.
.PARAMETER CertificateThumbprint
    Certificate in Cert:\CurrentUser\My or Cert:\LocalMachine\My with a private signing key.
.PARAMETER CredFile
    Credentials JSON (TenantId/ClientId/ClientSecret). Overrides config.Authentication.CredentialsPath.
.PARAMETER ConfigPath
    PowerShell data configuration file. Default: config\M365GroupsReporting.config.psd1 next to this script.
.PARAMETER SkipMembers
    Do not collect members (owners are still collected). membersCount/members are left empty (not collected)
    rather than reported as 0. A resumed run keeps the setting it was created with unless you pass the opposite
    (which is then refused).
.PARAMETER Format
    CSV or HTML. Omitted: all Report.Formats (CSV and HTML by default). JSON/JSONL are not supported.
.PARAMETER GridView
    Also display (at most -GridViewMax rows of) the CSV in Out-GridView. With -Format HTML the CSV is exported too.
.PARAMETER SpoAdminUrl
    SharePoint Admin URL, e.g. https://contoso-admin.sharepoint.com (interactive path, requires Windows PowerShell
    5.1 with the Microsoft.Online.SharePoint.PowerShell module; not qualified outside a lab).
.PARAMETER SiteUrlsCsv
    Pre-collected GroupId/Url CSV (see Get-SiteUrls.ps1). Skips the SharePoint window.
.PARAMETER ResumeRun
    Run folder (or its inventory.sqlite) to continue instead of starting a new run.
.PARAMETER OverwriteExport
    Replace an export that already exists in the run folder (default: refuse).
.PARAMETER HtmlRowsPerPart
    Rows per HTML part file when -HtmlPartitioned is used (1-10000, default 10000).
.PARAMETER HtmlPartitioned
    Keep the legacy multi-file HTML layout. By default HTML is one self-contained interactive file, like PurviewDlpReport.
.PARAMETER HtmlMaxRelations
    Owners/members shown in the HTML grid preview (default 25); complete lists remain available for filtering/details.
.PARAMETER RawCsvValues
    Do not neutralise spreadsheet formulas (values starting with = + - @ or TAB get a leading apostrophe by default).
.PARAMETER NoRetention
    Do not apply the configured log/run retention policy for this execution.
.PARAMETER Max
    Collect only the first N groups (testing). The resulting inventory is a deliberate sample.
.EXAMPLE
    .\Build-Engine.ps1
    .\Invoke-M365GroupsReporting.ps1 -SiteUrlsCsv .\siteurls.csv
.EXAMPLE
    .\Invoke-M365GroupsReporting.ps1 -SiteUrlsCsv .\siteurls.csv -Format HTML
.EXAMPLE
    .\Invoke-M365GroupsReporting.ps1 -ResumeRun .\run_20261013_131042 -SiteUrlsCsv .\siteurls.csv
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $SpoAdminUrl,                       # required unless -SiteUrlsCsv or -ResumeRun is provided
    [string] $SiteUrlsCsv,                        # pre-collected GroupId/Url CSV (skips the SharePoint window)
    [ValidateSet('CSV','HTML')] [string[]] $Format,
    [switch] $GridView,

    [string] $WorkDir   = $PSScriptRoot,
    [string] $CredFile,
    [string] $ConfigPath = $(if ($PSScriptRoot) { Join-Path $PSScriptRoot 'config\M365GroupsReporting.config.psd1' } else { '' }),
    [string] $TenantId, [string] $ClientId, [string] $ClientSecret,
    [ValidateSet('Certificate','ClientSecretFile','ClientSecretEnvironment')][string] $AuthMode,
    [string] $CertificateThumbprint,
    [string] $DatabasePath, [string] $OutputPath, [string] $LogPath,

    [string] $ResumeRun,
    [switch] $OverwriteExport,
    [string] $OutName,
    [int]    $ThrottleLimit,
    [switch] $SkipMembers,
    [int]    $Max           = -1,
    [ValidateRange(1,10000)] [int] $HtmlRowsPerPart,
    [switch] $HtmlPartitioned,
    [ValidateRange(1,10000)] [int] $HtmlMaxRelations,
    [switch] $RawCsvValues,
    [int]    $GridViewMax   = 20000,
    [int]    $SpTimeoutMin,
    [switch] $NoRetention
)
$ErrorActionPreference = 'Stop'

function Resolve-M365GroupsPath {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Root)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([IO.Path]::IsPathRooted($expanded)) { return [IO.Path]::GetFullPath($expanded) }
    [IO.Path]::GetFullPath((Join-Path $Root $expanded))
}

function Import-M365GroupsConfiguration {
    param([Parameter(Mandatory)][string] $Path, [string] $Root = $PSScriptRoot)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuration file not found: $Path" }
    $c = Import-PowerShellDataFile -LiteralPath $Path
    function Assert-NoConfigSecret([hashtable] $Section) {
        foreach ($key in $Section.Keys) {
            if ($key -match '^(ClientSecret|Password|AccessToken|PrivateKey)$') { throw 'Secrets are forbidden in operational configuration; use an external credential source.' }
            if ($Section[$key] -is [hashtable]) { Assert-NoConfigSecret $Section[$key] }
        }
    }
    Assert-NoConfigSecret $c
    foreach ($section in 'Tenant','Authentication','Collection','Storage','Logging','Report') {
        if (-not $c.ContainsKey($section) -or $c[$section] -isnot [hashtable]) { throw "Configuration section '$section' is missing: $Path" }
    }
    foreach ($key in 'DatabasePath','RetentionDays','KeepIncompleteRuns') {
        if (-not $c.Storage.ContainsKey($key)) { throw "Storage.$key is required." }
    }
    foreach ($key in 'OutputPath','Formats','FilePrefix','CsvDelimiter','TimeZone','Title','CompanyName','ShowTenantInformation','EnvironmentName') {
        if (-not $c.Report.ContainsKey($key)) { throw "Report.$key is required." }
    }
    if ($c.Authentication.Mode -notin 'Certificate','ClientSecretFile','ClientSecretEnvironment') { throw 'Authentication.Mode is invalid.' }
    if ($c.Report.ContainsKey('Author') -or $c.Report.ContainsKey('AuthorName')) { throw 'Report author is fixed to Nicolas Fabert, not configurable.' }
    foreach ($item in @(@($c.Storage,'RetentionDays'), @($c.Logging,'RetentionDays'), @($c.Collection,'MaxGroups'))) {
        $n = 0
        if (-not [int]::TryParse([string]$item[0][$item[1]], [ref]$n) -or $n -lt 0 -or ($item[1] -eq 'RetentionDays' -and $n -gt 3650)) { throw "$($item[1]) must be a nonnegative integer (retention maximum: 3650 days)." }
    }
    foreach ($item in @(@($c.Storage,'KeepIncompleteRuns'), @($c.Report,'ShowTenantInformation'), @($c.Report,'HtmlPartitioned'), @($c.Report,'RawCsvValues'), @($c.Collection,'SkipMembers'))) {
        if ($item[0][$item[1]] -isnot [bool]) { throw "$($item[1]) must be a Boolean." }
    }
    foreach ($item in @(@($c.Collection,'ThrottleLimit',1,128), @($c.Collection,'SharePointTimeoutMinutes',1,1440), @($c.Report,'HtmlRowsPerPart',1,10000), @($c.Report,'HtmlMaxRelations',1,10000))) {
        $n = 0
        if (-not [int]::TryParse([string]$item[0][$item[1]], [ref]$n) -or $n -lt $item[2] -or $n -gt $item[3]) { throw "$($item[1]) must be between $($item[2]) and $($item[3])." }
    }
    if (@($c.Report.Formats).Count -eq 0 -or @($c.Report.Formats | Where-Object { $_ -notin 'CSV','HTML' }).Count) { throw 'Report.Formats must contain CSV and/or HTML.' }
    if ($c.Report.CsvDelimiter -notin ',', ';', '|', "`t") { throw 'Report.CsvDelimiter must be a comma, semicolon, pipe or tab.' }
    if (-not $c.Report.FilePrefix -or $c.Report.FilePrefix -in '.', '..' -or $c.Report.FilePrefix.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw 'Report.FilePrefix must be a valid filename part.' }
    [void][TimeZoneInfo]::FindSystemTimeZoneById($c.Report.TimeZone)
    $iana = ''
    if ([TimeZoneInfo]::TryConvertWindowsIdToIanaId($c.Report.TimeZone, [ref]$iana)) { $c.Report.TimeZone = $iana }
    foreach ($item in @(@($c.Storage,'DatabasePath'), @($c.Logging,'Path'), @($c.Report,'OutputPath'), @($c.Authentication,'CredentialsPath'))) {
        $item[0][$item[1]] = Resolve-M365GroupsPath -Path $item[0][$item[1]] -Root $Root
    }
    if ([IO.Path]::GetExtension($c.Storage.DatabasePath) -ne '.sqlite') { throw 'Storage.DatabasePath must have a .sqlite extension.' }
    $c
}

$configuration = Import-M365GroupsConfiguration -Path $ConfigPath -Root $PSScriptRoot
if (-not $PSBoundParameters.ContainsKey('DatabasePath')) { $DatabasePath = $configuration.Storage.DatabasePath }
$DatabasePath = [IO.Path]::GetFullPath($DatabasePath)
if (-not $PSBoundParameters.ContainsKey('WorkDir') -or $PSBoundParameters.ContainsKey('DatabasePath')) { $WorkDir = Split-Path -Parent $DatabasePath }
if (-not $PSBoundParameters.ContainsKey('OutputPath')) { $OutputPath = $configuration.Report.OutputPath }
if (-not $PSBoundParameters.ContainsKey('LogPath')) { $LogPath = $configuration.Logging.Path }
if (-not $PSBoundParameters.ContainsKey('CredFile')) { $CredFile = $configuration.Authentication.CredentialsPath }
if (-not $PSBoundParameters.ContainsKey('Format')) { $Format = [string[]]$configuration.Report.Formats }
if (-not $PSBoundParameters.ContainsKey('TenantId')) { $TenantId = $configuration.Tenant.TenantId }
if (-not $PSBoundParameters.ContainsKey('ClientId')) { $ClientId = $configuration.Authentication.AppId }
if (-not $PSBoundParameters.ContainsKey('AuthMode')) { $AuthMode = $configuration.Authentication.Mode }
if (-not $PSBoundParameters.ContainsKey('CertificateThumbprint')) { $CertificateThumbprint = $configuration.Authentication.CertificateThumbprint }
if (-not $PSBoundParameters.ContainsKey('SpoAdminUrl')) { $SpoAdminUrl = $configuration.Tenant.SharePointAdminUrl }
if (-not $PSBoundParameters.ContainsKey('ThrottleLimit')) { $ThrottleLimit = [int]$configuration.Collection.ThrottleLimit }
if (-not $PSBoundParameters.ContainsKey('Max')) { $Max = [int]$configuration.Collection.MaxGroups }
if ($Max -lt 0) { $Max = 0 }
if (-not $PSBoundParameters.ContainsKey('HtmlRowsPerPart')) { $HtmlRowsPerPart = [int]$configuration.Report.HtmlRowsPerPart }
if (-not $PSBoundParameters.ContainsKey('HtmlMaxRelations')) { $HtmlMaxRelations = [int]$configuration.Report.HtmlMaxRelations }
if (-not $PSBoundParameters.ContainsKey('SpTimeoutMin')) { $SpTimeoutMin = [int]$configuration.Collection.SharePointTimeoutMinutes }
if (-not $PSBoundParameters.ContainsKey('OutName')) { $OutName = [string]$configuration.Report.FilePrefix }
if (-not $PSBoundParameters.ContainsKey('HtmlPartitioned')) { $HtmlPartitioned = [bool]$configuration.Report.HtmlPartitioned }
if (-not $PSBoundParameters.ContainsKey('RawCsvValues')) { $RawCsvValues = [bool]$configuration.Report.RawCsvValues }
if (-not $PSBoundParameters.ContainsKey('SkipMembers')) { $SkipMembers = [bool]$configuration.Collection.SkipMembers }
if (-not $OutName -or $OutName -in '.', '..' -or $OutName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw 'OutName must be a valid filename part.' }
if ($ThrottleLimit -lt 1 -or $ThrottleLimit -gt 128 -or $SpTimeoutMin -lt 1 -or $HtmlRowsPerPart -lt 1 -or $HtmlMaxRelations -lt 1) { throw 'Collection/report overrides must be positive and within their supported bounds.' }

# ================================================================== #
#  Graph collection helpers (the worker ones are also loaded into the
#  runspaces of the parallel collection, see Invoke-ListCollection).
#  Policy: FAIL-CLOSED. A failed/missing owners or members result is never
#  turned into an empty list or a zero count: it is stored as a failed list.
# ================================================================== #
function Get-HttpErrorInfo {
    param($ErrorRecord)
    $code = 0; $retryAfter = 0
    $resp = $null
    if ($ErrorRecord -and $ErrorRecord.Exception) { $resp = $ErrorRecord.Exception.Response }
    if ($resp) {
        try { $code = [int]$resp.StatusCode } catch { $code = 0 }
        $v = $null
        try {
            $h = $resp.Headers
            if ($h) {
                try { $v = $h['Retry-After'] } catch { $v = $null }
                if (-not $v -and $h.PSObject.Methods['TryGetValues']) {
                    $vals = $null
                    if ($h.TryGetValues('Retry-After', [ref]$vals)) { $v = @($vals)[0] }
                }
            }
        } catch { $v = $null }
        if ($v) { [void][int]::TryParse([string]@($v)[0], [ref]$retryAfter) }
    }
    [pscustomobject]@{ Code = $code; RetryAfter = $retryAfter }
}

function Get-GraphAppToken {
    param([Parameter(Mandatory)][hashtable] $Creds)
    $uri = "https://login.microsoftonline.com/$($Creds.TenantId)/oauth2/v2.0/token"
    $body = @{ client_id = $Creds.ClientId; scope = 'https://graph.microsoft.com/.default'; grant_type = 'client_credentials' }
    if ($Creds.Mode -eq 'Certificate') {
        $cert = $null
        foreach ($store in 'Cert:\CurrentUser\My','Cert:\LocalMachine\My') {
            $candidate = Get-Item -LiteralPath (Join-Path $store $Creds.CertificateThumbprint) -ErrorAction SilentlyContinue
            if ($candidate -and $candidate.HasPrivateKey) { $cert = $candidate; break }
        }
        if (-not $cert -or $cert.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow -or $cert.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow) { throw 'Certificate authentication requires a currently valid certificate with a private key.' }
        $b64 = { param([byte[]]$Bytes) [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_') }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $header = @{ alg='RS256'; typ='JWT'; x5t=(& $b64 $cert.GetCertHash()) } | ConvertTo-Json -Compress
        $payload = @{ aud=$uri; iss=$Creds.ClientId; sub=$Creds.ClientId; jti=[guid]::NewGuid().ToString(); nbf=$now-60; exp=$now+300 } | ConvertTo-Json -Compress
        $unsigned = (& $b64 ([Text.Encoding]::UTF8.GetBytes($header))) + '.' + (& $b64 ([Text.Encoding]::UTF8.GetBytes($payload)))
        $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        try { $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($unsigned), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1) }
        finally { if ($rsa) { $rsa.Dispose() }; $cert.Dispose() }
        $body.client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        $body.client_assertion = $unsigned + '.' + (& $b64 $signature)
    } else { $body.client_secret = $Creds.ClientSecret }
    try { $r = Invoke-RestMethod -Method POST -Uri $uri -Body $body -ContentType 'application/x-www-form-urlencoded' }
    catch { throw 'Graph authentication failed. Check tenant, application permission/consent and external credential or certificate; authentication response details are intentionally suppressed.' }
    if (-not $r -or -not $r.access_token) { throw 'The token endpoint did not return an access token.' }
    $secs = 3600; if ($r.expires_in) { $secs = [int]$r.expires_in }
    [pscustomobject]@{ Token = [string]$r.access_token; Expires = (Get-Date).AddSeconds([Math]::Max(60, $secs - 300)) }
}

# One Graph call with bounded retries: 401 -> at most $MaxAuthRefresh token refreshes;
# 429/5xx -> up to $MaxRetry attempts with Retry-After / exponential backoff. Anything else throws.
function Invoke-GraphRequest {
    param(
        [Parameter(Mandatory)][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][hashtable] $Auth,
        [string] $BodyJson,
        [hashtable] $ExtraHeaders,
        [int] $MaxRetry = 8,
        [int] $MaxAuthRefresh = 2
    )
    $attempt = 0; $refreshes = 0
    while ($true) {
        $attempt++
        try {
            $h = @{ Authorization = "Bearer $($Auth.Token)" }
            if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $h[$k] = $ExtraHeaders[$k] } }
            if ($BodyJson) { return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $h -Body $BodyJson -ContentType 'application/json' }
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $h
        } catch {
            $info = Get-HttpErrorInfo $_
            if ($info.Code -eq 401 -and $refreshes -lt $MaxAuthRefresh) {
                $refreshes++
                $t = Get-GraphAppToken -Creds $Auth.Creds
                $Auth.Token = $t.Token; $Auth.Expires = $t.Expires
                continue
            }
            if (($info.Code -eq 429 -or $info.Code -ge 500) -and $attempt -lt $MaxRetry) {
                $wait = $info.RetryAfter
                if ($wait -le 0) { $wait = [Math]::Min(60, [Math]::Pow(2, $attempt)) }
                Start-Sleep -Seconds ([Math]::Min(300, $wait))
                continue
            }
            throw
        }
    }
}

# Sends the sub-requests through $batch. Returns a hashtable id -> sub-response. 429/5xx (and
# sub-requests missing from the answer) are retried (bounded); an id that is still unresolved is
# either absent from the result (no answer) or holds its last 429/5xx answer: callers must treat
# both as failures. A sub-response 401 (token expired mid-run under an outer HTTP 200) triggers at
# most $MaxAuthRefresh token refreshes for the whole call; only the affected requests are retried
# and a 401 that persists is returned as a terminal (failed) sub-response.
function Invoke-GraphBatch {
    param(
        [Parameter(Mandatory)] $Requests,
        [Parameter(Mandatory)][hashtable] $Auth,
        [int] $MaxRetry = 8,
        [int] $MaxAuthRefresh = 2
    )
    $final = @{}; $last = @{}
    $pending = @($Requests); $attempt = 0; $refreshes = 0
    while ($pending.Count -gt 0 -and $attempt -lt $MaxRetry) {
        $attempt++
        $payload = @{ requests = @($pending | ForEach-Object { @{ id = $_.id; method = 'GET'; url = $_.url } }) }
        $resp = Invoke-GraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/$batch' -Auth $Auth -BodyJson ($payload | ConvertTo-Json -Depth 6 -Compress) -MaxRetry $MaxRetry
        $maxRA = 0; $authRetry = @{}
        foreach ($sub in @($resp.responses)) {
            if (-not $sub -or $null -eq $sub.id) { continue }
            $id = [string]$sub.id; $code = 0
            try { $code = [int]$sub.status } catch { $code = 0 }
            if ($code -eq 401) {
                $last[$id] = $sub
                if ($refreshes -lt $MaxAuthRefresh) { $authRetry[$id] = $true } else { $final[$id] = $sub }
            } elseif ($code -eq 429 -or $code -ge 500) {
                $last[$id] = $sub
                $ra = 0
                if ($sub.headers -and $sub.headers.'Retry-After') { [void][int]::TryParse([string]$sub.headers.'Retry-After', [ref]$ra) }
                if ($ra -gt $maxRA) { $maxRA = $ra }
            } else { $final[$id] = $sub }
        }
        if ($authRetry.Count -gt 0) {
            $refreshes++
            $t = Get-GraphAppToken -Creds $Auth.Creds
            $Auth.Token = $t.Token; $Auth.Expires = $t.Expires
        }
        $pending = @($pending | Where-Object { -not $final.ContainsKey([string]$_.id) })
        $needBackoff = @($pending | Where-Object { -not $authRetry.ContainsKey([string]$_.id) }).Count -gt 0
        if ($pending.Count -gt 0 -and $needBackoff -and $attempt -lt $MaxRetry) {
            $w = $maxRA
            if ($w -le 0) { $w = [Math]::Min(60, [Math]::Pow(2, $attempt)) }
            Start-Sleep -Seconds ([Math]::Min(300, $w))
        }
    }
    foreach ($id in @($last.Keys)) { if (-not $final.ContainsKey($id)) { $final[$id] = $last[$id] } }
    return $final
}


# Worker script of the interactive SharePoint Admin window (runs in its own Windows PowerShell 5.1 process).
$SpoWorkerCode = @'
param($AdminUrl,$OutCsv,$Marker,$LogPath)
$ErrorActionPreference = "Stop"
Start-Transcript -Path $LogPath -Force | Out-Null
try {
    Import-Module Microsoft.Online.SharePoint.PowerShell -ErrorAction Stop
    $connected = $false
    try { Get-SPOTenant -ErrorAction Stop | Out-Null; $connected = $true } catch {}
    if (-not $connected) { Write-Host "Connecting to SharePoint Admin ($AdminUrl)..." -ForegroundColor Cyan; Connect-SPOService -Url $AdminUrl -ModernAuth $true -UseSystemBrowser $true }
    Write-Host "Running Get-SPOSite -Template GROUP#0 -Limit All ..." -ForegroundColor Cyan
    $sites = Get-SPOSite -Template "GROUP#0" -Limit All
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($s in $sites) { $gid=[string]$s.GroupId; if ($gid -and $gid -ne "00000000-0000-0000-0000-000000000000") { $rows.Add([pscustomobject]@{ GroupId=$gid; Url=[string]$s.Url }) } }
    if ($rows.Count -eq 0) { throw "SharePoint returned no GROUP#0 site URLs; refusing to mark the source complete." }
    @($rows) | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8
    "OK $($rows.Count)" | Out-File -FilePath $Marker -Encoding utf8
    Write-Host "SharePoint OK: $($rows.Count) group sites -> $OutCsv" -ForegroundColor Green
    Write-Host "You can close this window." -ForegroundColor Yellow
} catch {
    $detail = "FAIL: $($_.Exception.GetType().FullName): $($_.Exception.Message)`r`nAt: $($_.InvocationInfo.PositionMessage)`r`nStack: $($_.ScriptStackTrace)"
    $detail | Out-File -FilePath $Marker -Encoding utf8
    Write-Host $detail -ForegroundColor Red
    if ($_.Exception.Message -match 'nauthor|denied|Access') { Write-Host "HINT: the signed-in account must be an ACTIVE SharePoint/Global Administrator (sign in with that account; activate the role via PIM if required)." -ForegroundColor Yellow }
    Write-Host "Window kept open for diagnostics." -ForegroundColor Yellow
} finally { try { Stop-Transcript | Out-Null } catch {} }
'@

# Reads one directory-object list (owners or members) of a group and writes it page by page to the engine.
# The first page comes from the $batch answer ($Sub); further pages are fetched one by one. Any problem
# (missing/failed answer, malformed page, pagination failure, engine rejection) marks the list FAILED in the
# engine; nothing is ever turned into an empty list. The engine stores, de-duplicates by object id and checks
# the declared total on the final page.
function Write-GraphListToEngine {
    param(
        [Parameter(Mandatory)] $Engine,
        [Parameter(Mandatory)][string] $GroupId,
        [Parameter(Mandatory)][int] $Kind,
        $Sub,
        [Parameter(Mandatory)][hashtable] $Auth,
        [int] $MaxRetry = 8,
        [string] $BatchError
    )
    if (-not $Sub) {
        $msg = 'No result returned for this request (missing batch response).'
        if ($BatchError) { $msg = "Batch request failed: $BatchError" }
        [void]$Engine.FailList($GroupId, $Kind, 0, $msg)
        return [pscustomobject]@{ Ok = $false; Status = 0; Error = $msg; Count = 0 }
    }
    $status = 0
    try { $status = [int]$Sub.status } catch { $status = 0 }
    if ($status -lt 200 -or $status -ge 300) {
        $detail = ''
        if ($Sub.body -and $Sub.body.error) { $detail = ": $($Sub.body.error.code) $($Sub.body.error.message)" }
        $msg = "HTTP $status$detail"
        [void]$Engine.FailList($GroupId, $Kind, $status, $msg)
        return [pscustomobject]@{ Ok = $false; Status = $status; Error = $msg; Count = 0 }
    }
    $page = $Sub.body
    $seq = 0; $declared = 0
    try {
        while ($true) {
            if ($null -eq $page -or -not $page.PSObject.Properties['value']) { throw 'Graph returned an empty or malformed list page.' }
            $ids = New-Object System.Collections.Generic.List[string]
            $vals = New-Object System.Collections.Generic.List[string]
            foreach ($v in @($page.value)) {
                if ($null -eq $v) { continue }
                $id = [string]$v.id
                if (-not $id) { throw 'A directory object without id was returned.' }
                $x = $v.userPrincipalName; if (-not $x) { $x = $v.displayName }; if (-not $x) { $x = $id }
                $ids.Add($id); $vals.Add([string]$x)
            }
            $declared += $ids.Count
            $next = $page.'@odata.nextLink'
            $final = -not $next
            $cursor = ''; if ($next) { $cursor = [string]$next }
            $r = $Engine.AppendListPage($GroupId, $Kind, [int64]$seq, $ids.ToArray(), $vals.ToArray(), $cursor, [bool]$final, [int64]$declared)
            if ($r.IsFailed) {
                return [pscustomobject]@{ Ok = $false; Status = 0; Error = "Rejected by the engine: $($r.Message)"; Count = 0 }
            }
            $seq++
            if ($final) { break }
            $page = Invoke-GraphRequest -Method GET -Uri $next -Auth $Auth -MaxRetry $MaxRetry
        }
    } catch {
        $info = Get-HttpErrorInfo $_
        $msg = "Pagination/read failure: $($_.Exception.Message)"
        [void]$Engine.FailList($GroupId, $Kind, [int]$info.Code, $msg)
        return [pscustomobject]@{ Ok = $false; Status = $info.Code; Error = $msg; Count = 0 }
    }
    return [pscustomobject]@{ Ok = $true; Status = $status; Error = ''; Count = $declared }
}

# Worker body: collects the owners (+members) lists still needed by a slice of groups and stores them through the
# engine. Never throws for a Graph problem and never invents data: a failed read leaves the list FAILED in the
# engine. Slice items need GroupId, DisplayName, NeedOwners, NeedMembers (engine WorkItem objects do).
# With -SkipMembers no members request is sent (the engine marks those lists as not collected).
function Save-GroupInventoryLists {
    param(
        [Parameter(Mandatory)] $Slice,
        [Parameter(Mandatory)] $Engine,
        [Parameter(Mandatory)][hashtable] $Auth,
        [bool] $SkipMembers = $false,
        [int] $MaxRetry = 8
    )
    $reqs = New-Object System.Collections.Generic.List[object]
    foreach ($g in @($Slice)) {
        $gid = [string]$g.GroupId
        if ($g.NeedOwners) { $reqs.Add(@{ id = "$gid|own"; url = "/groups/$gid/owners?`$select=id,userPrincipalName,displayName&`$top=999" }) }
        if ($g.NeedMembers -and -not $SkipMembers) { $reqs.Add(@{ id = "$gid|mem"; url = "/groups/$gid/members?`$select=id,userPrincipalName,displayName&`$top=999" }) }
    }
    $res = @{}; $batchError = $null
    if ($reqs.Count -gt 0) {
        try { $res = Invoke-GraphBatch -Requests $reqs.ToArray() -Auth $Auth -MaxRetry $MaxRetry }
        catch { $batchError = $_.Exception.Message }
    }
    $ok = 0; $failed = 0
    $notFound = New-Object System.Collections.Generic.List[string]
    foreach ($g in @($Slice)) {
        $gid = [string]$g.GroupId
        if ($g.NeedOwners) {
            $r = Write-GraphListToEngine -Engine $Engine -GroupId $gid -Kind 1 -Sub $res["$gid|own"] -Auth $Auth -MaxRetry $MaxRetry -BatchError $batchError
            if ($r.Ok) { $ok++ } elseif ($r.Status -eq 404) { $failed++; $notFound.Add($gid) } else { $failed++ }
        }
        if ($g.NeedMembers -and -not $SkipMembers) {
            $r = Write-GraphListToEngine -Engine $Engine -GroupId $gid -Kind 2 -Sub $res["$gid|mem"] -Auth $Auth -MaxRetry $MaxRetry -BatchError $batchError
            if ($r.Ok) { $ok++ } elseif ($r.Status -eq 404) { $failed++; if (-not $notFound.Contains($gid)) { $notFound.Add($gid) } } else { $failed++ }
        }
    }
    $removed = 0
    foreach ($gid in @($notFound | Select-Object -Unique)) {
        try {
            Invoke-GraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$gid?`$select=id" -Auth $Auth -MaxRetry $MaxRetry | Out-Null
        } catch {
            $info = Get-HttpErrorInfo $_
            if ($info.Code -ne 404) { throw "The group $gid returned HTTP 404 for a list, but the disappearance check failed with HTTP $($info.Code): $($_.Exception.Message)" }
            [void]$Engine.RemoveGroup($gid, "Graph confirmed that the group disappeared during owners/members collection.")
            $removed++
        }
    }
    return [pscustomobject]@{ Groups = @($Slice).Count; ListsOk = $ok; ListsFailed = $failed; GroupsRemoved = $removed }
}

# Fail-closed gate: seals the run only when every flow and list is complete and reconciled. Otherwise it writes the
# errors CSV and throws: no final file, the run folder and database are preserved for -ResumeRun.
function Complete-InventoryRun {
    param([Parameter(Mandatory)] $Engine, [string] $ErrorsCsv)
    $seal = $Engine.Seal()
    if ($seal.IsSealed) {
        if ($ErrorsCsv -and (Test-Path -LiteralPath $ErrorsCsv)) { Remove-Item -LiteralPath $ErrorsCsv -Force -ErrorAction Stop }
        return $seal
    }
    $f = @($seal.Reconcile.Failures)
    $note = ''
    if ($f.Count -gt 0 -and $ErrorsCsv) {
        try { $f | Select-Object GroupId, GroupName, Request, Status, Message | Export-Csv -Path $ErrorsCsv -NoTypeInformation -Encoding UTF8; $note = " Details: $ErrorsCsv." }
        catch { $note = " (the errors file could not be written: $($_.Exception.Message))" }
    }
    $bad = @($f | Where-Object { $_.GroupId } | Select-Object -ExpandProperty GroupId -Unique).Count
    $sample = (@($f | Select-Object -First 3 | ForEach-Object { "[$($_.Request)] $($_.GroupId): $($_.Message)" })) -join ' | '
    throw "Graph collection INCOMPLETE: $($seal.Message) ($($f.Count) failure(s) on $bad group(s)). No verified inventory was produced; owners/members were NOT assumed empty.$note First: $sample. Re-run with -ResumeRun <run folder> to collect only what is incomplete."
}

# ================================================================== #
#  Engine hosting
# ================================================================== #
function Import-GroupInventoryEngine {
    param([string] $EngineDir)
    if ('GroupInventory.Engine.InventoryEngine' -as [type]) { return }
    if (-not $EngineDir) {
        $EngineDir = Join-Path $PSScriptRoot 'lib\engine'
        if (-not (Test-Path -LiteralPath (Join-Path $EngineDir 'GroupInventory.Engine.dll'))) { $EngineDir = Join-Path $PSScriptRoot 'engine\bin' }
    }
    $dll = Join-Path $EngineDir 'GroupInventory.Engine.dll'
    if (-not (Test-Path -LiteralPath $dll)) { throw "The inventory engine is not built: $dll not found. Run .\Build-Engine.ps1 first (offline, nothing is downloaded)." }
    foreach ($n in 'SQLitePCLRaw.core', 'SQLitePCLRaw.provider.e_sqlite3', 'SQLitePCLRaw.batteries_v2', 'Microsoft.Data.Sqlite', 'GroupInventory.Engine') {
        $p = Join-Path $EngineDir "$n.dll"
        if (-not (Test-Path -LiteralPath $p)) { throw "Engine file missing: $p. Run .\Build-Engine.ps1." }
        [void][System.Reflection.Assembly]::LoadFrom($p)
    }
    if (-not ('GroupInventory.Engine.InventoryEngine' -as [type])) { throw 'The inventory engine assembly could not be loaded.' }
}

function Open-InventoryRun {
    param(
        [Parameter(Mandatory)][string] $DatabasePath,
        [string] $RunId,
        [bool] $SkipMembers = $false,
        [bool] $AdoptRunSettings = $false,
        [bool] $Resume = $false
    )
    $o = New-Object GroupInventory.Engine.EngineOptions
    $o.DatabasePath = $DatabasePath
    $o.RunId = $RunId
    $o.SkipMembers = $SkipMembers
    $o.AdoptRunSettings = $AdoptRunSettings
    if ($Resume) { return [GroupInventory.Engine.InventoryEngine]::Resume($o) }
    return [GroupInventory.Engine.InventoryEngine]::Create($o)
}

function New-GraphAuth {
    param([Parameter(Mandatory)][hashtable] $Creds)
    $t = Get-GraphAppToken -Creds $Creds
    return @{ Creds = $Creds; Token = $t.Token; Expires = $t.Expires }
}

function Update-GraphAuth {
    param([Parameter(Mandatory)][hashtable] $Auth)
    if ((Get-Date) -ge $Auth.Expires) {
        $nt = Get-GraphAppToken -Creds $Auth.Creds
        $Auth.Token = $nt.Token; $Auth.Expires = $nt.Expires
        Write-Host "  (token refreshed)" -ForegroundColor DarkGray
    }
    return $Auth.Token
}

function ConvertTo-GroupRecord {
    param([Parameter(Mandatory)] $Group)
    $rpo = @(); if ($Group.resourceProvisioningOptions) { $rpo = @($Group.resourceProvisioningOptions) }
    $r = New-Object GroupInventory.Engine.GroupRecord
    $r.Id = [string]$Group.id; $r.DisplayName = [string]$Group.displayName; $r.Alias = [string]$Group.mailNickname
    $r.Mail = [string]$Group.mail; $r.Visibility = [string]$Group.visibility; $r.IsTeam = ($rpo -contains 'Team')
    return $r
}

# ================================================================== #
#  Group enumeration (Graph) -> engine, one checkpoint per committed page.
#  Resume: continues from the stored cursor; if Graph rejects it the enumeration restarts from page 0
#  (groups already stored are de-duplicated; groups that disappeared are removed when the pass completes).
# ================================================================== #
function Invoke-GroupEnumeration {
    param(
        [Parameter(Mandatory)] $Engine,
        [Parameter(Mandatory)][hashtable] $Auth,
        [int] $Max = 0,
        [int] $MaxRetry = 8
    )
    $first = "https://graph.microsoft.com/v1.0/groups?`$filter=groupTypes/any(c:c eq 'Unified')&`$select=id,displayName,mailNickname,mail,visibility,resourceProvisioningOptions&`$top=999&`$count=true"
    $flow = $Engine.GetFlow('enum')
    if ($flow.State -eq 'Complete') {
        Write-Host "Group enumeration already complete ($($flow.RowsSeen) rows): skipped." -ForegroundColor DarkGray
        return [int64]$flow.RowsSeen
    }
    if ($flow.State -eq 'Failed') {
        Write-Host "Previous enumeration failed ($($flow.Message)); restarting it." -ForegroundColor Yellow
        [void]$Engine.ResetFlow('enum'); $flow = $Engine.GetFlow('enum')
    }
    $uri = $first; $seq = [int64]$flow.NextPage; $total = [int64]$flow.RowsSeen; $resuming = $false
    if ($flow.State -eq 'Collecting') {
        if ($flow.Cursor) { $uri = [string]$flow.Cursor; $resuming = $true; Write-Host "Resuming the enumeration at page $seq ($total rows already committed)." -ForegroundColor Cyan }
        else { $uri = $null }   # the last committed page was the final one
    }
    Write-Host "Enumerating M365 groups (Unified)..." -ForegroundColor Cyan
    $stop = $false
    while ($uri -and -not $stop) {
        [void](Update-GraphAuth -Auth $Auth)
        try { $resp = Invoke-GraphRequest -Method GET -Uri $uri -Auth $Auth -ExtraHeaders @{ ConsistencyLevel = 'eventual' } -MaxRetry $MaxRetry }
        catch {
            if (-not $resuming) { throw }
            Write-Host "  the stored enumeration cursor was rejected ($($_.Exception.Message)); restarting the enumeration from page 0." -ForegroundColor Yellow
            [void]$Engine.ResetFlow('enum')
            $uri = $first; $seq = 0; $total = 0; $resuming = $false
            continue
        }
        $resuming = $false
        if ($null -eq $resp -or -not $resp.PSObject.Properties['value']) { throw 'Group enumeration returned an empty or malformed page.' }
        $recs = New-Object System.Collections.Generic.List[object]
        foreach ($g in @($resp.value)) {
            $recs.Add((ConvertTo-GroupRecord -Group $g))
            if ($Max -gt 0 -and ($total + $recs.Count) -ge $Max) { $stop = $true; break }
        }
        $next = $resp.'@odata.nextLink'
        $cursor = ''; if ($next -and -not $stop) { $cursor = [string]$next }
        $r = $Engine.AddGroupPage([int64]$seq, [GroupInventory.Engine.GroupRecord[]]$recs.ToArray(), $cursor)
        if ($r.IsFailed) { throw "Group enumeration page $seq was rejected by the engine: $($r.Message)" }
        if ($r.Status -eq 'Applied') { $total += $recs.Count }
        $seq++
        $uri = $cursor
        Write-Host ("   .. enumeration page {0}: {1} groups committed" -f $seq, $total) -ForegroundColor DarkGray
    }
    $c = $Engine.CompleteFlow('enum', [int64]$total)
    if ($c.IsFailed) { throw "Group enumeration could not be completed: $($c.Message)" }
    if ($c.Message) { Write-Host "  $($c.Message)" -ForegroundColor Yellow }
    Write-Host "Group enumeration complete: $total group rows." -ForegroundColor Green
    return [int64]$total
}

# ================================================================== #
#  Owners / members collection: app-only, runspace-parallel workers -> the engine's single bounded writer.
#  The work list comes from the engine (every list that is pending, interrupted or failed), so a fresh run and
#  a resumed run take the same path. -Sequential runs the worker in-process (offline tests).
# ================================================================== #
function Invoke-ListCollection {
    param(
        [Parameter(Mandatory)] $Engine,
        [Parameter(Mandatory)][hashtable] $Auth,
        [int]    $ThrottleLimit  = 12,
        [int]    $GraphBatchSize = 20,
        [switch] $SkipMembers,
        [int]    $MaxRetry = 8,
        [switch] $Sequential
    )
    if ($ThrottleLimit -lt 1) { $ThrottleLimit = 1 }
    $callsPerGroup  = 1 + $(if ($SkipMembers) {0} else {1})
    $groupsPerBatch = [int][Math]::Max(1, [Math]::Floor($GraphBatchSize / $callsPerGroup))
    $info = $Engine.Info()
    $todo = [int64]($info.ListsPending + $info.ListsCollecting + $info.ListsFailed)
    $st = @{ Groups = 0; Ok = 0; Failed = 0; WorkerErrors = 0 }
    if ($todo -eq 0) {
        Write-Host 'Owners/members: every list is already complete.' -ForegroundColor DarkGray
        return [pscustomobject]$st
    }
    Write-Host "Threads=$ThrottleLimit | batch=$GraphBatchSize sub-req -> $groupsPerBatch groups/batch | lists to collect: $todo (owners$(if(-not $SkipMembers){'+members'}))" -ForegroundColor Cyan

    $worker = {
        param($Slice, $InitToken, $Creds, $SkipMembers, $MaxRetry, $Engine)
        $ErrorActionPreference = 'Stop'
        $auth = @{ Token = $InitToken; Creds = $Creds }
        Save-GroupInventoryLists -Slice $Slice -Engine $Engine -Auth $auth -SkipMembers:([bool]$SkipMembers) -MaxRetry $MaxRetry
    }
    $pool = $null
    $jobs = New-Object System.Collections.Generic.List[object]
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not $Sequential) {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($fn in @('Get-HttpErrorInfo','Get-GraphAppToken','Invoke-GraphRequest','Invoke-GraphBatch','Write-GraphListToEngine','Save-GroupInventoryLists')) {
            $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn, (Get-Item "Function:\$fn").ScriptBlock.ToString())))
        }
        $pool = [runspacefactory]::CreateRunspacePool(1, $ThrottleLimit, $iss, $Host); $pool.Open()
    }
    $maxInFlight = $ThrottleLimit * 3

    function Register-SliceFailure {
        param($Slice, [string] $Message)
        $st.WorkerErrors++
        Write-Host "  worker error: $Message" -ForegroundColor DarkYellow
        [void]$Engine.FailGroups([string[]]@(@($Slice) | ForEach-Object { [string]$_.GroupId }), "Worker failed: $Message")
    }
    function Add-SliceResult {
        param($Result)
        if ($Result) { $st.Groups += [int]$Result.Groups; $st.Ok += [int]$Result.ListsOk; $st.Failed += [int]$Result.ListsFailed }
    }
    function Drain {
        param([switch]$All)
        $again = $true
        while ($again) {
            $again = $false
            for ($k = $jobs.Count - 1; $k -ge 0; $k--) {
                $j = $jobs[$k]
                if (-not $j.Handle.IsCompleted) { continue }
                $out = @(); $werr = $null
                try {
                    $out = @($j.PS.EndInvoke($j.Handle))
                    if ($j.PS.Streams.Error.Count -gt 0) { $werr = "worker reported $($j.PS.Streams.Error.Count) error(s): $($j.PS.Streams.Error[0].Exception.Message)" }
                } catch { $werr = $_.Exception.Message }
                finally { $j.PS.Dispose(); $jobs.RemoveAt($k) }
                if ($werr) { Register-SliceFailure -Slice $j.Slice -Message $werr }
                else { Add-SliceResult -Result ($out | Select-Object -Last 1) }
            }
            if ($All -and $jobs.Count -gt 0) { Start-Sleep -Milliseconds 150; $again = $true }
        }
    }
    function Submit-Slice {
        param($Slice)
        if ($Sequential) {
            try { Add-SliceResult -Result (Save-GroupInventoryLists -Slice $Slice -Engine $Engine -Auth $Auth -SkipMembers:([bool]$SkipMembers) -MaxRetry $MaxRetry) }
            catch { Register-SliceFailure -Slice $Slice -Message $_.Exception.Message }
            return
        }
        $tok = Update-GraphAuth -Auth $Auth
        $ps = [powershell]::Create(); $ps.RunspacePool = $pool
        [void]$ps.AddScript([string]$worker)
        [void]$ps.AddArgument($Slice)
        [void]$ps.AddArgument([string]$tok)
        [void]$ps.AddArgument($Auth.Creds)
        [void]$ps.AddArgument([bool]$SkipMembers)
        [void]$ps.AddArgument([int]$MaxRetry)
        [void]$ps.AddArgument($Engine)
        $h = $ps.BeginInvoke()
        $jobs.Add(@{ PS = $ps; Handle = $h; Slice = $Slice })
        while ($jobs.Count -ge $maxInFlight) { Drain; if ($jobs.Count -ge $maxInFlight) { Start-Sleep -Milliseconds 100 } }
    }

    $after = [int64]0
    $pageSize = [int]($groupsPerBatch * $ThrottleLimit * 4)
    try {
        while ($true) {
            $items = @($Engine.GetWorkBatch($after, $pageSize))
            if ($items.Count -eq 0) { break }
            $after = [int64]$items[$items.Count - 1].Gid
            for ($i = 0; $i -lt $items.Count; $i += $groupsPerBatch) {
                $end = [Math]::Min($i + $groupsPerBatch, $items.Count) - 1
                Submit-Slice -Slice @($items[$i..$end])
            }
            Drain
            $done = $st.Ok + $st.Failed
            $rate = [Math]::Round($done / [Math]::Max(1, $sw.Elapsed.TotalSeconds), 1)
            $pct = [Math]::Min(100, [int](100 * $done / [Math]::Max(1, $todo)))
            Write-Progress -Id 1 -Activity 'Owners/members collection' -Status ("{0}/{1} lists | {2} lists/s | {3} in flight | failed {4}" -f $done, $todo, $rate, $jobs.Count, $st.Failed) -PercentComplete $pct
            Write-Host ("   .. {0}/{1} lists | {2} lists/s | inflight={3} | failed={4}" -f $done, $todo, $rate, $jobs.Count, $st.Failed) -ForegroundColor DarkGray
        }
        Drain -All
    } finally {
        if ($pool) { $pool.Close(); $pool.Dispose() }
        Write-Progress -Id 1 -Activity 'Owners/members collection' -Completed
    }
    $sw.Stop()
    Write-Host ("Owners/members collection finished: {0} lists written, {1} failed, {2} worker error(s), {3} min." -f $st.Ok, $st.Failed, $st.WorkerErrors, [Math]::Round($sw.Elapsed.TotalMinutes, 2)) -ForegroundColor Green
    return [pscustomobject]$st
}

# ================================================================== #
#  SharePoint site URLs -> engine (streamed from a GroupId/Url CSV, bounded pages)
# ================================================================== #
function Import-SiteUrlsToEngine {
    param(
        [Parameter(Mandatory)] $Engine,
        [Parameter(Mandatory)][string] $Path,
        [int] $PageSize = 1000
    )
    $flow = $Engine.GetFlow('sites')
    if ($flow.State -eq 'Complete') {
        Write-Host "SharePoint site URLs already complete ($($flow.RowsSeen) rows): skipped." -ForegroundColor DarkGray
        return [int64]$flow.RowsSeen
    }
    if ($flow.State -ne 'Pending') { [void]$Engine.ResetFlow('sites') }
    $st = @{ Seq = 0; Total = 0; Rows = 0 }
    $ids = New-Object System.Collections.Generic.List[string]
    $urls = New-Object System.Collections.Generic.List[string]
    function Send-SitePage {
        if ($ids.Count -eq 0) { return }
        $r = $Engine.AddSitePage([int64]$st.Seq, $ids.ToArray(), $urls.ToArray(), '')
        if ($r.IsFailed) { throw "SharePoint site page $($st.Seq) was rejected by the engine: $($r.Message)" }
        if ($r.Status -eq 'Applied') { $st.Total += $ids.Count }
        $st.Seq++
        $ids.Clear(); $urls.Clear()
    }
    try {
        Import-Csv -LiteralPath $Path -Encoding UTF8 | ForEach-Object {
            $row = $_
            if (-not $row.PSObject.Properties['GroupId'] -or -not $row.PSObject.Properties['Url']) { throw "The site URL file must have GroupId and Url columns: $Path" }
            $st.Rows++
            $gid = ([string]$row.GroupId).Trim()
            if (-not $gid -or $gid -eq '00000000-0000-0000-0000-000000000000') { return }
            $g = [guid]::Empty
            if (-not [guid]::TryParse($gid, [ref]$g)) { throw "Site URL row $($st.Rows): GroupId '$gid' is not a GUID." }
            $u = ([string]$row.Url).Trim()
            if (-not ($u -match '^https://\S+$')) { throw "Site URL row $($st.Rows): Url must be an absolute https URL (group $gid)." }
            $ids.Add($g.ToString('D')); $urls.Add($u)
            if ($ids.Count -ge $PageSize) { Send-SitePage }
        }
        Send-SitePage
        if ($st.Total -eq 0) { throw "The SharePoint site URL source contains no valid GROUP#0 rows; refusing to mark the source complete." }
        $c = $Engine.CompleteFlow('sites', [int64]$st.Total)
        if ($c.IsFailed) { throw "SharePoint site URLs could not be completed: $($c.Message)" }
    } catch {
        $m = "SharePoint site URL collection failed: $($_.Exception.Message)"
        try { [void]$Engine.MarkFlowFailed('sites', $m) } catch { }
        throw $m
    }
    Write-Host "SharePoint site URLs complete: $($st.Total) rows." -ForegroundColor Green
    return [int64]$st.Total
}

# ================================================================== #
#  Interactive SharePoint Admin window (NOT qualified outside a lab): prerequisites are verified up front and
#  the run fails clearly when they are missing. -SiteUrlsCsv is the supported alternative.
# ================================================================== #
function Test-SpoModuleAvailable {
    param([Parameter(Mandatory)][string] $PowerShellPath)
    & $PowerShellPath -NoProfile -NonInteractive -Command 'if (Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell) { exit 0 } else { exit 3 }' | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Test-SpoPrerequisites {
    param([string] $SpoAdminUrl)
    if (-not $SpoAdminUrl) { throw 'Provide -SpoAdminUrl (interactive SharePoint Admin collection) or -SiteUrlsCsv (pre-collected GroupId/Url file).' }
    if ($SpoAdminUrl -notmatch '^https://[a-z0-9-]+-admin\.sharepoint\.[a-z.]+/?$') { throw "-SpoAdminUrl must look like https://<tenant>-admin.sharepoint.com (got: $SpoAdminUrl)." }
    if (-not $IsWindows) { throw 'The interactive SharePoint Admin collection needs Windows PowerShell 5.1 (powershell.exe) and only exists on Windows. Use -SiteUrlsCsv.' }
    $ps = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if (-not $ps) { throw 'powershell.exe (Windows PowerShell 5.1) was not found: the interactive SharePoint Admin collection cannot start. Use -SiteUrlsCsv.' }
    if (-not (Test-SpoModuleAvailable -PowerShellPath $ps.Source)) { throw 'The Microsoft.Online.SharePoint.PowerShell module is not installed for Windows PowerShell 5.1 (Install-Module Microsoft.Online.SharePoint.PowerShell). Install it or use -SiteUrlsCsv.' }
    Write-Host 'WARNING: the interactive SharePoint Admin path has not been qualified outside a lab; -SiteUrlsCsv is the supported route.' -ForegroundColor Yellow
    return [string]$ps.Source
}

function Start-SpoCollection {
    param(
        [Parameter(Mandatory)][string] $PowerShellPath, [Parameter(Mandatory)][string] $AdminUrl,
        [Parameter(Mandatory)][string] $WorkerPath, [Parameter(Mandatory)][string] $WorkerCode,
        [Parameter(Mandatory)][string] $SiteCsv, [Parameter(Mandatory)][string] $Marker, [Parameter(Mandatory)][string] $LogPath
    )
    $WorkerCode | Out-File -FilePath $WorkerPath -Encoding utf8BOM
    Write-Host "=== Opening a new window for SharePoint collection (interactive SPO admin sign-in) ===" -ForegroundColor Cyan
    # Start-Process does not quote array elements: paths with spaces must be quoted here.
    $q = { param($s) if ($s -match '\s') { '"' + $s + '"' } else { $s } }
    Start-Process $PowerShellPath -ArgumentList @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', (& $q $WorkerPath), '-AdminUrl', (& $q $AdminUrl), '-OutCsv', (& $q $SiteCsv), '-Marker', (& $q $Marker), '-LogPath', (& $q $LogPath))
}

# GUARD: returns the done-marker text once the SharePoint collection finished OK; throws on timeout or failure.
function Wait-SpoCollection {
    param([Parameter(Mandatory)][string] $Marker, [string] $LogPath, [int] $TimeoutMin = 30, [string] $RunDir)
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while (-not (Test-Path -LiteralPath $Marker) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
    if (-not (Test-Path -LiteralPath $Marker)) { throw "Timeout ($TimeoutMin min): SharePoint collection not finished. The run is not sealed (database and intermediates kept in $RunDir); re-run with -ResumeRun." }
    $status = (Get-Content -LiteralPath $Marker -Raw).Trim()
    if ($status -notlike 'OK*') { throw "SharePoint collection failed ($status). The run is not sealed (see $LogPath ; kept in $RunDir)." }
    return $status
}

# ================================================================== #
#  Exports of the sealed run (CSV / HTML only), streamed by the engine and moved into place atomically.
# ================================================================== #
function Export-InventoryReports {
    param(
        [Parameter(Mandatory)] $Engine,
        [Parameter(Mandatory)][string] $RunDir,
        [Parameter(Mandatory)][string] $OutName,
        [Parameter(Mandatory)][ValidateSet('CSV', 'HTML')][string[]] $Format,
        [switch] $AlsoCsv,
        [switch] $Overwrite,
        [bool] $NeutralizeFormulas = $true,
        [int] $HtmlRowsPerPart = 10000,
        [int] $HtmlMaxRelations = 25,
        [switch] $HtmlPartitioned,
        [hashtable] $ReportSettings,
        [hashtable] $TenantSettings
    )
    $results = New-Object System.Collections.Generic.List[object]
    $snapshotInfo = $Engine.Info()
    if ($TenantSettings -and $TenantSettings.TenantId -and $snapshotInfo.TenantId -and $TenantSettings.TenantId -ne $snapshotInfo.TenantId) { throw 'The snapshot belongs to another authenticated tenant; report generation is refused.' }
    if (-not $Overwrite) {
        foreach ($fmt in @('CSV','HTML')) {
            if ($fmt -notin $Format -and -not ($fmt -eq 'CSV' -and $AlsoCsv)) { continue }
            if ((Test-Path -LiteralPath (Join-Path $RunDir "$OutName.$($fmt.ToLowerInvariant())")) -or
                ($fmt -eq 'HTML' -and (Test-Path -LiteralPath (Join-Path $RunDir "${OutName}_parts")))) { throw 'A requested export already exists; no new export was written. Use -OverwriteExport.' }
        }
    }
    foreach ($fmt in @('CSV', 'HTML')) {
        if ($fmt -notin $Format -and -not ($fmt -eq 'CSV' -and $AlsoCsv)) { continue }
        $o = New-Object GroupInventory.Engine.ExportOptions
        $o.Overwrite = [bool]$Overwrite
        $o.NeutralizeFormulas = $NeutralizeFormulas
        $o.HtmlRowsPerPart = $HtmlRowsPerPart
        $o.HtmlSingleFile = -not [bool]$HtmlPartitioned
        $o.HtmlMaxRelationsPerCell = $HtmlMaxRelations
        if ($ReportSettings) {
            foreach ($key in 'CsvDelimiter','Title','CompanyName','TimeZone','ShowTenantInformation','EnvironmentName') { $o.$key = $ReportSettings[$key] }
            if ($TenantSettings -and $o.ShowTenantInformation) { $o.TenantId = $TenantSettings.TenantId; $o.Organization = $TenantSettings.Organization }
            if ($o.ShowTenantInformation) {
                if ($snapshotInfo.TenantId) { $o.TenantId=$snapshotInfo.TenantId; $o.TenantIdentitySource='Authenticated collection tenant' }
                $o.LegacyTenantHistoryUnverified = $snapshotInfo.LegacyTenantHistoryUnverified
            }
        }
        if ($fmt -eq 'CSV') { $o.Path = Join-Path $RunDir "$OutName.csv"; $results.Add($Engine.ExportCsv($o)) }
        else { $o.Path = Join-Path $RunDir "$OutName.html"; $results.Add($Engine.ExportHtml($o)) }
    }
    return $results.ToArray()
}

function Invoke-M365GroupsRetention {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][int] $StorageRetentionDays,
        [Parameter(Mandatory)][int] $LogRetentionDays,
        [Parameter(Mandatory)][bool] $KeepIncompleteRuns,
        [string] $ExcludeRunDir,
        [string] $LogRoot
    )
    if ($StorageRetentionDays -lt 0 -or $LogRetentionDays -lt 0) { throw 'RetentionDays must be zero or a positive integer.' }
    $exclude = if ($ExcludeRunDir) {
        $path = [IO.Path]::GetFullPath($ExcludeRunDir).TrimEnd('\')
        if (Test-Path -LiteralPath $path -PathType Leaf) { Split-Path -Parent $path } else { $path }
    } else { '' }
    $now = Get-Date
    $completed = [Collections.Generic.List[object]]::new()
    $protected = [Collections.Generic.List[string]]::new()
    foreach ($run in @(Get-ChildItem -LiteralPath $Root -Directory -Filter 'run_*' -ErrorAction SilentlyContinue)) {
        $full = $run.FullName.TrimEnd('\')
        if (($run.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($exclude -and $full.Equals($exclude, [StringComparison]::OrdinalIgnoreCase))) { $protected.Add($run.Name); continue }
        $dbs = @(Get-ChildItem -LiteralPath $full -File -Filter '*.sqlite')
        if ($dbs.Count -ne 1 -or @(Get-ChildItem -LiteralPath $full -File -Filter '*.lock').Count) { $protected.Add($run.Name); continue }
        try {
            $info = [GroupInventory.Engine.InventoryEngine]::InspectSealedSnapshot($dbs[0].FullName)
            $sealedAt = [DateTimeOffset]::Parse($info.SealedUtc, [Globalization.CultureInfo]::InvariantCulture)
            $completed.Add([pscustomobject]@{ Run=$run; Database=$dbs[0].FullName; SealedAt=$sealedAt })
        } catch {
            $protected.Add($run.Name)
        }
    }
    # Preserve the most recent sealed snapshot even after a long idle period.
    $latest = $completed | Sort-Object SealedAt -Descending | Select-Object -First 1
    foreach ($item in $completed) {
        if ($item -eq $latest) { continue }
        $run = $item.Run
        if ($StorageRetentionDays -le 0 -or ($now.ToUniversalTime() - $item.SealedAt.UtcDateTime).TotalDays -lt $StorageRetentionDays) { continue }
        $guard = $null
        try {
            # Same exclusive lock path as the writer. FileShare.Delete allows guarded removal on Windows.
            $guard = [IO.FileStream]::new($item.Database + '.lock', [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Delete, 1, [IO.FileOptions]::DeleteOnClose)
            Remove-Item -LiteralPath $run.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            $protected.Add($run.Name)
            Write-Warning "Retention preserved a snapshot that could not be exclusively removed: $($run.Name)."
        } finally { if ($guard) { $guard.Dispose() } }
    }
    if ($latest) {
        # Logs have their own age policy, independent of database retention.
        $protected.Remove($latest.Run.Name) | Out-Null
    }
    foreach ($item in $completed) {
        if (Test-Path -LiteralPath $item.Run.FullName) {
            Invoke-M365GroupsLogRetention -Root $item.Run.FullName -RetentionDays $LogRetentionDays
        }
    }
    if ($LogRoot) { Invoke-M365GroupsLogRetention -Root $LogRoot -RetentionDays $LogRetentionDays -ProtectedRunNames $protected.ToArray() }
}

function Invoke-M365GroupsLogRetention {
    param([Parameter(Mandatory)][string] $Root, [int] $RetentionDays, [string[]] $ProtectedRunNames = @())
    if ($RetentionDays -lt 0) { throw 'Log retention must be a nonnegative integer.' }
    if ($RetentionDays -eq 0 -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Filter '*.log')) {
        if ($file.LastWriteTime -lt $cutoff -and -not ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            try {
                $handle = [IO.FileStream]::new($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Delete, 1, [IO.FileOptions]::DeleteOnClose)
                $handle.Dispose()
            } catch { Write-Warning "Retention preserved an active log: $($file.Name)." }
        }
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath $Root -Directory -Filter 'run_*')) {
        if ($dir.Name -notin $ProtectedRunNames -and -not ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Invoke-M365GroupsLogRetention -Root $dir.FullName -RetentionDays $RetentionDays
        }
    }
}

# ================================================================== #
#  Main
# ================================================================== #
if (-not $WorkDir) { throw "WorkDir could not be resolved (script folder unknown). Pass -WorkDir." }
$resuming = [bool]$ResumeRun
if (-not $resuming -and -not $SpoAdminUrl -and -not $SiteUrlsCsv) { throw "Provide -SpoAdminUrl (to collect SharePoint URLs) or -SiteUrlsCsv (pre-collected GroupId/Url file), or -ResumeRun <run folder>." }
if ($SiteUrlsCsv -and -not (Test-Path -LiteralPath $SiteUrlsCsv)) { throw "-SiteUrlsCsv not found: $SiteUrlsCsv" }

Import-GroupInventoryEngine

# Run folder: new run_<timestamp>, or the folder given to -ResumeRun
$runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
if ($resuming) {
    if (-not (Test-Path -LiteralPath $ResumeRun)) { throw "-ResumeRun not found: $ResumeRun" }
    $resolved = (Resolve-Path -LiteralPath $ResumeRun).Path
    if (Test-Path -LiteralPath $resolved -PathType Leaf) { $dbPath = $resolved; $runDir = Split-Path -Parent $resolved }
    else {
        $runDir = $resolved
        $dbPath = Join-Path $runDir ([IO.Path]::GetFileName($DatabasePath))
        if (-not (Test-Path -LiteralPath $dbPath)) { $dbPath = Join-Path $runDir 'inventory.sqlite' }
    }
    if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) { throw "No inventory.sqlite found to resume in $runDir." }
    $logName = "resume_$runStamp.log"
} else {
    $runDir = Join-Path $WorkDir "run_$runStamp"
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $dbPath = Join-Path $runDir $(if ($PSBoundParameters.ContainsKey('WorkDir') -and -not $PSBoundParameters.ContainsKey('DatabasePath')) { 'inventory.sqlite' } else { [IO.Path]::GetFileName($DatabasePath) })
    $logName = 'run.log'
}
$reportDir = Join-Path $OutputPath (Split-Path -Leaf $runDir)
$logDir = Join-Path $LogPath (Split-Path -Leaf $runDir)
if ($PSBoundParameters.ContainsKey('WorkDir')) {
    if (-not $PSBoundParameters.ContainsKey('OutputPath')) { $reportDir = $runDir }
    if (-not $PSBoundParameters.ContainsKey('LogPath')) { $logDir = $runDir }
}
New-Item -ItemType Directory -Path $reportDir, $logDir -Force | Out-Null
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'lib\engine\GroupInventory.Engine.dll')) {
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot '.M365GroupsReporting.executed'), 'Executed runtime package; never replace automatically.')
}
$executionLog = Join-Path $logDir $logName
$exportErrCsv = Join-Path $runDir "_inv_graph_errors.csv"   # failures (only written when the run is incomplete)
$siteCsv   = Join-Path $runDir "_inv_sites.csv"   # SharePoint intermediate
$spMarker  = Join-Path $runDir "_inv_sp.status"   # SharePoint done-marker
$spLog     = Join-Path $logDir "sp.log"           # SharePoint window transcript
$spWorker  = Join-Path $runDir "_inv_sp_worker.ps1"

$transcriptStarted = $false
Add-Content -LiteralPath $executionLog -Value ("{0:o} | execution started" -f [DateTimeOffset]::UtcNow) -Encoding UTF8
if ($PSBoundParameters.ContainsKey('ClientSecret')) {
    Add-Content -LiteralPath $executionLog -Value "Transcript disabled because -ClientSecret was supplied as a parameter; secret-safe diagnostics only." -Encoding UTF8
} else {
    Start-Transcript -Path $executionLog -Append -Force | Out-Null
    $transcriptStarted = $true
}
$engine = $null
$executionSucceeded = $false
try {
    Write-Host "Run folder: $runDir" -ForegroundColor Cyan
    $adopt = $resuming -and -not $PSBoundParameters.ContainsKey('SkipMembers')
    $engine = Open-InventoryRun -DatabasePath $dbPath -RunId $(if ($resuming) { '' } else { "run_$runStamp" }) -SkipMembers ([bool]$SkipMembers) -AdoptRunSettings $adopt -Resume $resuming
    $info = $engine.Info()
    $skipMembersRun = [bool]$info.SkipMembers
    Write-Host ("Run {0} | state {1} | groups {2} | lists: complete {3}, pending {4}, interrupted {5}, failed {6}{7}" -f $(if ($resuming) { 'resumed' } else { 'created' }), $info.State, $info.Groups, $info.ListsComplete, $info.ListsPending, $info.ListsCollecting, $info.ListsFailed, $(if ($skipMembersRun) { ' | members not collected' } else { '' })) -ForegroundColor Cyan
    if ($Max -gt 0 -and -not $resuming) { Write-Host "SAMPLE RUN: only the first $Max groups are collected (-Max)." -ForegroundColor Yellow }

    if ($info.State -ne 'sealed') {
        # ---------------------------------------------------------- credentials
        if ($AuthMode -eq 'ClientSecretFile' -and -not ($TenantId -and $ClientId -and $ClientSecret)) {
            if (-not $CredFile -or -not (Test-Path -LiteralPath $CredFile)) { throw "Missing external credentials file. Configure Authentication.CredentialsPath or use -CredFile." }
            try { $cj = Get-Content -LiteralPath $CredFile -Raw | ConvertFrom-Json }
            catch { throw 'The external credentials file could not be read as JSON; its contents are never included in diagnostics.' }
            if ($TenantId -and $cj.TenantId -and $TenantId -ne $cj.TenantId) { throw 'External credentials tenant does not match the configured tenant.' }
            if ($ClientId -and $cj.ClientId -and $ClientId -ne $cj.ClientId) { throw 'External credentials application does not match the configured application.' }
            if (-not $TenantId)     { $TenantId = $cj.TenantId }
            if (-not $ClientId)     { $ClientId = $cj.ClientId }
            if (-not $ClientSecret) { $ClientSecret = $cj.ClientSecret }
        }
        if ($AuthMode -eq 'ClientSecretEnvironment' -and -not $ClientSecret) { $ClientSecret = [Environment]::GetEnvironmentVariable($configuration.Authentication.SecretEnvironmentVariable) }
        $parsedId = [guid]::Empty
        if (-not [guid]::TryParse($TenantId, [ref]$parsedId) -or -not [guid]::TryParse($ClientId, [ref]$parsedId)) { throw 'Authentication requires valid TenantId and AppId/ClientId GUIDs.' }
        if ($AuthMode -eq 'Certificate') {
            if ($CertificateThumbprint -notmatch '^[a-fA-F0-9]{40}$' -or $PSBoundParameters.ContainsKey('ClientSecret')) { throw 'Certificate mode requires a 40-character thumbprint and forbids -ClientSecret.' }
        } elseif (-not $ClientSecret) { throw 'The selected authentication mode requires an external client secret.' }
        if ($info.TenantId -and $info.TenantId -ne $TenantId) { throw 'The snapshot belongs to another authenticated tenant; collection is refused.' }

        # ---------------------------------------------------------- 1) SharePoint site URLs
        $needSites = [bool]$info.SitesRequired -and $info.Sites.State -ne 'Complete'
        $spWindow = $false
        if ($needSites) {
            if ($SiteUrlsCsv) {
                Write-Host "Using provided site URLs (SharePoint window skipped): $SiteUrlsCsv" -ForegroundColor Cyan
                Copy-Item -LiteralPath $SiteUrlsCsv -Destination $siteCsv -Force
                [void](Import-SiteUrlsToEngine -Engine $engine -Path $siteCsv)
            } else {
                $psPath = Test-SpoPrerequisites -SpoAdminUrl $SpoAdminUrl
                $reuse = (Test-Path -LiteralPath $spMarker) -and (Test-Path -LiteralPath $siteCsv) -and ((Get-Content -LiteralPath $spMarker -Raw).Trim() -like 'OK*')
                if ($reuse) { Write-Host 'A finished SharePoint collection from the previous session is reused.' -ForegroundColor Cyan }
                else {
                    Remove-Item -LiteralPath $spMarker, $siteCsv -Force -ErrorAction SilentlyContinue
                    Start-SpoCollection -PowerShellPath $psPath -AdminUrl $SpoAdminUrl -WorkerPath $spWorker -WorkerCode $SpoWorkerCode -SiteCsv $siteCsv -Marker $spMarker -LogPath $spLog
                }
                $spWindow = $true
            }
        }

        # ---------------------------------------------------------- 2) Graph: enumeration + owners/members
        Write-Host "=== Graph export (app-only, parallel, no /sites/root) ===" -ForegroundColor Cyan
        $auth = New-GraphAuth -Creds @{ TenantId = $TenantId; ClientId = $ClientId; ClientSecret = $ClientSecret; Mode=$AuthMode; CertificateThumbprint=$CertificateThumbprint }
        $binding = $engine.BindAuthenticatedTenant($TenantId)
        if ($binding.IsFailed) { throw $binding.Message }
        if ($engine.Info().LegacyTenantHistoryUnverified) { Write-Warning $binding.Message }
        Write-Host "Token OK (tenant $TenantId)." -ForegroundColor Green
        $maxGroups = $(if ($resuming) { 0 } else { $Max })
        [void](Invoke-GroupEnumeration -Engine $engine -Auth $auth -Max $maxGroups)
        $collect = @{ Engine = $engine; Auth = $auth; ThrottleLimit = $ThrottleLimit }
        if ($skipMembersRun) { $collect.SkipMembers = $true }
        [void](Invoke-ListCollection @collect)

        # ---------------------------------------------------------- 3) GUARD + site import (window mode)
        if ($spWindow) {
            Write-Host "=== Waiting for SharePoint collection to finish (guard before sealing) ===" -ForegroundColor Cyan
            $spStatus = Wait-SpoCollection -Marker $spMarker -LogPath $spLog -TimeoutMin $SpTimeoutMin -RunDir $runDir
            Write-Host "SharePoint done ($spStatus)." -ForegroundColor Green
            [void](Import-SiteUrlsToEngine -Engine $engine -Path $siteCsv)
        }

        # ---------------------------------------------------------- 4) reconcile + seal (fail-closed)
        $seal = Complete-InventoryRun -Engine $engine -ErrorsCsv $exportErrCsv
        Write-Host $seal.Message -ForegroundColor Green
    } else {
        if (Test-Path -LiteralPath $exportErrCsv) { Remove-Item -LiteralPath $exportErrCsv -Force -ErrorAction Stop }
        Write-Host "The run is already sealed: only the export is produced." -ForegroundColor Cyan
    }

    # -------------------------------------------------------------- 5) exports
    $reportTenant = @{ TenantId=$TenantId; Organization=$configuration.Tenant.Organization }
    $exports = @(Export-InventoryReports -Engine $engine -RunDir $reportDir -OutName $OutName -Format $Format -AlsoCsv:([bool]$GridView) -Overwrite:([bool]$OverwriteExport) -NeutralizeFormulas (-not $RawCsvValues) -HtmlRowsPerPart $HtmlRowsPerPart -HtmlMaxRelations $HtmlMaxRelations -HtmlPartitioned:$HtmlPartitioned -ReportSettings $configuration.Report -TenantSettings $reportTenant)
    $rec = $engine.Reconcile()
    Write-Host "`n=== DONE ===" -ForegroundColor Green
    foreach ($x in $exports) {
        Write-Host "Final file ($($x.Format)): $($x.Path)"
        Write-Host "  $($x.RowsWritten) groups | $($x.Bytes) bytes | $($x.Parts) part(s) | sha256 $($x.Sha256)$(if ($x.FormulaNeutralized -gt 0) { " | formulas neutralised: $($x.FormulaNeutralized)" })$(if ($x.RelationsTruncated -gt 0) { " | cells with truncated relations: $($x.RelationsTruncated)" })"
    }
    Write-Host "  ownerless=$($rec.Ownerless) | owner entries=$($rec.OwnerEntries) | member entries=$($rec.MemberEntries) | duplicates removed=$($rec.Duplicates)"
    Write-Host "Run folder (database + logs + final): $runDir"

    if ($GridView) {
        $csvExport = @($exports | Where-Object { $_.Format -eq 'CSV' })[0]
        if ($csvExport.RowsTotal -gt $GridViewMax) { Write-Host "GridView limited to $GridViewMax rows." -ForegroundColor Yellow }
        try { Import-Csv -LiteralPath $csvExport.Path -Delimiter $configuration.Report.CsvDelimiter -Encoding UTF8 | Select-Object -First $GridViewMax | Out-GridView -Title "M365 groups inventory ($($csvExport.RowsTotal))" }
        catch { Write-Host "Out-GridView unavailable: $($_.Exception.Message)" -ForegroundColor DarkYellow }
    }
    $executionSucceeded = $true
}
catch {
    Write-Host "`nRUN FAILED - no final inventory was produced: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "The run database and logs are preserved in: $runDir (continue with -ResumeRun '$runDir')" -ForegroundColor Yellow
    throw
}
finally {
    if ($engine) { try { $engine.Dispose() } catch { Write-Host "Engine close: $($_.Exception.Message)" -ForegroundColor DarkYellow } }
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch {} }
    Add-Content -LiteralPath $executionLog -Value ("{0:o} | execution {1}" -f [DateTimeOffset]::UtcNow, $(if ($executionSucceeded) { 'completed' } else { 'incomplete; snapshot preserved' })) -Encoding UTF8
    $ClientSecret = $null; $cj = $null; $auth = $null
}
if ($executionSucceeded -and -not $NoRetention) {
    Invoke-M365GroupsRetention -Root $WorkDir -StorageRetentionDays ([int]$configuration.Storage.RetentionDays) `
        -LogRetentionDays ([int]$configuration.Logging.RetentionDays) -LogRoot $LogPath `
        -KeepIncompleteRuns ([bool]$configuration.Storage.KeepIncompleteRuns) -ExcludeRunDir $runDir
}
