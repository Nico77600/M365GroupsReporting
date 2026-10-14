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
    'M365GroupsReporting.PackageIntegrity.psd1',
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

# SIG # Begin signature block
# MIIghwYJKoZIhvcNAQcCoIIgeDCCIHQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAuUsDWrApxA0aV
# 91ihgjzZw6RQYLx2xrgPNfVC52V5gqCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# wZislcdCZuS6MYISbjCCEmoCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBb8r2ReEAa
# OcHUSzseic8IT5ndMSfC8pR1WA8UCYZ10zANBgkqhkiG9w0BAQEFAASCAgCmGtYm
# cfTlAh0t5ZeAlxeUdawe3fIRbmj5wh/j5BwJLR/qKeoEpjVbZ5B68sLhRGbIIFPJ
# l3V1svR6hHg4X38bgN5WHCOMlk/gGIendF2H7Xr94HKCyfKIjfWisvA7Om5NcqHa
# 6QpoRJzqSt6/pIc09HPGE+Hl1o+j5daX0ZITjxizFA/wHpsToc87PQ4DJpD865/p
# gWR9pXuf18xXuAGxtVZH1Qv3JAaPa7gJ+2EQw1BYJTMPwF9HPiTbd/i5AYnTyRAB
# D4rWOaPiP4X/L6+dINFLcTLwjNu5UGw+eSnj4FK8EJWXOSew7pTBOM1JgNypD5MW
# kVhnOlqkAYUtz9CMMipV31bUFk+9+upbe4XZJiQaisejn+0Bzdtq7E3HsUtHPICo
# MS/L2G0TkpIbYevCPfvTaznj18zQZ5/CfmVm9DAkqeGWHJl/4oT2nbPYQSFlHWYV
# Ei2O3buJn2dze3jXem9C2gJ4mp/q/lOFt8YiA9dF6wVK2zQlUOAM/VQ7cyrmL+7o
# +PJhVPbrJyOxvgXfh9IkK6c12gedPwB1/u23up0xs26Il4tjLkEGLwZLdPVxXs9g
# ewExE6OtpvUOKm6NGRCyG2uCFHPQPes9TGdAkRqdz1M+bYIab+ULDcFTaIJP1TN2
# ZZReXFek4WNmRZSryTOZfauvUYOczvi/vwoOHqGCDyswgg8nBgorBgEEAYI3AwMB
# MYIPFzCCDxMGCSqGSIb3DQEHAqCCDwQwgg8AAgEDMQ0wCwYJYIZIAWUDBAIBMIGK
# BgsqhkiG9w0BCRABBKB7BHkwdwIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIKKWa7JAxv5b/9AEDsACREBnXV7YHBlfYtHjhpi1V5NUAghpKwcEkRC6
# JBgPMjAyNjEwMTQxNzIxNTZaMAMCAQECEQDEespyxJSjvHl7XX+PtpXloIIMADCC
# BPwwggLkoAMCAQICEB9rFmLSLhtsXfHAwaBgDjgwDQYJKoZIhvcNAQELBQAwczEL
# MAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREw
# DwYDVQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNvbSBUaW1lc3RhbXBpbmcg
# SXNzdWluZyBSU0EgQ0EgUjEwHhcNMjUwMjE4MTYzMjAyWhcNMzQxMTEyMTg1MDA1
# WjBuMQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0
# b24xETAPBgNVBAoMCFNTTCBDb3JwMSowKAYDVQQDDCFTU0wuY29tIFRpbWVzdGFt
# cGluZyBVbml0IDIwMjUgRTEwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQb+1FR
# x2/mVZbsT15XxNzOrYNF56vHYnPjt7zzgkaWpVDNbzvQPhkc0lVY8soB4WKwcOtl
# yxYdZL+3vskXf2k2o4IBWjCCAVYwHwYDVR0jBBgwFoAUDJ0QJY6apxuZh0PPCH7h
# vYGQ9M8wUQYIKwYBBQUHAQEERTBDMEEGCCsGAQUFBzAChjVodHRwOi8vY2VydC5z
# c2wuY29tL1NTTC5jb20tdGltZVN0YW1waW5nLUktUlNBLVIxLmNlcjBRBgNVHSAE
# SjBIMDwGDCsGAQQBgqkwAQMGATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5z
# c2wuY29tL3JlcG9zaXRvcnkwCAYGZ4EMAQQCMBYGA1UdJQEB/wQMMAoGCCsGAQUF
# BwMIMEYGA1UdHwQ/MD0wO6A5oDeGNWh0dHA6Ly9jcmxzLnNzbC5jb20vU1NMLmNv
# bS10aW1lU3RhbXBpbmctSS1SU0EtUjEuY3JsMB0GA1UdDgQWBBTOfNnABIDFJBBq
# CeocqyU9Ef2o0jAOBgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQADggIBAIBz
# dSSFvWZTYqdOxX2Pa9SycCyk5dYf8va9QYw4BzBM+1Oye5gMt9icQNSi8owgiajZ
# LkX4QxxhRH2bY0zq7uwEDA0g4lA7wgnN42s+acvYxr8CHuZ6ZC216l4QPkqgsxu9
# fVEooMIR5GK+7/DYl6GmNF7tN6dAYmWa3mZaZ4JhgffvOjfeBaiBcdiOWeYrru3e
# I+2gDmQTcX1PYxQyCBg7Vn1ngqRdEPKyxP9wxw5cySrOSJd4v1aDpe601Pd/KEq8
# TMMMOhgwZSl/Kxh8b5I4CG/TF5FYJSUgx7DQGQ3gkv4p2sShwPgobgfCuDsSMWup
# NXvnhwcqWpAGN8Lje8Oz5T5oTepOSHamZ9x2R7NlY6EfONWfcJlTxXRg3ZAWe1zp
# m+TmVGirn7L7REdFW2Ng5M2qgGiLbdZHPiPhVM+z4lc9j1M6XoJH7UUcb6z8iC9P
# G5SU52zENF66gzdKxH7ky7+F4YZysiWl4cQlHYzv3EbpjM2d+UE1DCLQVstcRqdI
# sqBVZwMmtqT7FTLgCPrMtc8ZTkvZeYksbyifIKZ6ToI6mE2u7tXsmaPuCZXBqIok
# dey7YTE6xdautrTucTqSPLcVGeoLShrZCVesHY/r2S3MCmdjPdxqlaTqOlAZRo8d
# bCrFWewCFMyWZYuDSdDNimHK3zZ5Xm5GCqQ50qlsMIIG/DCCBOSgAwIBAgIQbVIY
# cIfoI02FYADQgI+TVjANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwG
# A1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jw
# b3JhdGlvbjExMC8GA1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0
# aG9yaXR5IFJTQTAeFw0xOTExMTMxODUwMDVaFw0zNDExMTIxODUwMDVaMHMxCzAJ
# BgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8G
# A1UECgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5nIElz
# c3VpbmcgUlNBIENBIFIxMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA
# rlEQE9L5PCCgIIXeyVAcZMnh/cXpNP8KfzFI6HJaxV6oYf3xh/dRXPu35tDBwhOw
# PsJjoqgY/Tg6yQGBqt65t94wpx0rAgTVgEGMqGri6vCI6rEtSZVy9vagzTDHcGfF
# Dc0Eu71mTAyeNCUhjaYTBkyANqp9m6IRrYEXOKdd/eREsqVDmhryd7dBTS9wbipm
# +mHLTHEFBdrKqKDM3fPYdBOro3bwQ6OmcDZ1qMY+2Jn1o0l4N9wORrmPcpuEGTOT
# hFYKPHm8/wfoMocgizTYYeDG/+MbwkwjFZjWKwb4hoHT2WK8pvGW/OE0Apkrl9CZ
# Sy2ulitWjuqpcCEm2/W1RofOunpCm5Qv10T9tIALtQo73GHIlIDU6xhYPH/ACYED
# zgnNfwgnWiUmMISaUnYXijp0IBEoDZmGT4RTguiCmjAFF5OVNbY03BQoBb7wK17S
# uGswFlDjtWN33ZXSAS+i45My1AmCTZBV6obAVXDzLgdJ1A1ryyXz4prLYyfJReEu
# hAsVp5VouzhJVcE57dRrUanmPcnb7xi57VPhXnCuw26hw1Hd+ulK3jJEgbc3rwHP
# WqqGT541TI7xaldaWDo85k4lR2bQHPNGwHxXuSy3yczyOg57TcqqG6cE3r0KR6jw
# zfaqjTvN695GsPAPY/h2YksNgF+XBnUD9JBtL4c34AcCAwEAAaOCAYEwggF9MBIG
# A1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKSle44gCUN
# plkwgYMGCCsGAQUFBwEBBHcwdTBRBggrBgEFBQcwAoZFaHR0cDovL3d3dy5zc2wu
# Y29tL3JlcG9zaXRvcnkvU1NMY29tUm9vdENlcnRpZmljYXRpb25BdXRob3JpdHlS
# U0EuY3J0MCAGCCsGAQUFBzABhhRodHRwOi8vb2NzcHMuc3NsLmNvbTA/BgNVHSAE
# ODA2MDQGBFUdIAAwLDAqBggrBgEFBQcCARYeaHR0cHM6Ly93d3cuc3NsLmNvbS9y
# ZXBvc2l0b3J5MBMGA1UdJQQMMAoGCCsGAQUFBwMIMDsGA1UdHwQ0MDIwMKAuoCyG
# Kmh0dHA6Ly9jcmxzLnNzbC5jb20vc3NsLmNvbS1yc2EtUm9vdENBLmNybDAdBgNV
# HQ4EFgQUDJ0QJY6apxuZh0PPCH7hvYGQ9M8wDgYDVR0PAQH/BAQDAgGGMA0GCSqG
# SIb3DQEBCwUAA4ICAQCSGXUNplpCzxkH2fL8lPrAm/AV6USWWi9xM91Q5RN7mZN3
# D8T7cm1Xy7qmnItFukgdtiUzLbQokDJyFTrF1pyLgGw/2hU3FJEywSN8crPsBGo8
# 12lyWFgAg0uOwUYw7WJQ1teICycX/Fug0KB94xwxhsvJBiRTpQyhu/2Kyu1Bnx7Q
# QBA1XupcmfhbQrK5O3Q/yIi//kN0OkhQEiS0NlyPPYoRboHWC++wogzV6yNjBbKU
# BrMFxABqR7mkA0x1Kfy3Ud08qyLC5Z86C7JFBrMBfyhfPpKVlIiiTQuKz1rTa8ZW
# 12ERoHRHcfEjI1EwwpZXXK5J5RcW6h7FZq/cZE9kLRZhvnRKtb+X7CCtLx2h61oz
# DJmifYvuKhiUg9LLWH0Or9D3XU+xKRsRnfOuwHWuhWch8G7kEmnTG9CtD9Dgtq+6
# 8KgVHtAWjKk2ui1s1iLYAYxnDm13jMZm0KpRM9mLQHBK5Gb4dFgAQwxOFPBslf99
# hXWgLyYE33vTIi9p0gYqGHv4OZh1ElgGsvyKdUUJkAr5hfbDX6pYScJI8v9VNYm1
# JEyFAV9x4MpskL6kE2Sy8rOqS9rQnVnIyPWLi8N9K4GZvPit/Oy+8nFL6q5kN2SZ
# box5d69YYFe+rN1sDD4CpNWwBBTI/q0V4pkgvhL99IV2XasjHZf4peSrHdL4RjGC
# AlkwggJVAgEBMIGHMHMxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4G
# A1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5j
# b20gVGltZXN0YW1waW5nIElzc3VpbmcgUlNBIENBIFIxAhAfaxZi0i4bbF3xwMGg
# YA44MAsGCWCGSAFlAwQCAaCCAWEwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEE
# MBwGCSqGSIb3DQEJBTEPFw0yNjEwMTQxNzIxNTZaMCgGCSqGSIb3DQEJNDEbMBkw
# CwYJYIZIAWUDBAIBoQoGCCqGSM49BAMCMC8GCSqGSIb3DQEJBDEiBCDJYtl2D9QH
# v3EhdMYVaDFoHnNgwEv9hKB8b/glaki1ATCByQYLKoZIhvcNAQkQAi8xgbkwgbYw
# gbMwgbAEIFQq+aFqjXIuZhFJeIrplMGKmq7lplyzRKJUmvlseceLMIGLMHekdTBz
# MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24x
# ETAPBgNVBAoMCFNTTCBDb3JwMS8wLQYDVQQDDCZTU0wuY29tIFRpbWVzdGFtcGlu
# ZyBJc3N1aW5nIFJTQSBDQSBSMQIQH2sWYtIuG2xd8cDBoGAOODAKBggqhkjOPQQD
# AgRIMEYCIQCWXp+M5NttcBjZTDL2PU2HQbgaUumG/0ARZRGTPrTyEAIhAKOQsrGQ
# j1YIdqIx02k4NfRkleJQdBWevIKJClkPr9nT
# SIG # End signature block
