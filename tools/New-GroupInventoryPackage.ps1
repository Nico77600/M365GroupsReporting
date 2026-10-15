#Requires -Version 7.4
<#
.SYNOPSIS
    Builds a clean M365GroupsReporting runtime package, with a sanitized configuration and HTML guide.
.DESCRIPTION
    Uses a strict runtime allow-list. No data, reports, logs, bin, credentials, databases, tests or build
    intermediates are copied. Compiled dependencies live in lib\engine, not bin. Tenant/branding values
    and operational paths are reset, then every text file is scanned. Publication is atomic.
    An executed package or a destination containing data is never replaced, even with -Force.
    Prepare produces an unsigned, non-runnable artifact. RefreshManifest requires trusted timestamped
    scripts and rehashes finalized bytes. Finalize requires a trusted timestamped manifest and verifies
    the entire runtime before removing the pending marker. This tool never signs or publishes.
.PARAMETER Destination
    External destination; default: ..\package\M365GroupsReporting-<version>.
.PARAMETER Force
    Replace only an unexecuted, recognized package after all source/scan checks pass.
.PARAMETER SourceRoot
    Reviewed source root. Defaults to the project root; also used by isolated package tests.
.PARAMETER Stage
    Prepare, RefreshManifest or Finalize (default). Signing is a separate owner-approved operation.
.EXAMPLE
    .\Build-Engine.ps1
    .\tools\Build-Documentation.ps1
    .\tools\New-GroupInventoryPackage.ps1 -Stage Prepare -Destination C:\ReviewedArtifacts\M365GroupsReporting-1.0.0
#>
[CmdletBinding()]
param(
    [string] $Destination, [switch] $Force,
    [string] $SourceRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('Prepare', 'RefreshManifest', 'Finalize')][string]$Stage = 'Finalize'
)
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
function Assert-PackageScriptSignatures([string]$PackageRoot) {
    foreach ($relative in 'Invoke-M365GroupsReporting.ps1', 'Get-SiteUrls.ps1', 'Test-PackageIntegrity.ps1') {
        $path = Join-Path $PackageRoot $relative
        Assert-NoReparsePath $path
        $signature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
        if ([string]$signature.Status -cne 'Valid' -or $null -eq $signature.SignerCertificate -or
            $signature.SignerCertificate.Thumbprint -cne '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6' -or
            $null -eq $signature.TimeStamperCertificate) {
            throw "Package signing is pending: expected trusted, timestamped owner signature: $relative"
        }
    }
}
if ($Stage -cne 'Prepare') {
    if (-not (Test-Path -LiteralPath (Join-Path $Destination '.publication-pending') -PathType Leaf)) {
        throw 'RefreshManifest/Finalize requires an existing, unexecuted signing-preparation package.'
    }
    if (Test-Path -LiteralPath (Join-Path $Destination '.M365GroupsReporting.executed')) {
        throw 'An executed package is never modified.'
    }
    Assert-PackageScriptSignatures $Destination
    if ($Stage -ceq 'RefreshManifest') {
        & (Join-Path $root 'tools\New-IntegrityManifest.ps1') -Root $Destination -Layout Package
        Write-Warning 'Manifest refreshed from finalized signed script bytes. Sign and timestamp the manifest before Finalize.'
        return
    }
    & (Join-Path $Destination 'Test-PackageIntegrity.ps1') -Root $Destination
    Remove-Item -LiteralPath (Join-Path $Destination '.publication-pending') -Force
    Write-Output "Authenticated package finalized: $Destination"
    return
}
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

$files = @('Invoke-M365GroupsReporting.ps1','Get-SiteUrls.ps1','Test-PackageIntegrity.ps1',
    'LICENSE','THIRD-PARTY-NOTICES.md',
    'docs\GroupInventory-Guide.md','docs\GroupInventory-Guide.html','templates\GroupInventory.template.html',
    'docs\images\readme-banner-light.svg','docs\images\readme-banner-dark.svg',
    'docs\images\report-overview.png','docs\images\report-details.png')
$binaries = @('GroupInventory.Engine.dll','Microsoft.Data.Sqlite.dll','SQLitePCLRaw.core.dll',
    'SQLitePCLRaw.batteries_v2.dll','SQLitePCLRaw.provider.e_sqlite3.dll','GroupInventory.template.html',
    'runtimes\win-x64\e_sqlite3.dll','runtimes\win-arm64\e_sqlite3.dll')
