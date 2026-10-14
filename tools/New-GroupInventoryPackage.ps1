#Requires -Version 7.4
<#
.SYNOPSIS
    Builds a clean M365GroupsReporting runtime package, with a sanitized configuration and HTML guide.
.DESCRIPTION
    Uses a strict runtime allow-list. No data, reports, logs, bin, credentials, databases, tests or build
    intermediates are copied. Compiled dependencies live in lib\engine, not bin. Tenant/branding values
    and operational paths are reset, then every text file is scanned. Publication is atomic.
    An executed package or a destination containing data is never replaced, even with -Force.
.PARAMETER Destination
    External destination; default: ..\package\M365GroupsReporting-<version>.
.PARAMETER Force
    Replace only an unexecuted, recognized package after all source/scan checks pass.
.PARAMETER SourceRoot
    Reviewed source root. Defaults to the project root; also used by isolated package tests.
.EXAMPLE
    .\Build-Engine.ps1
    .\tools\Build-Documentation.ps1
    .\tools\New-GroupInventoryPackage.ps1 -Destination C:\Scripts\package\M365GroupsReporting-1.0.0
#>
[CmdletBinding()]
param([string] $Destination, [switch] $Force, [string] $SourceRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
$xml = [xml](Get-Content -LiteralPath (Join-Path $root 'engine\GroupInventory.Engine.csproj') -Raw)
$version = ([string]$xml.Project.PropertyGroup.Version).Trim()
if (-not $version) { throw 'Engine version is missing.' }
if (-not $Destination) { $Destination = Join-Path (Split-Path -Parent $root) "package\M365GroupsReporting-$version" }
$Destination = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
$comparison = [StringComparison]::OrdinalIgnoreCase
if (($Destination + '\').StartsWith($root + '\', $comparison) -or ($root + '\').StartsWith($Destination + '\', $comparison)) { throw 'The destination must be outside the tool folder and cannot be its ancestor.' }

function Assert-NoReparsePath([string] $Path) {
    $p = $Path
    while ($p) {
        if ((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Package paths must not traverse a junction or symbolic link.' }
        $parent = Split-Path -Parent $p
        if ($parent -eq $p) { break }; $p = $parent
    }
}
Assert-NoReparsePath $root
Assert-NoReparsePath $Destination
function Assert-DestinationSafe {
if (Test-Path -LiteralPath $Destination) {
    if (-not $Force) { throw 'The destination already exists; use -Force only for an unexecuted package.' }
    if (-not (Test-Path -LiteralPath (Join-Path $Destination 'Invoke-M365GroupsReporting.ps1') -PathType Leaf)) { throw 'The destination is not a recognized M365GroupsReporting package.' }
    $unsafe = @(Get-ChildItem -LiteralPath $Destination -Recurse -Force | Where-Object {
        ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        ($_.PSIsContainer -and $_.Name -match '^(data|reports|logs|bin|run_.+|lab_.+)$') -or
        (-not $_.PSIsContainer -and $_.Name -match '(?i)(\.M365GroupsReporting\.executed|app_creds|credential|\.sqlite(?:$|-(?:journal|wal|shm)$|\.lock$)|\.db$|\.log$|\.lock$|\.csv$|\.zip$)')
    })
    if ($unsafe.Count) { throw 'The destination is an executed package or contains data; it is never replaced.' }
}
}
Assert-DestinationSafe

$files = @('Invoke-M365GroupsReporting.ps1','Get-SiteUrls.ps1','README.md','THIRD-PARTY-NOTICES.md',
    'docs\GroupInventory-Guide.md','docs\GroupInventory-Guide.html','templates\GroupInventory.template.html')
$binaries = @('GroupInventory.Engine.dll','Microsoft.Data.Sqlite.dll','SQLitePCLRaw.core.dll',
    'SQLitePCLRaw.batteries_v2.dll','SQLitePCLRaw.provider.e_sqlite3.dll','GroupInventory.template.html',
    'runtimes\win-x64\e_sqlite3.dll','runtimes\win-arm64\e_sqlite3.dll')
foreach ($relative in $files + @($binaries | ForEach-Object { "engine\bin\$_" }) + 'config\M365GroupsReporting.config.psd1') {
    $source = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required package source missing: $relative" }
    Assert-NoReparsePath $source
}
if ((Get-FileHash -LiteralPath (Join-Path $root 'templates\GroupInventory.template.html')).Hash -ne
    (Get-FileHash -LiteralPath (Join-Path $root 'engine\bin\GroupInventory.template.html')).Hash) { throw 'The built HTML template is stale. Run Build-Engine.ps1 before packaging.' }

$configFile = Join-Path $root 'config\M365GroupsReporting.config.psd1'
$configuration = Import-PowerShellDataFile -LiteralPath $configFile
function Assert-NoConfigurationSecret([hashtable] $Section) {
    foreach ($key in $Section.Keys) {
        if ($key -match '^(ClientSecret|Password|AccessToken|PrivateKey)$') { throw 'Secrets are forbidden in operational configuration.' }
        if ($Section[$key] -is [hashtable]) { Assert-NoConfigurationSecret $Section[$key] }
    }
}
Assert-NoConfigurationSecret $configuration
$tenantValues = [Collections.Generic.List[string]]::new()
foreach ($section in 'Tenant','Authentication','Report') {
    foreach ($key in @($configuration[$section].Keys)) {
        if ($key -in 'TenantId','Organization','SharePointAdminUrl','AppId','CertificateThumbprint','CompanyName','EnvironmentName') {
            $value = [string]$configuration[$section][$key]
            if ($value) { $tenantValues.Add($value) }
            $configuration[$section][$key] = ''
        }
    }
}
$configuration.Authentication.CredentialsPath = '.\app_creds.json'
$configuration.Authentication.SecretEnvironmentVariable = 'M365_GROUPS_CLIENT_SECRET'
$configuration.Storage.DatabasePath = '.\data\M365GroupsReporting.sqlite'
$configuration.Storage.Remove('WorkDirectory')
$configuration.Logging.Path = '.\logs'
$configuration.Report.OutputPath = '.\reports'
$configuration.Report.FilePrefix = 'M365GroupsReporting'
$configuration.Report.Title = 'M365 groups inventory'
$configuration.Report.CompanyName = ''
$configuration.Report.EnvironmentName = ''
$configuration.Report.ShowTenantInformation = $false

function ConvertTo-DataLiteral($Value) {
    if ($Value -is [hashtable]) {
        $items = foreach ($key in @($Value.Keys | Sort-Object)) { "    '$($key.Replace("'","''"))' = $(ConvertTo-DataLiteral $Value[$key])" }
        return "@{`n$($items -join "`n")`n}"
    }
    if ($Value -is [bool]) { return '$' + $Value.ToString().ToLowerInvariant() }
    if ($Value -is [string]) { return "'" + $Value.Replace("'", "''") + "'" }
    if ($Value -is [Array]) { return '@(' + ((@($Value | ForEach-Object { ConvertTo-DataLiteral $_ })) -join ', ') + ')' }
    if ($Value -is [int] -or $Value -is [long]) { return [string]$Value }
    throw 'Unsupported operational configuration value.'
}

$parent = Split-Path -Parent $Destination
[void][IO.Directory]::CreateDirectory($parent)
$stage = Join-Path $parent ('.M365GroupsReporting-stage-' + [guid]::NewGuid().ToString('N'))
$backup = Join-Path $parent ('.M365GroupsReporting-previous-' + [guid]::NewGuid().ToString('N'))
$movedOld = $false
try {
    [void][IO.Directory]::CreateDirectory($stage)
    foreach ($relative in $files) {
        $target = Join-Path $stage $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $target
    }
    foreach ($relative in $binaries) {
        $target = Join-Path $stage "lib\engine\$relative"
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        Copy-Item -LiteralPath (Join-Path $root "engine\bin\$relative") -Destination $target
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $stage 'config'))
    [IO.File]::WriteAllText((Join-Path $stage 'config\M365GroupsReporting.config.psd1'), (ConvertTo-DataLiteral $configuration), [Text.UTF8Encoding]::new($true))
    foreach ($item in Get-ChildItem -LiteralPath $stage -Recurse -Force) {
        if (($item.PSIsContainer -and $item.Name -match '^(data|reports|logs|bin|run_.+|lab_.+)$') -or
            (-not $item.PSIsContainer -and $item.Name -match '(?i)(app_creds|\.sqlite(?:$|-(?:journal|wal|shm)$|\.lock$)|\.db$|\.log$|\.lock$|\.csv$|\.zip$)')) { throw 'Forbidden runtime data or build output in package.' }
        if (-not $item.PSIsContainer -and $item.Extension -in '.ps1','.psm1','.psd1','.cs','.html','.md','.json','.xml') {
            $text = [IO.File]::ReadAllText($item.FullName)
            foreach ($value in $tenantValues) {
                if ($text.IndexOf($value, $comparison) -ge 0) { throw "A tenant or branding value remains in $($item.Name)." }
            }
            if ($text -match '(?im)(?:client[_-]?secret|password|access[_-]?token)[''"]?\s*[:=]\s*[''"][^''"$<\r\n]{8,}[''"]' -or
                $text -match '-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}') { throw "Secret-shaped content in $($item.Name)." }
        }
    }
    [void](Import-PowerShellDataFile -LiteralPath (Join-Path $stage 'config\M365GroupsReporting.config.psd1'))
    Assert-NoReparsePath $Destination
    Assert-DestinationSafe
    if (Test-Path -LiteralPath $Destination) { [IO.Directory]::Move($Destination, $backup); $movedOld = $true }
    try { [IO.Directory]::Move($stage, $Destination) }
    catch { if ($movedOld) { [IO.Directory]::Move($backup, $Destination); $movedOld = $false }; throw }
    if ($movedOld) { Remove-Item -LiteralPath $backup -Recurse -Force }
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
Write-Host "M365GroupsReporting $version package ready: $Destination" -ForegroundColor Green
Get-ChildItem -LiteralPath $Destination -Recurse -File | Sort-Object FullName | ForEach-Object {
    [pscustomobject]@{ File=$_.FullName.Substring($Destination.Length+1); Bytes=$_.Length; Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
}
