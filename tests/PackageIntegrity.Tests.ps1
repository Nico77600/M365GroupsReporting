#Requires -Version 7.4
# Policy tests use explicitly synthetic signature results; native rejection tests are separate.
Describe 'Runtime package integrity policy (offline signing preparation)' {
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        $signer = '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6'
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Test-PackageIntegrity.ps1'), [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw 'Verifier syntax failed.' }
        foreach ($definition in $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $false)) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $required = @(Get-InventoryPaths Package)
        function New-IntegrityFixture {
            $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($folder)
            foreach ($relative in $required) {
                $path = Join-Path $folder $relative
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
                [IO.File]::WriteAllBytes($path, [Text.Encoding]::UTF8.GetBytes("synthetic immutable bytes: $relative`r`n"))
            }
            [void][IO.Directory]::CreateDirectory((Join-Path $folder 'config'))
            Set-Content (Join-Path $folder 'config\M365GroupsReporting.config.psd1') '@{}'
            $manifest = @{
                SchemaVersion = 1; Algorithm = 'SHA256'; SignerThumbprint = $signer
                Files = @($required | ForEach-Object {
                    @{ Path = $_; Sha256 = (Get-FileHash -LiteralPath (Join-Path $folder $_)).Hash }
                })
            }
            @{ Root = $folder; Manifest = $manifest }
        }
    }
    BeforeEach {
        $fixture = New-IntegrityFixture
        Mock Assert-OwnerSignature {}
    }
    It 'requires the actual relocated compiled engine and both copies of the template' {
        $required | Should -Contain 'lib\engine\GroupInventory.Engine.dll'
        $required | Should -Contain 'lib\engine\GroupInventory.template.html'
        $required | Should -Contain 'templates\GroupInventory.template.html'
        $required | Should -Not -Contain 'config\M365GroupsReporting.config.psd1'
        { Assert-ManifestInventory $fixture.Manifest $required $fixture.Root } | Should -Not -Throw
        Should -Invoke Assert-OwnerSignature -Times 3 -Exactly
    }
    It 'rejects an omitted compiled DLL rather than accepting a source hash manifest' {
        $fixture.Manifest.Files = @($fixture.Manifest.Files | Where-Object Path -ne 'lib\engine\GroupInventory.Engine.dll')
        { Assert-ManifestInventory $fixture.Manifest $required $fixture.Root } | Should -Throw '*incomplete manifest*'
    }
    It 'rejects traversal, absolute, source-layout, noncanonical and duplicate manifest paths' {
        foreach ($path in '..\engine.dll', 'C:\engine.dll', 'engine\bin\GroupInventory.Engine.dll',
            'lib/engine/GroupInventory.Engine.dll', 'lib\engine\..\engine\GroupInventory.Engine.dll') {
            $fixture = New-IntegrityFixture
            $fixture.Manifest.Files[0].Path = $path
            { Assert-ManifestInventory $fixture.Manifest $required $fixture.Root } | Should -Throw '*unapproved inventory*'
        }
        $fixture = New-IntegrityFixture
        $fixture.Manifest.Files[1] = $fixture.Manifest.Files[0].Clone()
        { Assert-ManifestInventory $fixture.Manifest $required $fixture.Root } | Should -Throw '*unapproved inventory*'
    }
    It 'rejects malformed hashes, changed algorithm and untrusted manifest signer pins' {
        $fixture.Manifest.Files[0].Sha256 = 'not-a-sha256'
        { Assert-ManifestInventory $fixture.Manifest $required $fixture.Root } | Should -Throw '*unapproved inventory*'
        $fixture = New-IntegrityFixture
        $fixture.Manifest.Algorithm = 'SHA1'
        { Assert-ManifestInventory $fixture.Manifest $required $fixture.Root } | Should -Throw '*incomplete manifest*'
        $fixture = New-IntegrityFixture
        $fixture.Manifest.SignerThumbprint = '1111111111111111111111111111111111111111'
        { Assert-ManifestInventory $fixture.Manifest $required $fixture.Root } | Should -Throw '*incomplete manifest*'
    }
    It 'rejects changes to every protected file, including DLLs, native libraries, templates and verifier' {
        foreach ($relative in $required) {
            $fixture = New-IntegrityFixture
            [IO.File]::AppendAllText((Join-Path $fixture.Root $relative), 'changed')
            { Assert-ManifestInventory $fixture.Manifest $required $fixture.Root } | Should -Throw '*SHA256 mismatch*'
        }
    }
    It 'rejects each missing immutable file' {
        foreach ($relative in $required) {
            $fixture = New-IntegrityFixture
            Remove-Item -LiteralPath (Join-Path $fixture.Root $relative)
            { Assert-ManifestInventory $fixture.Manifest $required $fixture.Root } | Should -Throw
        }
    }
    It 'allows operational configuration changes without changing immutable hashes' {
        Set-Content (Join-Path $fixture.Root 'config\M365GroupsReporting.config.psd1') "@{ TenantId = 'synthetic-customization' }"
        { Assert-ManifestInventory $fixture.Manifest $required $fixture.Root } | Should -Not -Throw
        { Assert-StableInventory $fixture.Root $required Package } | Should -Not -Throw
    }
    It 'rejects extra stable code and unknown documentation names' {
        foreach ($relative in 'lib\engine\extra.dll', 'docs\extra.ps1', 'docs\unknown.md', 'config\extra.psd1',
            'app_creds.ps1', 'siteurls.ps1', 'extra.json', 'extra.csv') {
            $fixture = New-IntegrityFixture
            Set-Content -LiteralPath (Join-Path $fixture.Root $relative) 'synthetic'
            { Assert-StableInventory $fixture.Root $required Package } | Should -Throw '*unexpected stable file*'
        }
    }
    It 'does not accept source/build/CI/tests in a runtime inventory' {
        Set-Content -LiteralPath (Join-Path $fixture.Root 'Build-Engine.ps1') 'synthetic'
        { Assert-StableInventory $fixture.Root $required Package } | Should -Throw '*unexpected stable file*'
    }
    It 'keeps runtime outputs outside executable authority' {
        foreach ($name in 'data', 'logs', 'reports') {
            [void][IO.Directory]::CreateDirectory((Join-Path $fixture.Root $name))
            Set-Content (Join-Path $fixture.Root "$name\never-loaded.dll") 'not trusted code'
        }
        { Assert-StableInventory $fixture.Root $required Package } | Should -Not -Throw
    }
    It 'preserves exact compatibility credential and SharePoint CSV input paths without hashing them' {
        Set-Content (Join-Path $fixture.Root 'app_creds.json') '{"TenantId":"synthetic-only"}'
        Set-Content (Join-Path $fixture.Root 'siteurls.csv') 'GroupId,Url'
        $required | Should -Not -Contain 'app_creds.json'
        $required | Should -Not -Contain 'siteurls.csv'
        { Assert-ManifestInventory $fixture.Manifest $required $fixture.Root } | Should -Not -Throw
        { Assert-StableInventory $fixture.Root $required Package } | Should -Not -Throw
    }
    It 'retains exact bytes for every manifest path in gitattributes' {
        foreach ($relative in @(Get-InventoryPaths Source)) {
            $attribute = @(git -C $root check-attr text -- $relative)
            $LASTEXITCODE | Should -Be 0
            $attribute[0] | Should -Match ': text: unset$'
        }
    }
    It 'Git clean filters round-trip every immutable source byte without normalization' {
        foreach ($relative in @(Get-InventoryPaths Source)) {
            $path = Join-Path $root $relative
            $raw = @(git -C $root hash-object --no-filters -- $path)
            $LASTEXITCODE | Should -Be 0
            $gitPath = $relative.Replace('\', '/')
            $filtered = @(git -C $root hash-object "--path=$gitPath" -- $path)
            $LASTEXITCODE | Should -Be 0
            $filtered[0] | Should -BeExactly $raw[0]
        }
    }
    It 'rejects protected junction paths before trusting any child file' {
        $target = Join-Path $TestDrive 'junction-target'
        [void][IO.Directory]::CreateDirectory($target)
        $link = Join-Path $fixture.Root 'protected-junction'
        [void](New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop)
        { Assert-StableInventory $fixture.Root $required Package } | Should -Throw '*reparse point*'
        { Assert-PlainPath $link $true } | Should -Throw '*unsafe path*'
    }
    It 'has distinct source and package inventories, never sanitizable configuration or stale source paths' {
        $source = @(Get-InventoryPaths Source)
        $source | Should -Contain 'src\GroupInventory.Engine.Engine.cs'
        $source | Should -Not -Contain 'lib\engine\GroupInventory.Engine.dll'
        $source | Should -Not -Contain 'config\M365GroupsReporting.config.psd1'
        foreach ($path in $required) { $path | Should -Not -Match '^(src|engine|tools|tests|\.github)\\' }
    }
}

