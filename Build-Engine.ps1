<#
.SYNOPSIS
    Builds the Group Inventory engine (.NET 8 + SQLite) offline into engine\bin.
.DESCRIPTION
    No package is downloaded: SQLite comes from the DLLs already present in lib\sqlite and the
    engine is a plain class library (engine\GroupInventory.Engine.csproj).
    When the .NET 8 targeting pack is not installed, the engine is compiled against the newest
    installed Microsoft.NETCore.App 8.0.x runtime (found with 'dotnet --list-runtimes') instead.
    The build fails with a precise message when neither the SDK nor a .NET 8 runtime is available.
    Invoke-M365GroupsReporting.ps1 loads the result from engine\bin; rebuild after changing src.
.PARAMETER Configuration
    Release (default) or Debug.
.PARAMETER OutputDir
    Output folder. Default: engine\bin next to this script.
.EXAMPLE
    .\Build-Engine.ps1
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug')] [string] $Configuration = 'Release',
    [string] $OutputDir
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { throw 'The script folder could not be resolved.' }
$project = Join-Path $root 'engine\GroupInventory.Engine.csproj'
if (-not $OutputDir) { $OutputDir = Join-Path $root 'engine\bin' }
if (-not (Test-Path -LiteralPath $project)) { throw "Engine project not found: $project" }
foreach ($f in 'Microsoft.Data.Sqlite.dll', 'SQLitePCLRaw.core.dll', 'SQLitePCLRaw.batteries_v2.dll', 'SQLitePCLRaw.provider.e_sqlite3.dll', 'runtimes\win-x64\e_sqlite3.dll') {
    if (-not (Test-Path -LiteralPath (Join-Path $root "lib\sqlite\$f"))) { throw "Missing local SQLite file lib\sqlite\$f (the build never downloads dependencies)." }
}

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) { throw 'The dotnet SDK was not found in PATH. Install a .NET SDK (8.0 or later) to build the engine.' }
$sdks = @(& $dotnet.Source --list-sdks 2>$null)
if ($sdks.Count -eq 0) { throw 'No .NET SDK is installed (dotnet --list-sdks is empty): a runtime alone cannot build the engine.' }

# Is the .NET 8 targeting pack installed? (packs\Microsoft.NETCore.App.Ref\8.*)
$dotnetRoot = ($sdks | Select-Object -Last 1) -replace '^\S+\s+\[(.*)\]$', '$1'
$dotnetRoot = Split-Path -Parent $dotnetRoot
$packDir = Join-Path $dotnetRoot 'packs\Microsoft.NETCore.App.Ref'
$havePack = (Test-Path -LiteralPath $packDir) -and @(Get-ChildItem -LiteralPath $packDir -Directory -Filter '8.*' -ErrorAction SilentlyContinue).Count -gt 0

$buildArgs = @('build', $project, '-c', $Configuration, '-o', $OutputDir, '--nologo', '-v:minimal', '-p:UseSharedCompilation=false')
if ($havePack) {
    Write-Host 'Using the installed .NET 8 targeting pack.' -ForegroundColor DarkGray
} else {
    $rt = @(& $dotnet.Source --list-runtimes 2>$null | ForEach-Object {
            if ($_ -match '^Microsoft\.NETCore\.App\s+(8\.\d+\.\d+)\s+\[(.*)\]$') { [pscustomobject]@{ Version = [version]$Matches[1]; Dir = (Join-Path $Matches[2] $Matches[1]) } }
        } | Sort-Object Version -Descending)
    if ($rt.Count -eq 0) { throw 'Neither the .NET 8 targeting pack nor a Microsoft.NETCore.App 8.0.x runtime is installed. Install the .NET 8 SDK or runtime; nothing is downloaded by this script.' }
    Write-Host "No .NET 8 targeting pack: compiling against the local runtime $($rt[0].Version) (offline)." -ForegroundColor Yellow
    $buildArgs += "-p:Net8RuntimeDir=$($rt[0].Dir)"
}

$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
& $dotnet.Source @buildArgs
if ($LASTEXITCODE -ne 0) { throw "Engine build failed (dotnet exit code $LASTEXITCODE)." }

$dll = Join-Path $OutputDir 'GroupInventory.Engine.dll'
if (-not (Test-Path -LiteralPath $dll)) { throw "Build reported success but $dll is missing." }
$asm = [System.Reflection.AssemblyName]::GetAssemblyName($dll)
Write-Host "Engine built: $dll (assembly version $($asm.Version))" -ForegroundColor Green

# SIG # Begin signature block
# MIIRWAYJKoZIhvcNAQcCoIIRSTCCEUUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCX6wk6MBsN2C+Q
# Ph++K4jXQQIA7zsb1V/MfiEC0OLY0aCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# wZislcdCZuS6MYIDPzCCAzsCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDtM4O3jVwq
# Zok80/9Wc/1dtYcBYSOX/NshHOeURWkSJjANBgkqhkiG9w0BAQEFAASCAgAVRlkf
# NqpOY56g42bCRcEKpVkYTeyBx/j04EAfw5SnvyIwY6K2vegeTHRWL0R0Hpl81xj+
# viMoYlPIZMIZfCA0cc1Vj5Mll/2kwa7r8Mpql2wmeig+q2/JhTJHGwRl1KXIMfuo
# 7f73DtRe2ARGkA3vreKOrQBITqXSBMN0X+xVgjqas/wZlwMzmbbaGSzoH1RYaNcV
# jXqGvriiEHcyOtL3xFHs0PdBQUv8Cyep7M38228xdvcoD65IFuaJoEsvAzQMHoj0
# EZFGcmG8b3kVSKs2MBsXxq5J/UMJVvDgULj9o57dFLOtNsnpl4UOPtbuUd0Izz//
# xSs/UGnK6RRlEcngRVa1/8k8dRiWpm43m6V8t5jZLe8xIjL36ndSk2eKDZR9rKrk
# PovxIL65rscvwPOT7lPLoAdhanJzJwRMDzWmXispnde2ckFErPXPm61SVuRdNJEL
# r6J/wgFu8VO4Ex8jkbZD/4fxYEEIMtT0dvnuAaTn+39yD9r/SuBHV4iVbq4QCW4B
# DQLdv//HoXvwzY8GevSA6GC2Kycurh1mfp5l+u8vts5mK6Wd3YemH5TXGI92XMOu
# mvkLMYVew17w132pAA4cMF3zTMSyBd1Ayr8dMcO6KikkF5eaMwFrlTMD5Fk4Op39
# FbWzXv2WOmtcFEzrDyfU7LQjn56pOa7cX6ul9Q==
# SIG # End signature block