foreach ($relative in $files + @($binaries | ForEach-Object { "engine\bin\$_" }) +
    @('config\M365GroupsReporting.config.psd1', 'docs\runtime-README.md', 'tools\New-IntegrityManifest.ps1')) {
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
$stagingPath = Join-Path $parent ('.M365GroupsReporting-stage-' + [guid]::NewGuid().ToString('N'))
$backup = Join-Path $parent ('.M365GroupsReporting-previous-' + [guid]::NewGuid().ToString('N'))
$movedOld = $false
try {
    [void][IO.Directory]::CreateDirectory($stagingPath)
    foreach ($relative in $files) {
        $target = Join-Path $stagingPath $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $target
    }
    Copy-Item -LiteralPath (Join-Path $root 'docs\runtime-README.md') -Destination (Join-Path $stagingPath 'README.md')
    foreach ($relative in $binaries) {
        $target = Join-Path $stagingPath "lib\engine\$relative"
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        Copy-Item -LiteralPath (Join-Path $root "engine\bin\$relative") -Destination $target
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $stagingPath 'config'))
    [IO.File]::WriteAllText((Join-Path $stagingPath 'config\M365GroupsReporting.config.psd1'), (ConvertTo-DataLiteral $configuration), [Text.UTF8Encoding]::new($true))
    foreach ($item in Get-ChildItem -LiteralPath $stagingPath -Recurse -Force) {
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
    [void](Import-PowerShellDataFile -LiteralPath (Join-Path $stagingPath 'config\M365GroupsReporting.config.psd1'))
    & (Join-Path $root 'tools\New-IntegrityManifest.ps1') -Root $stagingPath -Layout Package | Out-Null
    [IO.File]::WriteAllText((Join-Path $stagingPath '.publication-pending'),
        'UNSIGNED PREPARATION ONLY. Sign scripts, RefreshManifest, sign manifest, then Finalize.', [Text.UTF8Encoding]::new($false))
    Assert-NoReparsePath $Destination
    Assert-DestinationSafe
    if (Test-Path -LiteralPath $Destination) { [IO.Directory]::Move($Destination, $backup); $movedOld = $true }
    try { [IO.Directory]::Move($stagingPath, $Destination) }
    catch { if ($movedOld) { [IO.Directory]::Move($backup, $Destination); $movedOld = $false }; throw }
    if ($movedOld) { Remove-Item -LiteralPath $backup -Recurse -Force }
} finally {
    if (Test-Path -LiteralPath $stagingPath) { Remove-Item -LiteralPath $stagingPath -Recurse -Force }
}
Write-Warning "UNSIGNED PREPARATION ONLY: M365GroupsReporting $version at $Destination. This artifact cannot run or be published."
Get-ChildItem -LiteralPath $Destination -Recurse -File | Sort-Object FullName | ForEach-Object {
    [pscustomobject]@{ File=$_.FullName.Substring($Destination.Length+1); Bytes=$_.Length; Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
}

# SIG # Begin signature block
# MIIghQYJKoZIhvcNAQcCoIIgdjCCIHICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDQ19cz/PSo7QN9
# rw/u2ZETeCBqwyvTotva5Nm3NihaWqCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
# CDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAe
# Fw0xNjA2MjQyMDQ0MzBaFw0zMTA2MjQyMDQ0MzBaMHgxCzAJBgNVBAYTAlVTMQ4w
# DAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENv
# cnAxNDAyBgNVBAMMK1NTTC5jb20gQ29kZSBTaWduaW5nIEludGVybWVkaWF0ZSBD
# QSBSU0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCfgxNzqrDG
# bSHL24t6h3TQcdyOl3Ka5LuINLTdgAPGL0WkdJq/Hg9Q6p5tePOf+lEmqT2d0bKU
# Vz77OYkbkStW72fL5gvjDjmMxjX0jD3dJekBrBdCfVgWQNz51ShEHZVkMGE6ZPKX
# 13NMfXsjAm3zdetVPW+qLcSvvnSsXf5qtvzqXHnpD0OctVIFD+8+sbGP0EmtpuNC
# GVQ/8y8Ooct8/hP5IznaJRy4PgBKOm8yMDdkHseudQfYVdIYyQ6KvKNc8HwKp4WB
# wg6vj5lc02AlvINaaRwlE81y9eucgJvcLGfE3ckJmNVz68Qho+Uyjj4vUpjGYDdk
# jLJvSlRyGMwnh/rNdaJjIUy1PWT9K6abVa8mTGC0uVz+q0O9rdATZlAfC9KJpv/X
# gAbxwxECMzNhF/dWH44vO2jnFfF3VkopngPawismYTJboFblSSmNNqf1x1KiVgMg
# Lzh4gL32Bq5BNMuURb2bx4kYHwu6/6muakCZE93vUN8BuvIE1tAx3zQ4XldbyDge
# VtSsSKbt//m4wTvtwiS+RGCnd83VPZhZtEPqqmB9zcLlL/Hr9dQg1Zc0bl0EawUR
# 0tOSjAknRO1PNTFGfnQZBWLsiePqI3CY5NEv1IoTGEaTZeVYc9NMPSd6Ij/D+KNV
# t/nmh4LsRR7Fbjp8sU65q2j3m2PVkUG8qQIDAQABo4H7MIH4MA8GA1UdEwEB/wQF
# MAMBAf8wHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKSle44gCUNplkwMAYIKwYBBQUH
# AQEEJDAiMCAGCCsGAQUFBzABhhRodHRwOi8vb2NzcHMuc3NsLmNvbTARBgNVHSAE
# CjAIMAYGBFUdIAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwOwYDVR0fBDQwMjAwoC6g
# LIYqaHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0G
# A1UdDgQWBBRUwv4QlQCTzWr158DX2bJLuI8M4zAOBgNVHQ8BAf8EBAMCAYYwDQYJ
# KoZIhvcNAQELBQADggIBAPUPJodwr5miyvXWyfCNZj05gtOII9iCv49UhCe204MH
# 154niU2EjlTRIO5gQ9tXQjzHsJX2vszqoz2OTwbGK1mGf+tzG8rlQCbgPW/M9r1x
# xs19DiBAOdYF0q+UCL9/wlG3K7V7gyHwY9rlnOFpLnUdTsthHvWlM98CnRXZ7WmT
# V7pGRS6AvGW+5xI+3kf/kJwQrfZWsqTU+tb8LryXIbN2g9KR+gZQ0bGAKID+260P
# Z+34fdzZcFt6umi1s0pmF4/n8OdX3Wn+vF7h1YyfE7uVmhX7eSuF1W0+Z0duGwdc
# +1RFDxYRLhHDsLy1bhwzV5Qe/kI0Ro4xUE7bM1eV+jjk5hLbq1guRbfZIsr0WkdJ
# LCjoT4xCPGRo6eZDrBmRqccTgl/8cQo3t51Qezxd96JSgjXktefTCm9r/o35pNfV
# HUvnfWII+NnXrJlJ27WEQRQu9i5gl1NLmv7xiHp0up516eDap8nMLDt7TAp4z5T3
# NmC2gzyKVMtODWgqlBF1JhTqIDfM63kXdlV4cW3iSTgzN9vkbFnHI2LmvM4uVEv9
# XgMqyN0eS3FE0HU+MWJliymm7STheh2ENH+kF3y0rH0/NVjLw78a3Z9UVm1F5VPz
# iIorMaPKPlDRADTsJwjDZ8Zc6Gi/zy4WZbg8Zv87spWrmo2dzJTw7XhQf+xkR6Od
# MIIG9TCCBN2gAwIBAgIQBof4ljXihJpmCqqt2mhAWzANBgkqhkiG9w0BAQsFADB4
# MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24x
# ETAPBgNVBAoMCFNTTCBDb3JwMTQwMgYDVQQDDCtTU0wuY29tIENvZGUgU2lnbmlu
# ZyBJbnRlcm1lZGlhdGUgQ0EgUlNBIFIxMB4XDTI2MTAxMzAyNDgwMloXDTI3MTAx
# MzAyNDgwMlowXDELMAkGA1UEBhMCRlIxGzAZBgNVBAcMEkNoYW50ZWxvdXAtRW4t
# QnJpZTEXMBUGA1UECgwOTmljb2xhcyBGYWJlcnQxFzAVBgNVBAMMDk5pY29sYXMg
# RmFiZXJ0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsg6CT0mFQ4jB
# V2plIS4uWFSoVqRHd82Y7XYZ4CUTe/7nPBRUlXXdKTZMMHzGgiG8dEXNE8K1Xe90
# Dgl/FnorzAFlrNWSwf6t27UAUw9xkqtRDVVpVgpixpWkAwjcQeLG+YMqBkGbFi35
# TGvS23lPFWvLp4DxARrv15MtZ/NjNTCAAGUlMP2hFVBknEmrnYjEGyeJ93sl20RS
# WXQQLNqlenBdkGCrQW4XjHtRjJAEqAC68hN6nWevopSQ8CLUV7A1RFfHFarDrzrL
# zr0/NjIdSyIfM9hShln31NDrktB6Ups2XIyrtPDNB7fjkW4jpLlOqQGfYKsU9ErE
# 4SnFsh0yOOjitegyh1RvZ9wH++3DF4CmJfTli5l/gEIm8xCCryxI+K5EogW3wu1y
# u8NT2hcvHjdh7OpRyPyFAuLZ8MfX7kPAJpnuCeOuktzY/20eVD8bDglj+4zgqzsn
# cR/t6T/7w1/HxpRyrVoKvEyRx+mphYh5jMdEa0BjxOL0vAJpdGZSfXGmPm/yPqRn
# 5STTkMtzkVQXPbcvgKM0luzFcQKPHk3qdHLEXa8gf93ktYDbLE5Wd2UHrXz3SZxN
# URHPdIXCr1qgrqQve7041kMpzrkDI5DnG2lvRG4108gp02bHG0muKyZlDdCOra7h
# Zonu2nO79sFallruzzNi0o994PoWksUCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQC
# MAAwHwYDVR0jBBgwFoAUVML+EJUAk81q9efA19myS7iPDOMwegYIKwYBBQUHAQEE
# bjBsMEgGCCsGAQUFBzAChjxodHRwOi8vY2VydC5zc2wuY29tL1NTTGNvbS1TdWJD
# QS1Db2RlU2lnbmluZy1SU0EtNDA5Ni1SMS5jZXIwIAYIKwYBBQUHMAGGFGh0dHA6
# Ly9vY3Nwcy5zc2wuY29tMFEGA1UdIARKMEgwCAYGZ4EMAQQBMDwGDCsGAQQBgqkw
# AQMDATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3JlcG9zaXRv
# cnkwEwYDVR0lBAwwCgYIKwYBBQUHAwMwTQYDVR0fBEYwRDBCoECgPoY8aHR0cDov
# L2NybHMuc3NsLmNvbS9TU0xjb20tU3ViQ0EtQ29kZVNpZ25pbmctUlNBLTQwOTYt
# UjEuY3JsMB0GA1UdDgQWBBRoUx3630l9wA1fUpkKkw2GUIxl/jAOBgNVHQ8BAf8E
# BAMCB4AwDQYJKoZIhvcNAQELBQADggIBAE3oj6cNuwlDToi1BwjgsA5djfRN4DIi
# BYDFZIRYaIRe/rEdnItz3aqQQdFuwXnJA/MQEmi2WAGek8GeZF+R41s8FbcDxBUE
# BoSt98TuBE+0xgxQWDiPhhXaX1Aw9V0GF4ZnlfCSw1eu2KiASaKn7Bo0PLbEAXff
# vftRXof/kyqtw8iID6I4Rhrf5DI3WVZQodakUUmWnbnziWvEZOWbNOfzwP+7BwEt
# 7jQANfbmEfb4p75rfy5dQVwniTDSvdo6xkrbe1Cr93GS7cJta18IG5CoIVUmdK+s
# W38B1sLuy8Mi0MstMXV3004yaRuzLdNaAM0f9WAFerxemiQC0kdmA44/lWV3lVkM
# WJSwkHBkkSg8Eh0hxcGzTH2xmtDhLJHNNLRwkI9u2Ur+HbLCt50oBgSV8BcCs/1i
# qi884iC/yuX+HIv9YgTUNZ8c4lLaq4VuliJpXLu2buHIsTkO0v0+5oCM91zjTVZm
# ULeH38N0Vr83psiJVuBSxQyt5nRVrpYz7FACq5gtXELkyViq/rGOlJKaRrgQ6WWq
# eoIXqKhVFAdP/jAEm2M8ezoVYsUgPyKY2OcuecV9coulAcxUIUydx6qYiOfsGj5u
# Dy7l4aYjvB771wkUMzUQwxzcDYXJtMMTaWRe6n9EemR67jc73u5CJyFg3PfA5WR1
# wZislcdCZuS6MYISbDCCEmgCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBYPG2V2deL
# o3kvJv+PxwsDmb8eJyR6JS0PFpiPAQ7CmjANBgkqhkiG9w0BAQEFAASCAgBJ2Yh1
# tIb5HxzHA0lqs/RmJfSCOJ/jPSVfVsJEJh1UI6qL8rV1C7PHOUUJg2UW+cnr5C+S
# yVkOgb1ig44UWO3P0XG0fFAVsAa16E1tfSoOfafKaH5e6l5mKy+lF3GfGAdtKUtE
# Ik2gMPeJx6Im/02VUSp6Bsi9Te3j2WAnxZtHjBmowTDmNVWAu8SiNwTU7WcrNQ3Z
# aPCiEo17p+Z3oPOKiGmmLUh2+uJ/ccZ8GEK47boiX/K+jf/OdUTL/Y8HCu/7rDd8
# wzkcRp8BYuvkqza37Xam4KEVwcWWNJfva0xxHUEtV6ai/1roE5CmM0wbYkGCnZdq
# jH3JkN75DBiuzID7m+w9beGimO6oKqEJwh91pkZcUkaeRCWFnsMn66lX4Yofl+T/
# B2QyF2fElirQ4waW++TNDb27Vv42Uo9sG9f4RkWja3yY59ccy/6R1X/K0xZbeGa+
# xbEwqEPqtUzLB4cHySIzOBZoWD15B3lQWMdsr6S76+CABagIYbdR3N+lnyUgLqng
# 9vHKZnxKY4gMr+FATzl+aEyhHh1DDT/BsVI0g93QzyKCvxdPFyzjMX0PpARQuKDM
# LhhDhv1v9JpqFJIl6bZzKJ8GEX8sESf52qxmHS8EkrY+TTUnMYHWBTswix7C6nVc
# wjze3qSoDRSQ3UrsiQLxuVfUUoa4rajUwzwqf6GCDykwgg8lBgorBgEEAYI3AwMB
# MYIPFTCCDxEGCSqGSIb3DQEHAqCCDwIwgg7+AgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIJXKmpRlvn9RSdKN/Hn5UlbsvBGJXPT4h/jWyu7/VQ7YAgg6UFVJTDD2
# bhgPMjAyNjEwMTQyMDA4MzNaMAMCAQECEFmqchI6HeFe1i2dwmhih8GgggwAMIIE
# /DCCAuSgAwIBAgIQH2sWYtIuG2xd8cDBoGAOODANBgkqhkiG9w0BAQsFADBzMQsw
# CQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAP
# BgNVBAoMCFNTTCBDb3JwMS8wLQYDVQQDDCZTU0wuY29tIFRpbWVzdGFtcGluZyBJ
# c3N1aW5nIFJTQSBDQSBSMTAeFw0yNTAyMTgxNjMyMDJaFw0zNDExMTIxODUwMDVa
# MG4xCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3Rv
# bjERMA8GA1UECgwIU1NMIENvcnAxKjAoBgNVBAMMIVNTTC5jb20gVGltZXN0YW1w
# aW5nIFVuaXQgMjAyNSBFMTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABBv7UVHH
# b+ZVluxPXlfE3M6tg0Xnq8dic+O3vPOCRpalUM1vO9A+GRzSVVjyygHhYrBw62XL
# Fh1kv7e+yRd/aTajggFaMIIBVjAfBgNVHSMEGDAWgBQMnRAljpqnG5mHQ88IfuG9
# gZD0zzBRBggrBgEFBQcBAQRFMEMwQQYIKwYBBQUHMAKGNWh0dHA6Ly9jZXJ0LnNz
# bC5jb20vU1NMLmNvbS10aW1lU3RhbXBpbmctSS1SU0EtUjEuY2VyMFEGA1UdIARK
# MEgwPAYMKwYBBAGCqTABAwYBMCwwKgYIKwYBBQUHAgEWHmh0dHBzOi8vd3d3LnNz
# bC5jb20vcmVwb3NpdG9yeTAIBgZngQwBBAIwFgYDVR0lAQH/BAwwCgYIKwYBBQUH
# AwgwRgYDVR0fBD8wPTA7oDmgN4Y1aHR0cDovL2NybHMuc3NsLmNvbS9TU0wuY29t
# LXRpbWVTdGFtcGluZy1JLVJTQS1SMS5jcmwwHQYDVR0OBBYEFM582cAEgMUkEGoJ
# 6hyrJT0R/ajSMA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAgHN1
# JIW9ZlNip07FfY9r1LJwLKTl1h/y9r1BjDgHMEz7U7J7mAy32JxA1KLyjCCJqNku
# RfhDHGFEfZtjTOru7AQMDSDiUDvCCc3jaz5py9jGvwIe5npkLbXqXhA+SqCzG719
# USigwhHkYr7v8NiXoaY0Xu03p0BiZZreZlpngmGB9+86N94FqIFx2I5Z5iuu7d4j
# 7aAOZBNxfU9jFDIIGDtWfWeCpF0Q8rLE/3DHDlzJKs5Il3i/VoOl7rTU938oSrxM
# www6GDBlKX8rGHxvkjgIb9MXkVglJSDHsNAZDeCS/inaxKHA+ChuB8K4OxIxa6k1
# e+eHBypakAY3wuN7w7PlPmhN6k5IdqZn3HZHs2VjoR841Z9wmVPFdGDdkBZ7XOmb
# 5OZUaKufsvtER0VbY2DkzaqAaItt1kc+I+FUz7PiVz2PUzpegkftRRxvrPyIL08b
# lJTnbMQ0XrqDN0rEfuTLv4XhhnKyJaXhxCUdjO/cRumMzZ35QTUMItBWy1xGp0iy
# oFVnAya2pPsVMuAI+sy1zxlOS9l5iSxvKJ8gpnpOgjqYTa7u1eyZo+4JlcGoiiR1
# 7LthMTrF1q62tO5xOpI8txUZ6gtKGtkJV6wdj+vZLcwKZ2M93GqVpOo6UBlGjx1s
# KsVZ7AIUzJZli4NJ0M2KYcrfNnlebkYKpDnSqWwwggb8MIIE5KADAgECAhBtUhhw
# h+gjTYVgANCAj5NWMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMQ4wDAYD
# VQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NMIENvcnBv
# cmF0aW9uMTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRo
# b3JpdHkgUlNBMB4XDTE5MTExMzE4NTAwNVoXDTM0MTExMjE4NTAwNVowczELMAkG
# A1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYD
# VQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNvbSBUaW1lc3RhbXBpbmcgSXNz
# dWluZyBSU0EgQ0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCu
# URAT0vk8IKAghd7JUBxkyeH9xek0/wp/MUjoclrFXqhh/fGH91Fc+7fm0MHCE7A+
# wmOiqBj9ODrJAYGq3rm33jCnHSsCBNWAQYyoauLq8IjqsS1JlXL29qDNMMdwZ8UN
# zQS7vWZMDJ40JSGNphMGTIA2qn2bohGtgRc4p1395ESypUOaGvJ3t0FNL3BuKmb6
# YctMcQUF2sqooMzd89h0E6ujdvBDo6ZwNnWoxj7YmfWjSXg33A5GuY9ym4QZM5OE
# Vgo8ebz/B+gyhyCLNNhh4Mb/4xvCTCMVmNYrBviGgdPZYrym8Zb84TQCmSuX0JlL
# La6WK1aO6qlwISbb9bVGh866ekKblC/XRP20gAu1CjvcYciUgNTrGFg8f8AJgQPO
# Cc1/CCdaJSYwhJpSdheKOnQgESgNmYZPhFOC6IKaMAUXk5U1tjTcFCgFvvArXtK4
# azAWUOO1Y3fdldIBL6LjkzLUCYJNkFXqhsBVcPMuB0nUDWvLJfPimstjJ8lF4S6E
# CxWnlWi7OElVwTnt1GtRqeY9ydvvGLntU+FecK7DbqHDUd366UreMkSBtzevAc9a
# qoZPnjVMjvFqV1pYOjzmTiVHZtAc80bAfFe5LLfJzPI6DntNyqobpwTevQpHqPDN
# 9qqNO83r3kaw8A9j+HZiSw2AX5cGdQP0kG0vhzfgBwIDAQABo4IBgTCCAX0wEgYD
# VR0TAQH/BAgwBgEB/wIBADAfBgNVHSMEGDAWgBTdBAkHovV6fVJTEpKV7jiAJQ2m
# WTCBgwYIKwYBBQUHAQEEdzB1MFEGCCsGAQUFBzAChkVodHRwOi8vd3d3LnNzbC5j
# b20vcmVwb3NpdG9yeS9TU0xjb21Sb290Q2VydGlmaWNhdGlvbkF1dGhvcml0eVJT
# QS5jcnQwIAYIKwYBBQUHMAGGFGh0dHA6Ly9vY3Nwcy5zc2wuY29tMD8GA1UdIAQ4
# MDYwNAYEVR0gADAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3Jl
# cG9zaXRvcnkwEwYDVR0lBAwwCgYIKwYBBQUHAwgwOwYDVR0fBDQwMjAwoC6gLIYq
# aHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0GA1Ud
# DgQWBBQMnRAljpqnG5mHQ88IfuG9gZD0zzAOBgNVHQ8BAf8EBAMCAYYwDQYJKoZI
# hvcNAQELBQADggIBAJIZdQ2mWkLPGQfZ8vyU+sCb8BXpRJZaL3Ez3VDlE3uZk3cP
# xPtybVfLuqaci0W6SB22JTMttCiQMnIVOsXWnIuAbD/aFTcUkTLBI3xys+wEajzX
# aXJYWACDS47BRjDtYlDW14gLJxf8W6DQoH3jHDGGy8kGJFOlDKG7/YrK7UGfHtBA
# EDVe6lyZ+FtCsrk7dD/IiL/+Q3Q6SFASJLQ2XI89ihFugdYL77CiDNXrI2MFspQG
# swXEAGpHuaQDTHUp/LdR3TyrIsLlnzoLskUGswF/KF8+kpWUiKJNC4rPWtNrxlbX
# YRGgdEdx8SMjUTDClldcrknlFxbqHsVmr9xkT2QtFmG+dEq1v5fsIK0vHaHrWjMM
# maJ9i+4qGJSD0stYfQ6v0PddT7EpGxGd867Ada6FZyHwbuQSadMb0K0P0OC2r7rw
# qBUe0BaMqTa6LWzWItgBjGcObXeMxmbQqlEz2YtAcErkZvh0WABDDE4U8GyV/32F
# daAvJgTfe9MiL2nSBioYe/g5mHUSWAay/Ip1RQmQCvmF9sNfqlhJwkjy/1U1ibUk
# TIUBX3HgymyQvqQTZLLys6pL2tCdWcjI9YuLw30rgZm8+K387L7ycUvqrmQ3ZJlu
# jHl3r1hgV76s3WwMPgKk1bAEFMj+rRXimSC+Ev30hXZdqyMdl/il5Ksd0vhGMYIC
# WDCCAlQCAQEwgYcwczELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYD
# VQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNv
# bSBUaW1lc3RhbXBpbmcgSXNzdWluZyBSU0EgQ0EgUjECEB9rFmLSLhtsXfHAwaBg
# DjgwCwYJYIZIAWUDBAIBoIIBYTAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MTAxNDIwMDgzM1owKAYJKoZIhvcNAQk0MRswGTAL
# BglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIM8/B2PDmerA
# XQ/xXJ0/+iQBYxXCQjmP3KpxIevoDEeiMIHJBgsqhkiG9w0BCRACLzGBuTCBtjCB
# szCBsAQgVCr5oWqNci5mEUl4iumUwYqaruWmXLNEolSa+Wx5x4swgYswd6R1MHMx
# CzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjER
# MA8GA1UECgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5n
# IElzc3VpbmcgUlNBIENBIFIxAhAfaxZi0i4bbF3xwMGgYA44MAoGCCqGSM49BAMC
# BEcwRQIgGtxCY4LYUOj4XYMpc5mumOVBSWTf45qhY/wFuQLBs9cCIQCaHuoh1aCp
# 3t7P3RjKDne9CStJXzDRObZPDBTAXKkq5A==
# SIG # End signature block