Describe 'Native and bootstrap rejection without a signing device' {
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        $signer = '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6'
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Test-PackageIntegrity.ps1'), [ref]$tokens, [ref]$errors)
        $signaturePolicy = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-OwnerSignature'
        }, $false)[0].Extent.Text
        # Explicit unit adapter: these synthetic results never claim native authentication.
        . ([scriptblock]::Create($signaturePolicy.Replace(
            'Microsoft.PowerShell.Security\Get-AuthenticodeSignature', 'Get-SyntheticSignature')))
        function Get-SyntheticSignature { param($LiteralPath, $ErrorAction) $script:TestSignature }
        $entryAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Invoke-M365GroupsReporting.ps1'), [ref]$tokens, [ref]$errors)
        foreach ($definition in $entryAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @('Assert-M365GroupsRuntime', 'Import-GroupInventoryEngine')
        }, $false)) { . ([scriptblock]::Create($definition.Extent.Text)) }
    }
    It 'requires a trusted timestamped signer even when a synthetic status says Valid' {
        $script:TestSignature = [pscustomobject]@{
            Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Thumbprint = $signer }
            TimeStamperCertificate = [pscustomobject]@{ Thumbprint = 'synthetic-timestamp' }
        }
        { Assert-OwnerSignature 'synthetic.ps1' } | Should -Not -Throw
        $script:TestSignature.SignerCertificate.Thumbprint = '1111111111111111111111111111111111111111'
        { Assert-OwnerSignature 'synthetic.ps1' } | Should -Throw '*timestamped owner signature*'
        $script:TestSignature.SignerCertificate.Thumbprint = $signer
        $script:TestSignature.TimeStamperCertificate = $null
        { Assert-OwnerSignature 'synthetic.ps1' } | Should -Throw '*timestamped owner signature*'
        $script:TestSignature.Status = 'NotSigned'
        { Assert-OwnerSignature 'synthetic.ps1' } | Should -Throw '*timestamped owner signature*'
    }
    It 'rejects source entry execution without an explicit source-only development distinction' {
        { Assert-M365GroupsRuntime -Root $root } | Should -Throw '*source checkout*'
        { Assert-M365GroupsRuntime -Root $root -SourceDevelopment } | Should -Not -Throw
    }
    It 'cannot turn a runtime or pending artifact into source development by adding project markers' {
        $fixture = Join-Path $TestDrive 'pretend-source'
        foreach ($name in '.git', 'engine', 'src', 'lib\engine') {
            [void][IO.Directory]::CreateDirectory((Join-Path $fixture $name))
        }
        foreach ($name in 'engine\GroupInventory.Engine.csproj', 'src\GroupInventory.Engine.Engine.cs', 'Build-Engine.ps1') {
            Set-Content (Join-Path $fixture $name) 'synthetic'
        }
        { Assert-M365GroupsRuntime -Root $fixture -SourceDevelopment } | Should -Throw '*never a runtime artifact*'
        Remove-Item -LiteralPath (Join-Path $fixture 'lib\engine')
        Set-Content (Join-Path $fixture '.publication-pending') 'pending'
        { Assert-M365GroupsRuntime -Root $fixture -SourceDevelopment } | Should -Throw '*never a runtime artifact*'
    }
    It 'checks a pending artifact before loading an already-loaded engine type or any DLL' {
        $fixture = Join-Path $TestDrive 'pending-runtime'
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'lib\engine'))
        Set-Content (Join-Path $fixture '.publication-pending') 'pending'
        { Import-GroupInventoryEngine -EngineDir (Join-Path $fixture 'lib\engine') } | Should -Throw '*signing is pending*'
    }
    It 'rejects a pending source-shaped engine directory even when source markers are present' {
        $fixture = Join-Path $TestDrive 'pending-source-engine'
        foreach ($name in '.git', 'engine\bin', 'src') {
            [void][IO.Directory]::CreateDirectory((Join-Path $fixture $name))
        }
        foreach ($name in 'engine\GroupInventory.Engine.csproj', 'src\GroupInventory.Engine.Engine.cs', 'Build-Engine.ps1',
            '.publication-pending') {
            Set-Content (Join-Path $fixture $name) 'synthetic'
        }
        { Import-GroupInventoryEngine -EngineDir (Join-Path $fixture 'engine\bin') } | Should -Throw '*only be loaded from a source Git checkout*'
    }
    It 'natively rejects an unsigned independent verifier before parsing an arbitrary manifest' {
        $fixture = Join-Path $TestDrive 'unsigned-verifier'
        [void][IO.Directory]::CreateDirectory($fixture)
        $unsigned = [IO.File]::ReadAllText((Join-Path $root 'Test-PackageIntegrity.ps1')) -replace '(?ms)^# SIG # Begin signature block.*\z', ''
        [IO.File]::WriteAllText((Join-Path $fixture 'Test-PackageIntegrity.ps1'), $unsigned, [Text.UTF8Encoding]::new($true))
        $sideEffect = Join-Path $fixture 'must-not-exist.txt'
        Set-Content (Join-Path $fixture 'M365GroupsReporting.PackageIntegrity.psd1') "Set-Content '$sideEffect' 'malicious'"
        # Preparation has no owner signature. Real native APIs, no test adapter.
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -File (Join-Path $fixture 'Test-PackageIntegrity.ps1') -Root $fixture *> (Join-Path $fixture 'native-rejection.txt')
        $LASTEXITCODE | Should -Not -Be 0
        Test-Path $sideEffect | Should -BeFalse
        Get-Content (Join-Path $fixture 'native-rejection.txt') -Raw | Should -Match 'timestamped owner signature'
    }
    It 'rejects source manifest interpretation for a runtime artifact before any signature parsing' {
        $fixture = Join-Path $TestDrive 'invalid-source-artifact'
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'lib\engine'))
        Copy-Item (Join-Path $root 'Test-PackageIntegrity.ps1') (Join-Path $fixture 'Test-PackageIntegrity.ps1')
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -File (Join-Path $fixture 'Test-PackageIntegrity.ps1') -Root $fixture -Layout Source *> (Join-Path $fixture 'source-rejection.txt')
        $LASTEXITCODE | Should -Not -Be 0
        Get-Content (Join-Path $fixture 'source-rejection.txt') -Raw | Should -Match 'cannot authenticate a runtime artifact'
    }
}

