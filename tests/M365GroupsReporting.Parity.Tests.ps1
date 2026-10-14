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
            foreach($relative in 'Invoke-M365GroupsReporting.ps1','Get-SiteUrls.ps1','README.md','THIRD-PARTY-NOTICES.md','docs\GroupInventory-Guide.md','docs\GroupInventory-Guide.html','templates\GroupInventory.template.html','engine\GroupInventory.Engine.csproj','config\M365GroupsReporting.config.psd1') {
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
