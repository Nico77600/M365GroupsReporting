# Synthetic configuration, retention, package and documentation contract tests. No network or credentials.
Describe 'M365GroupsReporting Purview parity' {
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Invoke-M365GroupsReporting.ps1'),[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw ($errors.Message -join '; ') }
        $wanted='Resolve-M365GroupsPath','Import-M365GroupsConfiguration','Invoke-M365GroupsRetention','Invoke-M365GroupsLogRetention','Import-GroupInventoryEngine','Get-GraphAppToken','Export-InventoryReports'
        foreach ($def in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted},$false)) { . ([scriptblock]::Create($def.Extent.Text)) }
        Import-GroupInventoryEngine -EngineDir (Join-Path $root 'engine\bin')
        function Check($Value,[string]$Message) { if (-not $Value) { throw $Message } }
        function Reject([scriptblock]$Action,[string]$Pattern) {
            $message=$null;try { & $Action | Out-Null } catch { $message=$_.Exception.Message }
            if (-not $message -or $message -notmatch $Pattern) { throw "Expected rejection matching $Pattern, got: $message" }
        }
        function New-Snapshot([string]$Base,[string]$Name,[int]$Age,[switch]$Incomplete) {
            $folder=Join-Path $Base $Name;[void][IO.Directory]::CreateDirectory($folder)
            $options=New-Object GroupInventory.Engine.EngineOptions -Property @{DatabasePath=(Join-Path $folder 'M365GroupsReporting.sqlite');RunId=$Name;SkipMembers=$true;SitesRequired=$false}
            $engine=[GroupInventory.Engine.InventoryEngine]::Create($options)
            if (-not $Incomplete) { [void]$engine.CompleteFlow('enum',0);[void]$engine.Seal() }
            $engine.Dispose()
            if (-not $Incomplete) {
                $db=[Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$($options.DatabasePath);Pooling=False")
                try {$db.Open();$cmd=$db.CreateCommand();$cmd.CommandText="UPDATE engine_meta SET value=@date WHERE key='sealed_utc'";[void]$cmd.Parameters.AddWithValue('@date',[DateTimeOffset]::UtcNow.AddDays(-$Age).ToString('o'));[void]$cmd.ExecuteNonQuery()}finally{$db.Dispose()}
            }
            $folder
        }
        function New-PackageSource([string]$Name) {
            $folder=Join-Path $TestDrive $Name;[void][IO.Directory]::CreateDirectory($folder)
            foreach($relative in 'Invoke-M365GroupsReporting.ps1','Get-SiteUrls.ps1','README.md','THIRD-PARTY-NOTICES.md','M365GroupsReporting.PackageIntegrity.psd1','docs\GroupInventory-Guide.md','docs\GroupInventory-Guide.html','templates\GroupInventory.template.html','engine\GroupInventory.Engine.csproj','config\M365GroupsReporting.config.psd1') {
                $target=Join-Path $folder $relative;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $target));Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $target
            }
            Copy-Item -LiteralPath (Join-Path $root 'engine\bin') -Destination (Join-Path $folder 'engine') -Recurse
            $config=Join-Path $folder 'config\M365GroupsReporting.config.psd1'
            $text=[IO.File]::ReadAllText($config).Replace("TenantId       = ''","TenantId       = '11111111-1111-1111-1111-111111111111'").Replace("Organization   = ''","Organization   = 'synthetic.onmicrosoft.com'").Replace("CompanyName        = ''","CompanyName        = 'Synthetic Private Company'").Replace("EnvironmentName    = ''","EnvironmentName    = 'Synthetic Private Environment'").Replace('ShowTenantInformation = $false','ShowTenantInformation = $true')
            [IO.File]::WriteAllText($config,$text)
            $folder
        }
    }
    It 'uses the actual Purview tool-root path semantics and complete authoritative report defaults' {
        $config=Import-M365GroupsConfiguration -Path (Join-Path $root 'config\M365GroupsReporting.config.psd1') -Root $TestDrive
        Check ($config.Storage.DatabasePath -eq (Join-Path $TestDrive 'data\M365GroupsReporting.sqlite')) 'DatabasePath must resolve from the tool root'
        Check ($config.Logging.Path -eq (Join-Path $TestDrive 'logs')) 'Logging.Path'
        Check ($config.Report.OutputPath -eq (Join-Path $TestDrive 'reports')) 'Report.OutputPath'
        Check (($config.Report.Formats -join ',') -eq 'CSV,HTML') 'Formats'
        Check ($config.Report.FilePrefix -eq 'M365GroupsReporting' -and $config.Report.CsvDelimiter -eq ';') 'Product prefix and delimiter'
        Check (-not $config.Report.ShowTenantInformation) 'Tenant display is opt-in'
        Check ($config.Authentication.Mode -eq 'ClientSecretFile') 'Existing external lab credential path retained explicitly'
        $invalid=Join-Path $TestDrive 'invalid-config.psd1'
        $text=[IO.File]::ReadAllText((Join-Path $root 'config\M365GroupsReporting.config.psd1'))
        [IO.File]::WriteAllText($invalid,$text.Replace("CsvDelimiter       = ';'","CsvDelimiter       = 'invalid'"))
        Reject { Import-M365GroupsConfiguration -Path $invalid -Root $TestDrive } 'CsvDelimiter'
        [IO.File]::WriteAllText($invalid,$text.Replace("TimeZone           = 'Europe/Paris'","TimeZone           = 'Not/AZone'"))
        Reject { Import-M365GroupsConfiguration -Path $invalid -Root $TestDrive } 'time zone|fuseau|Not/AZone'
        [IO.File]::WriteAllText($invalid,$text.Replace("AppId = ''","AppId = ''; 'ClientSecret' = 'synthetic-secret-not-real'"))
        Reject { Import-M365GroupsConfiguration -Path $invalid -Root $TestDrive } 'Secrets are forbidden'
    }
    It 'retains latest/incomplete/active snapshots and removes only older validated sealed snapshots' {
        $base=Join-Path $TestDrive 'parity-retention';[void][IO.Directory]::CreateDirectory($base)
        $older=New-Snapshot $base 'run_older' 500
        $latest=New-Snapshot $base 'run_latest' 400
        $incomplete=New-Snapshot $base 'run_incomplete' 600 -Incomplete
        Set-Content -LiteralPath (Join-Path $incomplete '_inv_sites.csv') -Value 'intermediate,not-a-final'
        $active=New-Snapshot $base 'run_active' 700
        $handle=[IO.FileStream]::new((Join-Path $active 'M365GroupsReporting.sqlite.lock'),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {
            Invoke-M365GroupsRetention -Root $base -StorageRetentionDays 180 -LogRetentionDays 0 -KeepIncompleteRuns $true
            Check (-not (Test-Path $older)) 'Older seal removed'
            Check ((Test-Path $latest) -and (Test-Path $incomplete) -and (Test-Path $active)) 'Latest/incomplete/active preserved'
        } finally { $handle.Dispose() }
        Invoke-M365GroupsRetention -Root $base -StorageRetentionDays 1 -LogRetentionDays 0 -KeepIncompleteRuns $true -ExcludeRunDir (Join-Path $active 'M365GroupsReporting.sqlite')
        Check (Test-Path $active) 'Resume database-file exclusion normalized'
    }
    It 'log retention uses file age independently and preserves locked logs and incomplete-run logs' {
        $base=Join-Path $TestDrive 'parity-logs';[void][IO.Directory]::CreateDirectory($base)
        $old=Join-Path $base 'old.log';$fresh=Join-Path $base 'fresh.log';$locked=Join-Path $base 'locked.log'
        foreach($file in $old,$fresh,$locked){Set-Content -LiteralPath $file -Value 'synthetic'}
        (Get-Item $old).LastWriteTime=(Get-Date).AddDays(-60);(Get-Item $locked).LastWriteTime=(Get-Date).AddDays(-60)
        $incomplete=Join-Path $base 'run_incomplete';[void][IO.Directory]::CreateDirectory($incomplete)
        $kept=Join-Path $incomplete 'run.log';Set-Content -LiteralPath $kept -Value 'synthetic';(Get-Item $kept).LastWriteTime=(Get-Date).AddDays(-60)
        $handle=[IO.FileStream]::new($locked,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {
            Invoke-M365GroupsLogRetention -Root $base -RetentionDays 30 -ProtectedRunNames 'run_incomplete'
            Check (-not (Test-Path $old)) 'Old log removed'
            Check ((Test-Path $fresh) -and (Test-Path $locked) -and (Test-Path $kept)) 'Fresh/locked/incomplete logs preserved'
        } finally {$handle.Dispose()}
        Invoke-M365GroupsLogRetention -Root $base -RetentionDays 0
        Check (Test-Path $locked) 'Zero disables log retention'
    }
    It 'help examples, canonical layout and generated HTML guide match the runtime contract' {
        $help=Get-Help (Join-Path $root 'Invoke-M365GroupsReporting.ps1') -Full
        foreach($name in 'ConfigPath','DatabasePath','OutputPath','LogPath','AuthMode','CertificateThumbprint','Format','ResumeRun','NoRetention') {
            Check ($help.parameters.parameter.name -contains $name) "Help for $name"
        }
        Check ($help.examples.example.Count -ge 3) 'Runnable examples'
        foreach($path in 'src\GroupInventory.Engine.Export.cs','tests\GroupInventory.Engine.Tests.ps1','docs\GroupInventory-Guide.html','THIRD-PARTY-NOTICES.md') { Check (Test-Path (Join-Path $root $path)) "Required file $path" }
        $guide=[IO.File]::ReadAllText((Join-Path $root 'docs\GroupInventory-Guide.html'))
        Check ($guide.Contains('class="hero"') -and $guide.Contains('data-target=') -and $guide.Contains('class="copy"')) 'Actual Purview guide renderer components'
        Check ($guide.Contains('ClientSecretEnvironment') -and $guide.Contains('Accepted domain difference')) 'Explicit domain exceptions documented'
        $source=[IO.File]::ReadAllText((Join-Path $root 'Invoke-M365GroupsReporting.ps1'))
        Check ($source.LastIndexOf('Invoke-M365GroupsRetention -Root') -gt $source.LastIndexOf('Stop-Transcript')) 'Retention follows close/log lifecycle'
    }
    It 'matches full Purview theme variables and summary/distribution/ranking/filter/dialog components' {
        $html=[IO.File]::ReadAllText((Join-Path $root 'templates\GroupInventory.template.html'))
        foreach($var in 'bg','bg-elevated','surface','surface-soft','border','border-strong','text','text-muted','text-soft','accent','accent-hover','accent-soft','accent-fg','success','danger','warning','link','shadow','overlay','highlight') {
            Check ([regex]::Matches($html,"--cp-$var\s*:").Count -eq 2) "Light/dark variable --cp-$var"
        }
        foreach($component in 'distribution','ranking-list','overview-scope','filters','viewport','loading','details','focus-visible','dictionaryMask','Uint8Array','relationValues') { Check ($html.Contains($component)) "HTML component $component" }
    }
    It 'sealed entry-point runs honor config report/log paths, formats, prefix and CLI overrides without credentials' {
        $base=Join-Path $TestDrive 'entrypoint';[void][IO.Directory]::CreateDirectory($base)
        $snapshot=New-Snapshot $base 'run_entrypoint' 0
        $configPath=Join-Path $base 'config.psd1'
        $reportRoot=Join-Path $base 'configured-reports';$logRoot=Join-Path $base 'configured-logs'
        $text=[IO.File]::ReadAllText((Join-Path $root 'config\M365GroupsReporting.config.psd1')).Replace("OutputPath         = '.\reports'","OutputPath         = '$reportRoot'").Replace("Path = '.\logs'","Path = '$logRoot'").Replace("FilePrefix         = 'M365GroupsReporting'","FilePrefix         = 'ConfiguredPrefix'")
        [IO.File]::WriteAllText($configPath,$text)
        & (Get-Command pwsh).Source -NoProfile -File (Join-Path $root 'Invoke-M365GroupsReporting.ps1') -ConfigPath $configPath -ResumeRun $snapshot -NoRetention *> (Join-Path $base 'execution.txt')
        Check ($LASTEXITCODE -eq 0) ("Sealed re-export succeeds without credentials: " + [IO.File]::ReadAllText((Join-Path $base 'execution.txt')))
        Check ((Test-Path (Join-Path $reportRoot 'run_entrypoint\ConfiguredPrefix.csv')) -and (Test-Path (Join-Path $reportRoot 'run_entrypoint\ConfiguredPrefix.html'))) 'Config paths/formats/prefix applied'
        $logs=@(Get-ChildItem (Join-Path $logRoot 'run_entrypoint') -Filter '*.log')
        Check ($logs.Count -gt 0 -and ([IO.File]::ReadAllText($logs[0].FullName).Contains('execution completed'))) 'Configured log lifecycle'
        $override=Join-Path $base 'override-reports'
        & (Get-Command pwsh).Source -NoProfile -File (Join-Path $root 'Invoke-M365GroupsReporting.ps1') -ConfigPath $configPath -ResumeRun $snapshot -Format CSV -OutName OverridePrefix -OutputPath $override -ClientSecret 'synthetic-only-not-a-credential' -NoRetention *> (Join-Path $base 'override.txt')
        Check ($LASTEXITCODE -eq 0) 'Legacy CLI secret guard does not prevent sealed export'
        Check ((Test-Path (Join-Path $override 'run_entrypoint\OverridePrefix.csv')) -and -not (Test-Path (Join-Path $override 'run_entrypoint\OverridePrefix.html'))) 'CLI overrides authoritative config defaults'
        $logText=(@(Get-ChildItem (Join-Path $logRoot 'run_entrypoint') -Filter '*.log' | ForEach-Object {[IO.File]::ReadAllText($_.FullName)})) -join "`n"
        Check (-not $logText.Contains('synthetic-only-not-a-credential') -and $logText.Contains('Transcript disabled')) 'Legacy parameter never recorded in owned log'
    }
    It 'suppresses token-endpoint error details and signs short-lived certificate assertions offline' {
        Mock Invoke-RestMethod { throw 'synthetic response containing synthetic-secret-value' }
        Reject { Get-GraphAppToken -Creds @{TenantId='11111111-1111-1111-1111-111111111111';ClientId='22222222-2222-2222-2222-222222222222';ClientSecret='synthetic-secret-value'} } '^Graph authentication failed'
        $rsa=[Security.Cryptography.RSA]::Create(2048)
        $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Synthetic parity test',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $script:syntheticCertificate=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1),[DateTimeOffset]::UtcNow.AddHours(1))
        $script:assertionBody=$null
        Mock Get-Item { $script:syntheticCertificate } -ParameterFilter { $LiteralPath -like 'Cert:*' }
        Mock Invoke-RestMethod { $script:assertionBody=$Body;[pscustomobject]@{access_token='synthetic-token';expires_in=3600} }
        try {
            $token=Get-GraphAppToken -Creds @{TenantId='11111111-1111-1111-1111-111111111111';ClientId='22222222-2222-2222-2222-222222222222';Mode='Certificate';CertificateThumbprint=$script:syntheticCertificate.Thumbprint}
            Check ($token.Token -eq 'synthetic-token') 'Certificate mode token response'
            Check (-not $script:assertionBody.ContainsKey('client_secret')) 'No secret in certificate request'
            $jwt=$script:assertionBody.client_assertion -split '\.'
            Check ($jwt.Count -eq 3) 'Signed JWT assertion'
            $payload=$jwt[1].Replace('-','+').Replace('_','/');$payload=$payload.PadRight([int]([Math]::Ceiling($payload.Length/4)*4),'=')
            $claims=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
            Check ($claims.exp-$claims.nbf -eq 360 -and $claims.iss -eq $claims.sub) 'Five-minute expiry plus bounded clock skew'
        } finally { $script:syntheticCertificate.Dispose();$rsa.Dispose() }
    }
    It 'offline reports reject cross-tenant attribution and label unbound legacy tenant display honestly' {
        $base=Join-Path $TestDrive 'tenant-report';[void][IO.Directory]::CreateDirectory($base)
        $options=New-Object GroupInventory.Engine.EngineOptions -Property @{DatabasePath=(Join-Path $base 'bound.sqlite');RunId='bound';SitesRequired=$false}
        $engine=[GroupInventory.Engine.InventoryEngine]::Create($options)
        try {
            [void]$engine.BindAuthenticatedTenant('11111111-1111-1111-1111-111111111111')
            [void]$engine.CompleteFlow('enum',0);[void]$engine.Seal()
            Reject {Export-InventoryReports -Engine $engine -RunDir $base -OutName refused -Format CSV -TenantSettings @{TenantId='22222222-2222-2222-2222-222222222222'}} 'another authenticated tenant'
            Check (-not (Test-Path (Join-Path $base 'refused.csv'))) 'Cross-tenant report never published'
            $settings=(Import-M365GroupsConfiguration -Path (Join-Path $root 'config\M365GroupsReporting.config.psd1') -Root $TestDrive).Report
            $settings.ShowTenantInformation=$true
            Export-InventoryReports -Engine $engine -RunDir $base -OutName bound -Format HTML -ReportSettings $settings -TenantSettings @{TenantId='11111111-1111-1111-1111-111111111111';Organization='example.test'} | Out-Null
            $html=[IO.File]::ReadAllText((Join-Path $base 'bound.html'))
            Check ($html.Contains('"tenantIdentitySource":"Authenticated collection tenant"')) 'Verified provenance displayed'
        } finally {$engine.Dispose()}
        $snapshot=New-Snapshot $TestDrive 'run_unbound_tenant' 0
        $options.DatabasePath=Join-Path $snapshot 'M365GroupsReporting.sqlite'
        $engine=[GroupInventory.Engine.InventoryEngine]::OpenSealed($options)
        try {
            Export-InventoryReports -Engine $engine -RunDir $base -OutName legacy -Format HTML -ReportSettings $settings -TenantSettings @{TenantId='11111111-1111-1111-1111-111111111111';Organization='example.test'} | Out-Null
            Check ([IO.File]::ReadAllText((Join-Path $base 'legacy.html')).Contains('Configuration only (unverified snapshot)')) 'Legacy snapshots are not falsely attributed'
        } finally {$engine.Dispose()}
    }
    It 'sanitizes package configuration, includes runtime/guide/notices and never ships bin or data' {
        $source=New-PackageSource 'package-source'
        $destination=Join-Path $TestDrive 'package-result'
        & (Join-Path $root 'tools\New-GroupInventoryPackage.ps1') -SourceRoot $source -Destination $destination | Out-Null
        $config=Import-PowerShellDataFile -LiteralPath (Join-Path $destination 'config\M365GroupsReporting.config.psd1')
        Check (-not $config.Tenant.TenantId -and -not $config.Tenant.Organization -and -not $config.Report.CompanyName -and -not $config.Report.EnvironmentName) 'Private config sanitized'
        Check (-not $config.Report.ShowTenantInformation) 'Tenant display reset'
        Check ((Test-Path (Join-Path $destination 'lib\engine\GroupInventory.Engine.dll')) -and (Test-Path (Join-Path $destination 'docs\GroupInventory-Guide.html'))) 'Runnable packaged engine and HTML guide'
        Check (@(Get-ChildItem $destination -Recurse -Directory | Where-Object Name -in 'data','reports','logs','bin').Count -eq 0) 'No forbidden directory'
        foreach($file in Get-ChildItem $destination -Recurse -File | Where-Object Extension -in '.ps1','.psd1','.md','.html') { Check (-not ([IO.File]::ReadAllText($file.FullName).Contains('synthetic.onmicrosoft.com'))) 'No tenant values in package' }
        Reject { & (Join-Path $root 'tools\New-GroupInventoryPackage.ps1') -SourceRoot $source -Destination (Join-Path $source 'inside') } 'outside'
        $runtimeSnapshot=New-Snapshot $TestDrive 'run_package_runtime' 0
        & (Get-Command pwsh).Source -NoProfile -File (Join-Path $destination 'Invoke-M365GroupsReporting.ps1') -ResumeRun $runtimeSnapshot -NoRetention *> (Join-Path $TestDrive 'package-runtime.txt')
        Check ($LASTEXITCODE -eq 0) ("Compiled lib\engine package must run: " + [IO.File]::ReadAllText((Join-Path $TestDrive 'package-runtime.txt')))
        $marker=Join-Path $destination '.M365GroupsReporting.executed'
        Check (Test-Path $marker) 'Runtime marks an executed package even with external snapshot storage'
        Reject { & (Join-Path $root 'tools\New-GroupInventoryPackage.ps1') -SourceRoot $source -Destination $destination -Force } 'executed|data'
        Check (Test-Path $marker) 'Executed package left untouched'
    }
    It 'tenant and secret-shaped scans fail atomically without replacing an existing unexecuted package' {
        $source=New-PackageSource 'package-scan-source'
        $destination=Join-Path $TestDrive 'package-scan-result'
        $tool=Join-Path $root 'tools\New-GroupInventoryPackage.ps1'
        & $tool -SourceRoot $source -Destination $destination | Out-Null
        $before=(Get-FileHash (Join-Path $destination 'README.md')).Hash
        Add-Content -LiteralPath (Join-Path $source 'README.md') -Value 'synthetic.onmicrosoft.com'
        Reject { & $tool -SourceRoot $source -Destination $destination -Force } 'tenant|branding'
        Check ((Get-FileHash (Join-Path $destination 'README.md')).Hash -eq $before) 'Failed scan keeps existing package'
        Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination (Join-Path $source 'README.md') -Force
        Add-Content -LiteralPath (Join-Path $source 'README.md') -Value "ClientSecret = 'synthetic-secret-not-a-credential'"
        Reject { & $tool -SourceRoot $source -Destination $destination -Force } 'Secret-shaped'
        Check ((Get-FileHash (Join-Path $destination 'README.md')).Hash -eq $before) 'Secret rejection is atomic'
        Check (@(Get-ChildItem $TestDrive -Force -Directory -Filter '.M365GroupsReporting-stage-*').Count -eq 0) 'No failed staging artifact'
    }
}

# SIG # Begin signature block
# MIIghAYJKoZIhvcNAQcCoIIgdTCCIHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBD38mHhb+pTKBo
# AphFaFf3ZkD0TKKLmTc07mS+WsxAGqCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# wZislcdCZuS6MYISazCCEmcCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDh29m6vDnh
# 4Ieq6k0aHsfLaNu7Hl86GhMMptBohmx15jANBgkqhkiG9w0BAQEFAASCAgBwdV4e
# +GTvFe1/CNXve5D2Y9oV2ZJtog2Oxl+I3CAtT4ayrFewmcKzBccLtjBbRRNtw54S
# 0ebO/idtZk0eT9QQ2APTpmVc5WV09qBtbVj7TYcfftPYT/tCZMKVVlpizzKIYIM/
# HDEKdmTYGYKZfrABENjOUvUmyaWyzr1+VX2NQ6bNRi0H99yyXUXZcNmFoqFacpRc
# da7BBOzsQwvM1+reG94OwyaQsrxclBEEGRytslDF//p1PwaNjpF9HnvmjqnvDLcA
# 3+1VRDMWpwicaTypFjbG9VVkGir5A/VOWB8GAPzRd8u2+bk7BH9ZSbWKnIoCi/+9
# P7Qjk+GevlTb4cFzNMcL4gelPKUGtnNFbZ1ogE5NuzIuPyL88NQrZTyRHZ1uB3z2
# 2UZS00UwkfnG8FRB0y19TfxckG5LRvXvslQ+8Xav1kI8fnt7IHy3sWk7ocWM6+lD
# EpWYIz8GiVnUrJ8sW1VflLC1d/QQKxi6ixKcIwQ2zFRWqEKnCqvfQzLTlg/baww7
# eBqSNpIRqmr53OIY8iGTHnDUSQilIvf8KNvoInICFNxp+7kfIdUrbQqN9AzJlEkV
# iRa0bK9b9pJBEhEHMyyoWCcz+v8CybcIx7GKJpy1u/ChorVJZq2Wt0ShOl6aC58D
# 1r93ANUE/kgoAA/ZoUHEPKGnmrvWJq9msnVfnKGCDygwgg8kBgorBgEEAYI3AwMB
# MYIPFDCCDxAGCSqGSIb3DQEHAqCCDwEwgg79AgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEII96PYa5l3kcRYULzf0AgnnYHOkgfBFPru/3v8TEp+5vAghAha8TEJsh
# kRgPMjAyNjEwMTQxNzI4MDRaMAMCAQECEDWdzaHFTa25Y2NXZgLS8lOgggwAMIIE
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
# VzCCAlMCAQEwgYcwczELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYD
# VQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNv
# bSBUaW1lc3RhbXBpbmcgSXNzdWluZyBSU0EgQ0EgUjECEB9rFmLSLhtsXfHAwaBg
# DjgwCwYJYIZIAWUDBAIBoIIBYTAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MTAxNDE3MjgwNFowKAYJKoZIhvcNAQk0MRswGTAL
# BglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIFnS7sAanC/O
# Ly1+0uQBmRBc7XHGQj33XACffA5SmmmbMIHJBgsqhkiG9w0BCRACLzGBuTCBtjCB
# szCBsAQgVCr5oWqNci5mEUl4iumUwYqaruWmXLNEolSa+Wx5x4swgYswd6R1MHMx
# CzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjER
# MA8GA1UECgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5n
# IElzc3VpbmcgUlNBIENBIFIxAhAfaxZi0i4bbF3xwMGgYA44MAoGCCqGSM49BAMC
# BEYwRAIgC/M4DvXX7H5buOMCrra1+ET2LzIEbCx6w9kayqu+0MsCIFAPcj1SjHJJ
# yFKUWBj0XnlgNNF0aMxEFX8Z7gYuDU4M
# SIG # End signature block