# SIG # Begin signature block
# MIIghQYJKoZIhvcNAQcCoIIgdjCCIHICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCIex+VV+Jwskog
# DTOD54TmISz49etkkaXtOp2NeHtXraCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDweemORJiZ
# dG7jpSTrd4Szc6LiZt2do83u51SViqX4aDANBgkqhkiG9w0BAQEFAASCAgAHDPUB
# zEFLVe98iWniNMlT0lZpMT51DKrj+jRclmtyXRBF0VA7PE1L6dpUFwWTTndXeMnv
# n/sd1jT3hROVYUNT8aZesYURJZ0M4u3Ntz4yxPaio2iDtcknG4p7pbauODelKfbJ
# hAHKQMumyoBJQQ4JXb00ubGiJX1EhImf4nT0SHLtO8BJPFC5Dh6Y0+OEAlYKv+aF
# oZGgbVvd3IGviGKRhDQfayMV7RvjCJnjw36zpp35/GtuUUPrPFAuq1dvvQ+YRfmc
# m78NcKp8clTakqBDrqa1ta4KBiKT2P/c8ChMMlHpq06q78zIdOgDglRYqgh2Q0bQ
# fhGwzBUzK25sJ/FlQr5DIN7wfLiplhFtFiv+nQ1lnv2RfZgjpPKnBnAMi1LP/t2n
# SxOv0HGMpnaxZNha1mtwH55lLqiT7Q6f8n1T45ynsFe9WnKwvD80Sod0Xw+trXyH
# lV7M/4l4dVPU/RllXeUVOV33h2aJbb3CNK3OFkGF9FQGOxalyp0qx90ULwtmvKz6
# NWzSVDqxMp4/zx0iQ8fFkY3FhyZaKNRSdo4rQH/EujmwiLkusRf2mp7ZRDEWY+uU
# VBziqeZT429Tn9AzxjD3ApIeYSX5hb1Nu8vaAxB0chzBjSfxT8I5Ayhke1cp0jLc
# P/zVe0GN1AYvFX0O63jAHZRaeQHfEkCc/BSTF6GCDykwgg8lBgorBgEEAYI3AwMB
# MYIPFTCCDxEGCSqGSIb3DQEHAqCCDwIwgg7+AgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIKR70Rs+1XJzfCrgi8iRygkAkFUzy+aWJG320CvQoAKHAghcRfzLhtOI
# MhgPMjAyNjEwMTQyMDA4MjlaMAMCAQECEHVhYdF/TqCZmWVdJZsrkEOgggwAMIIE
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
# HAYJKoZIhvcNAQkFMQ8XDTI2MTAxNDIwMDgyOVowKAYJKoZIhvcNAQk0MRswGTAL
# BglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIHGZPYbJ8Gqh
# fwUz1beSm7NTEvpcO4MncMaKoYq0TQDUMIHJBgsqhkiG9w0BCRACLzGBuTCBtjCB
# szCBsAQgVCr5oWqNci5mEUl4iumUwYqaruWmXLNEolSa+Wx5x4swgYswd6R1MHMx
# CzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjER
# MA8GA1UECgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5n
# IElzc3VpbmcgUlNBIENBIFIxAhAfaxZi0i4bbF3xwMGgYA44MAoGCCqGSM49BAMC
# BEcwRQIhAIGueNvhv8bua1bMqn/wqUxAxBflBryTu+NSAMMkK/s6AiAm1KvVZeju
# ixjV+IGwpeWZ9hYFOjdL6ESYyyCgDDz74g==
# SIG # End signature block
