# Offline synthetic tests for Invoke-M365GroupsReporting.ps1 (Pester 5+; the plain assertion helpers also work with 3.4).
# The entry point is never run: only its helper functions are extracted from the script AST and exercised with
# Invoke-RestMethod / Start-Sleep mocked and a REAL engine (engine\bin, built offline by Build-Engine.ps1) writing to
# $TestDrive. No network, credentials or tenant data.
# Run:  Invoke-Pester -Path .\tests\Invoke-M365GroupsReporting.Tests.ps1
# Engine, resume, export and benchmark tests live in GroupInventory.Engine.Tests.ps1.

Describe 'Invoke-M365GroupsReporting Graph collection (fail-closed, engine-backed)' {
    BeforeAll {
        $projectRoot = Split-Path -Parent $PSScriptRoot
        $src = Join-Path $projectRoot 'Invoke-M365GroupsReporting.ps1'
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$parseErrors)
        $wanted = @('Get-HttpErrorInfo','Get-GraphAppToken','Invoke-GraphRequest','Invoke-GraphBatch','Write-GraphListToEngine','Save-GroupInventoryLists','Complete-InventoryRun',
            'Import-GroupInventoryEngine','Open-InventoryRun','New-GraphAuth','Update-GraphAuth','ConvertTo-GroupRecord','Invoke-GroupEnumeration','Invoke-ListCollection',
            'Import-SiteUrlsToEngine','Test-SpoModuleAvailable','Test-SpoPrerequisites','Start-SpoCollection','Wait-SpoCollection','Export-InventoryReports','Invoke-M365GroupsRetention','Invoke-M365GroupsLogRetention','Import-M365GroupsConfiguration','Resolve-M365GroupsPath')
        $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $false)
        foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }

        function Assert-Equal { param($Actual, $Expected, [string]$What)
            if ("$Actual" -ne "$Expected") { throw "Expected [$What] = '$Expected' but got '$Actual'" } }
        function Assert-True { param($Condition, [string]$What)
            if (-not $Condition) { throw "Expected true: $What" } }
        function Assert-Throws { param([scriptblock]$Script, [string]$Pattern)
            $msg = $null
            try { & $Script } catch { $msg = $_.Exception.Message }
            if ($null -eq $msg) { throw "Expected an exception matching '$Pattern' but none was thrown" }
            if ($Pattern -and $msg -notmatch $Pattern) { throw "Exception '$msg' does not match '$Pattern'" } }

        $engineDir = Join-Path $projectRoot 'engine\bin'
        if (-not (Test-Path -LiteralPath (Join-Path $engineDir 'GroupInventory.Engine.dll'))) { & (Join-Path $projectRoot 'Build-Engine.ps1') | Out-Null }
        Import-GroupInventoryEngine -EngineDir $engineDir

        function New-HttpFailure { param([int]$Code, $RetryAfter)
            $ex = New-Object System.Exception "HTTP $Code"
            $headers = @{}
            if ($RetryAfter) { $headers['Retry-After'] = [string]$RetryAfter }
            Add-Member -InputObject $ex -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Code; Headers = $headers })
            $ex }
        function New-Sub { param([string]$Id, [int]$Status, $Value, [string]$NextLink)
            $body = [pscustomobject]@{ value = @($Value) }
            if ($NextLink) { $body | Add-Member -NotePropertyName '@odata.nextLink' -NotePropertyValue $NextLink }
            [pscustomobject]@{ id = $Id; status = $Status; body = $body } }
        function New-Err { param([string]$Id, [int]$Status)
            [pscustomobject]@{ id = $Id; status = $Status; body = [pscustomobject]@{ error = [pscustomobject]@{ code = 'Forbidden'; message = 'synthetic' } } } }
        function New-User { param([string]$Upn) [pscustomobject]@{ id = [guid]::NewGuid().ToString(); userPrincipalName = $Upn; displayName = $Upn } }
        function G { param([int]$n) [guid]::new($n, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0).ToString() }

        $script:Engines = New-Object System.Collections.Generic.List[object]
        function New-RunEngine { param([string]$Name, [int]$Groups = 1, [switch]$SkipMembers, [switch]$NoComplete)
            $dir = Join-Path $TestDrive $Name; New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $o = New-Object GroupInventory.Engine.EngineOptions
            $o.DatabasePath = Join-Path $dir 'inventory.sqlite'; $o.RunId = 'test'; $o.SkipMembers = [bool]$SkipMembers
            $e = [GroupInventory.Engine.InventoryEngine]::Create($o)
            $script:Engines.Add($e)
            if ($Groups -gt 0) {
                $recs = @(1..$Groups | ForEach-Object { $g = New-Object GroupInventory.Engine.GroupRecord; $g.Id = G $_; $g.DisplayName = "Group $_"; $g.Alias = "g$_"; $g.Mail = "g$_@example.test"; $g.Visibility = 'Private'; $g })
                [void]$e.AddGroupPage(0, [GroupInventory.Engine.GroupRecord[]]$recs, '')
                if (-not $NoComplete) { [void]$e.CompleteFlow('enum', $Groups) }
            }
            $e }
        function New-Slice { param([int[]]$Groups = @(1), [bool]$Members = $true)
            @($Groups | ForEach-Object { [pscustomobject]@{ GroupId = (G $_); DisplayName = "Group $_"; NeedOwners = $true; NeedMembers = $Members } }) }

        $script:Handler = $null
        $script:RestCalls = 0
        $script:Sleeps = New-Object System.Collections.Generic.List[double]
        Mock Invoke-RestMethod { $script:RestCalls++; $script:LastAuthHeader = $Headers.Authorization; & $script:Handler $Method $Uri $Body }
        Mock Start-Sleep { $script:Sleeps.Add([double]$Seconds) }
        Mock Get-GraphAppToken { $script:RefreshCalls++; [pscustomobject]@{ Token = 'synthetic-refreshed'; Expires = (Get-Date).AddHours(1) } }
        Mock Write-Host { }
        Mock Write-Progress { }
        $script:RefreshCalls = 0
        $script:NewAuth = { @{ Token = 'synthetic'; Creds = @{ TenantId = 't'; ClientId = 'c'; ClientSecret = 's' }; Expires = (Get-Date).AddHours(1) } }
    }
    BeforeEach {
        $script:RestCalls = 0
        $script:RefreshCalls = 0
        $script:LastAuthHeader = $null
        $script:Sleeps.Clear()
    }
    AfterEach {
        foreach ($e in $script:Engines) { try { $e.Dispose() } catch { } }
        $script:Engines.Clear()
    }

    It 'parses status code and Retry-After from an error record' {
        $err = $null
        try { throw (New-HttpFailure 429 7) } catch { $err = $_ }
        $i = Get-HttpErrorInfo $err
        Assert-Equal $i.Code 429 'code'
        Assert-Equal $i.RetryAfter 7 'retry-after'
    }

    It 'bounds 401 token refreshes and then throws' {
        $script:Handler = { throw (New-HttpFailure 401) }
        $auth = & $script:NewAuth
        Assert-Throws { Invoke-GraphRequest -Method GET -Uri 'https://graph.test/x' -Auth $auth -MaxRetry 5 -MaxAuthRefresh 2 } 'HTTP 401'
        Assert-Equal $script:RestCalls 3 'initial call + 2 refreshed retries'
        Assert-Equal $auth.Token 'synthetic-refreshed' 'token was refreshed'
    }

    It 'retries 429 with Retry-After then succeeds' {
        $script:Handler = { if ($script:RestCalls -lt 3) { throw (New-HttpFailure 429 4) } else { [pscustomobject]@{ ok = $true } } }
        $r = Invoke-GraphRequest -Method GET -Uri 'https://graph.test/x' -Auth (& $script:NewAuth) -MaxRetry 5
        Assert-True $r.ok 'result returned'
        Assert-Equal $script:RestCalls 3 'calls'
        Assert-Equal $script:Sleeps.Count 2 'sleeps'
        Assert-Equal $script:Sleeps[0] 4 'honours Retry-After'
    }

    It 'stops after MaxRetry attempts on persistent 5xx' {
        $script:Handler = { throw (New-HttpFailure 503) }
        Assert-Throws { Invoke-GraphRequest -Method GET -Uri 'https://graph.test/x' -Auth (& $script:NewAuth) -MaxRetry 3 } 'HTTP 503'
        Assert-Equal $script:RestCalls 3 'calls'
    }

    It 'does not retry other client errors' {
        $script:Handler = { throw (New-HttpFailure 400) }
        Assert-Throws { Invoke-GraphRequest -Method GET -Uri 'https://graph.test/x' -Auth (& $script:NewAuth) -MaxRetry 5 } 'HTTP 400'
        Assert-Equal $script:RestCalls 1 'calls'
        Assert-Equal $script:Sleeps.Count 0 'sleeps'
    }

    It 'benign success: owners and members are read into the engine, counts match, nothing fails' {
        $e = New-RunEngine 'benign'
        $script:Handler = {
            $req = ($Body | ConvertFrom-Json).requests
            [pscustomobject]@{ responses = @($req | ForEach-Object {
                if ($_.id -like '*|own') { New-Sub $_.id 200 @((New-User 'owner@example.test')) }
                else { New-Sub $_.id 200 @((New-User 'a@example.test'), (New-User 'b@example.test')) }
            }) }
        }
        $s = Save-GroupInventoryLists -Slice (New-Slice) -Engine $e -Auth (& $script:NewAuth)
        Assert-Equal $s.ListsOk 2 'lists written'; Assert-Equal $s.ListsFailed 0 'lists failed'
        $r = $e.Reconcile()
        Assert-Equal $r.ListsComplete 2 'complete lists'; Assert-Equal $r.OwnerEntries 1 'owners'; Assert-Equal $r.MemberEntries 2 'members'
        Assert-Equal $r.VerifiedEmptyOwners 0 'not ownerless'; Assert-Equal @($e.GetFailures(10)).Count 0 'failures'
    }

    It 'a genuinely empty owners list is a verified zero (ownerless)' {
        $e = New-RunEngine 'ownerless'
        $script:Handler = {
            $req = ($Body | ConvertFrom-Json).requests
            [pscustomobject]@{ responses = @($req | ForEach-Object { New-Sub $_.id 200 @() }) }
        }
        [void](Save-GroupInventoryLists -Slice (New-Slice) -Engine $e -Auth (& $script:NewAuth))
        $r = $e.Reconcile()
        Assert-Equal $r.ListsComplete 2 'complete lists'; Assert-Equal $r.VerifiedEmptyOwners 1 'verified-empty owners'; Assert-Equal $r.Ownerless 1 'ownerless'
    }

    It 'owners 403 is a failed list, not an empty/zero owners list' {
        $e = New-RunEngine 'owners403'
        $script:Handler = {
            $req = ($Body | ConvertFrom-Json).requests
            [pscustomobject]@{ responses = @($req | ForEach-Object {
                if ($_.id -like '*|own') { New-Err $_.id 403 } else { New-Sub $_.id 200 @((New-User 'a@example.test')) }
            }) }
        }
        $s = Save-GroupInventoryLists -Slice (New-Slice) -Engine $e -Auth (& $script:NewAuth)
        Assert-Equal $s.ListsFailed 1 'one failed list'; Assert-Equal $s.ListsOk 1 'members still read'
        $r = $e.Reconcile()
        Assert-Equal $r.ListsFailed 1 'failed owners list'; Assert-Equal $r.VerifiedEmptyOwners 0 'no zero owners invented'; Assert-Equal $r.MemberEntries 1 'members stored'
        $f = @($e.GetFailures(10))
        Assert-Equal $f.Count 1 'failure count'; Assert-Equal $f[0].Request 'owners' 'request'; Assert-Equal $f[0].Status 403 'status'
        Assert-Equal $r.IsComplete $false 'run cannot reconcile'
    }

    It 'a sub-request missing from the batch answer is a failed list' {
        $e = New-RunEngine 'missing'
        $script:Handler = {
            $req = ($Body | ConvertFrom-Json).requests
            [pscustomobject]@{ responses = @($req | Where-Object { $_.id -like '*|own' } | ForEach-Object { New-Sub $_.id 200 @((New-User 'o@example.test')) }) }
        }
        [void](Save-GroupInventoryLists -Slice (New-Slice) -Engine $e -Auth (& $script:NewAuth) -MaxRetry 2)
        $f = @($e.GetFailures(10))
        Assert-Equal $f.Count 1 'one failure'; Assert-Equal $f[0].Request 'members' 'request'
        Assert-Equal $e.Reconcile().MemberEntries 0 'no members assumed'
    }

    It 'persistent 429 on a sub-request ends as a failure after bounded retries' {
        $e = New-RunEngine 'p429'
        $script:Handler = {
            $req = ($Body | ConvertFrom-Json).requests
            [pscustomobject]@{ responses = @($req | ForEach-Object {
                if ($_.id -like '*|mem') { New-Err $_.id 429 } else { New-Sub $_.id 200 @((New-User 'o@example.test')) }
            }) }
        }
        [void](Save-GroupInventoryLists -Slice (New-Slice) -Engine $e -Auth (& $script:NewAuth) -MaxRetry 3)
        $f = @($e.GetFailures(10))
        Assert-Equal $f[0].Request 'members' 'request'; Assert-Equal $f[0].Status 429 'status'
        Assert-Equal $script:RestCalls 3 'batch attempts are bounded'
    }

    It 'a pagination failure fails the list instead of storing a short list' {
        $e = New-RunEngine 'pagefail'
        $script:Handler = {
            if ($Method -eq 'POST') {
                $req = ($Body | ConvertFrom-Json).requests
                [pscustomobject]@{ responses = @($req | ForEach-Object {
                    if ($_.id -like '*|own') { New-Sub $_.id 200 @((New-User 'o@example.test')) -NextLink 'https://graph.test/page2' }
                    else { New-Sub $_.id 200 @((New-User 'a@example.test')) }
                }) }
            } else { throw (New-HttpFailure 500) }
        }
        [void](Save-GroupInventoryLists -Slice (New-Slice) -Engine $e -Auth (& $script:NewAuth) -MaxRetry 2)
        $r = $e.Reconcile()
        Assert-Equal $r.ListsFailed 1 'owners list failed'; Assert-Equal $r.OwnerEntries 0 'the partial first page was discarded'
        Assert-True (-not ($r.Problems -match 'still hold entries')) 'no stray entries'
        Assert-Equal @($e.GetFailures(10))[0].Request 'owners' 'request'
    }

    It 'follows a successful second page' {
        $e = New-RunEngine 'page2'
        $script:Handler = {
            if ($Method -eq 'POST') {
                $req = ($Body | ConvertFrom-Json).requests
                [pscustomobject]@{ responses = @($req | ForEach-Object {
                    if ($_.id -like '*|own') { New-Sub $_.id 200 @((New-User 'o1@example.test')) -NextLink 'https://graph.test/page2' }
                    else { New-Sub $_.id 200 @() }
                }) }
            } else { (New-Sub 'x' 200 @((New-User 'o2@example.test'))).body }
        }
        [void](Save-GroupInventoryLists -Slice (New-Slice) -Engine $e -Auth (& $script:NewAuth))
        $r = $e.Reconcile()
        Assert-Equal $r.ListsComplete 2 'complete'; Assert-Equal $r.OwnerEntries 2 'owners from both pages'
    }

    It 'a failing batch transport fails every list (no silent empty rows)' {
        $e = New-RunEngine 'transport'
        $script:Handler = { throw (New-HttpFailure 500) }
        $s = Save-GroupInventoryLists -Slice (New-Slice) -Engine $e -Auth (& $script:NewAuth) -MaxRetry 2
        Assert-Equal $s.ListsFailed 2 'owners + members'
        $r = $e.Reconcile()
        Assert-Equal $r.ListsFailed 2 'both failed'; Assert-Equal ($r.OwnerEntries + $r.MemberEntries) 0 'nothing stored'
    }

    It '-SkipMembers requests no members and the engine does not collect them' {
        $e = New-RunEngine 'skip' -SkipMembers
        $script:SeenIds = @()
        $script:Handler = {
            $req = ($Body | ConvertFrom-Json).requests
            $script:SeenIds = @($req | ForEach-Object { $_.id })
            [pscustomobject]@{ responses = @($req | ForEach-Object { New-Sub $_.id 200 @((New-User 'o@example.test')) }) }
        }
        $s = Save-GroupInventoryLists -Slice (New-Slice) -Engine $e -Auth (& $script:NewAuth) -SkipMembers $true
        Assert-Equal @($script:SeenIds).Count 1 'only the owners request is sent'
        Assert-Equal $s.ListsOk 1 'owners written'
        $r = $e.Reconcile()
        Assert-Equal $r.ListsSkipped 1 'members not collected'; Assert-Equal $r.OwnerEntries 1 'owners'; Assert-Equal @($e.GetFailures(10)).Count 0 'no failure'
    }

    It 'a sub-response 401 refreshes the token once and retries only the affected request' {
        $e = New-RunEngine 'refresh401'
        $script:Batches = New-Object System.Collections.Generic.List[object]
        $script:Handler = {
            $req = @(($Body | ConvertFrom-Json).requests)
            $script:Batches.Add(@($req | ForEach-Object { $_.id }))
            [pscustomobject]@{ responses = @($req | ForEach-Object {
                if ($_.id -like '*|own' -and $script:RefreshCalls -eq 0) { New-Err $_.id 401 }
                else { New-Sub $_.id 200 @((New-User 'u@example.test')) }
            }) }
        }
        [void](Save-GroupInventoryLists -Slice (New-Slice) -Engine $e -Auth (& $script:NewAuth))
        $r = $e.Reconcile()
        Assert-Equal $r.ListsComplete 2 'complete'; Assert-Equal $r.OwnerEntries 1 'ownersCount'
        Assert-Equal $script:RefreshCalls 1 'token refreshed once'
        Assert-Equal $script:Batches.Count 2 'batch calls'
        Assert-Equal @($script:Batches[1]).Count 1 'only the 401 request is retried'
        Assert-Equal @($script:Batches[1])[0] ((G 1) + '|own') 'retried id'
        Assert-Equal $script:LastAuthHeader 'Bearer synthetic-refreshed' 'retry uses the refreshed token'
    }

    It 'a persistent sub-response 401 is bounded and ends as a failure' {
        $e = New-RunEngine 'persist401'
        $script:Handler = {
            $req = @(($Body | ConvertFrom-Json).requests)
            [pscustomobject]@{ responses = @($req | ForEach-Object {
                if ($_.id -like '*|own') { New-Err $_.id 401 } else { New-Sub $_.id 200 @((New-User 'u@example.test')) }
            }) }
        }
        [void](Save-GroupInventoryLists -Slice (New-Slice) -Engine $e -Auth (& $script:NewAuth))
        $r = $e.Reconcile()
        Assert-Equal $r.ListsFailed 1 'owners failed'; Assert-Equal $r.VerifiedEmptyOwners 0 'no zero owners invented'
        Assert-Equal @($e.GetFailures(10))[0].Status 401 'status'
        Assert-Equal $script:RefreshCalls 2 'refreshes are bounded'
        Assert-Equal $script:RestCalls 3 'batch calls are bounded'
        Assert-Equal $r.MemberEntries 1 'members unaffected'
    }

    It 'removes a group only after a list 404 is confirmed by a group re-check' {
        $e = New-RunEngine 'deleted-group'
        $script:Handler = {
            if ($Method -eq 'GET' -and $Uri -match '/groups/') { throw (New-HttpFailure 404) }
            $req = @(($Body | ConvertFrom-Json).requests)
            [pscustomobject]@{ responses = @($req | ForEach-Object {
                if ($_.id -like '*|own') { New-Err $_.id 404 }
                else { New-Sub $_.id 200 @((New-User 'member@example.test')) }
            }) }
        }
        $result = Save-GroupInventoryLists -Slice (New-Slice) -Engine $e -Auth (& $script:NewAuth)
        Assert-Equal $result.GroupsRemoved 1 'removed group'
        Assert-Equal $e.Info().Groups 0 'group removed from active inventory'
        Assert-Equal $e.Reconcile().GroupsRemoved 1 'removal recorded'
    }

    # ------------------------------------------------------------------ formats: CSV and HTML only
    It 'JSON and JSONL are gone: -Format accepts CSV and HTML only, the old JSON parameters no longer exist' {
        $params = $ast.ParamBlock.Parameters
        $fmt = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Format' }
        $set = $fmt.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        Assert-Equal (($set.PositionalArguments | ForEach-Object { $_.Value }) -join ',') 'CSV,HTML' 'Format values'
        $names = @($params | ForEach-Object { $_.Name.VariablePath.UserPath })
        Assert-True ($names -notcontains 'JsonArrayMax') 'no JsonArrayMax'
        Assert-True ($names -notcontains 'HtmlMax') 'no HtmlMax'
        Assert-Throws { & $src -Format JSON -SiteUrlsCsv x } 'JSON'
        Assert-Throws { & $src -Format JSONL -SiteUrlsCsv x } 'JSONL'
        Assert-Throws { & $src -JsonArrayMax 5 -SiteUrlsCsv x } 'JsonArrayMax'
        $text = [System.IO.File]::ReadAllText($src)
        Assert-True ($text -notmatch 'function ConvertTo-(InventoryJsonArray|JsonObj)') 'no JSON export helper left'
        Assert-True ($text -notmatch "(?m)^\s*'JSON'\s*\{") 'no JSON export branch'
    }

    # ------------------------------------------------------------------ gate, workers, enumeration, resume, sites, SharePoint prerequisites
    It 'Complete-InventoryRun seals a complete run; otherwise it throws INCOMPLETE and writes the errors file' {
        $csv = Join-Path $TestDrive 'errors.csv'
        $ok = New-RunEngine 'gate-ok'
        $script:Handler = { $req = ($Body | ConvertFrom-Json).requests; [pscustomobject]@{ responses = @($req | ForEach-Object { New-Sub $_.id 200 @((New-User 'u@example.test')) }) } }
        [void](Save-GroupInventoryLists -Slice (New-Slice) -Engine $ok -Auth (& $script:NewAuth))
        [void]$ok.AddSitePage(0, [string[]]@(), [string[]]@(), ''); [void]$ok.CompleteFlow('sites', 0)
        Set-Content -LiteralPath $csv -Value 'stale failure report'
        Assert-True (Complete-InventoryRun -Engine $ok -ErrorsCsv $csv).IsSealed 'sealed'
        Assert-True (-not (Test-Path $csv)) 'stale errors file removed when clean'
        $bad = New-RunEngine 'gate-bad' -Groups 2
        [void]$bad.FailList((G 1), 1, 403, 'HTTP 403')
        Assert-Throws { Complete-InventoryRun -Engine $bad -ErrorsCsv $csv } 'INCOMPLETE'
        Assert-True (Test-Path $csv) 'errors CSV written'
        Assert-True (@(Import-Csv $csv | Where-Object { $_.Request -eq 'owners' -and $_.Status -eq '403' }).Count -eq 1) 'owners 403 listed'
        Assert-Equal $bad.Info().State 'collecting' 'not sealed'
    }

    Context 'mocks scoped to this block (Pester 3 keeps an It-level mock until its parent ends)' {
        It 'a worker crash fails only the unfinished lists of its slice (never an empty list)' {
            $e = New-RunEngine 'crashworker' -Groups 2
            Mock Save-GroupInventoryLists { throw 'boom' }
            $r = Invoke-ListCollection -Engine $e -Auth (& $script:NewAuth) -Sequential
            Assert-Equal $r.WorkerErrors 1 'worker error counted'
            $i = $e.Info()
            Assert-Equal $i.ListsFailed 4 'every unfinished list of the slice failed'
            Assert-True (@($e.GetFailures(10) | Where-Object { $_.Message -match 'Worker failed: boom' }).Count -eq 4) 'reported'
        }    }


    It 'selective resume: a second collection only requests the lists that are still incomplete' {
        $e = New-RunEngine 'selective' -Groups 3
        $script:Handler = {
            $req = ($Body | ConvertFrom-Json).requests
            [pscustomobject]@{ responses = @($req | ForEach-Object {
                if ($_.id -like ((G 2) + '|own') -and $script:FailOwners) { New-Err $_.id 403 } else { New-Sub $_.id 200 @((New-User 'u@example.test')) }
            }) }
        }
        $script:FailOwners = $true
        $r1 = Invoke-ListCollection -Engine $e -Auth (& $script:NewAuth) -Sequential
        Assert-Equal $r1.Failed 1 'one list failed'; Assert-Equal $r1.Ok 5 'five lists written'
        $script:BatchIds = New-Object System.Collections.Generic.List[string]
        $script:Handler = {
            $req = ($Body | ConvertFrom-Json).requests
            foreach ($q in $req) { $script:BatchIds.Add($q.id) }
            [pscustomobject]@{ responses = @($req | ForEach-Object { New-Sub $_.id 200 @((New-User 'u@example.test')) }) }
        }
        $r2 = Invoke-ListCollection -Engine $e -Auth (& $script:NewAuth) -Sequential
        Assert-Equal ($script:BatchIds -join ',') ((G 2) + '|own') 'only the failed list is requested'
        Assert-Equal $r2.Ok 1 'recollected'; Assert-Equal $r2.Failed 0 'no failure'
        Assert-Equal $e.Reconcile().ListsComplete 6 'all lists complete'
        $r3 = Invoke-ListCollection -Engine $e -Auth (& $script:NewAuth) -Sequential
        Assert-Equal $r3.Groups 0 'nothing left to do'
    }

    It 'enumeration: pages are committed with a cursor checkpoint, types come from resourceProvisioningOptions' {
        $e = New-RunEngine 'enum' -Groups 0
        $script:mk = { param($n, $team) [pscustomobject]@{ id = (G $n); displayName = "Group $n"; mailNickname = "g$n"; mail = "g$n@example.test"; visibility = 'Public'; resourceProvisioningOptions = $(if ($team) { @('Team') } else { @() }) } }
        $script:Uris = New-Object System.Collections.Generic.List[string]
        $script:Handler = {
            $script:Uris.Add($Uri)
            if ($Uri -like '*page=2') { [pscustomobject]@{ value = @(& $script:mk 3 $false) } }
            else { [pscustomobject]@{ value = @((& $script:mk 1 $false), (& $script:mk 2 $true)); '@odata.nextLink' = 'https://graph.test/groups?page=2' } }
        }
        $n = Invoke-GroupEnumeration -Engine $e -Auth (& $script:NewAuth)
        Assert-Equal $n 3 'groups'
        Assert-Equal $e.GetFlow('enum').State 'Complete' 'flow complete'
        Assert-Equal $e.Info().Groups 3 'stored'
        Assert-Equal $script:Uris.Count 2 'two pages requested'
        Assert-True ($script:Uris[0] -match 'groupTypes/any' -and $script:Uris[0] -match 'top=999') 'Unified filter and page size'
        Assert-Equal (Invoke-GroupEnumeration -Engine $e -Auth (& $script:NewAuth)) 3 'a complete enumeration is skipped'
        Assert-Equal $script:Uris.Count 2 'no new request'
    }

    It 'enumeration: stops at -Max groups; malformed pages fail the run' {
        $e = New-RunEngine 'enummax' -Groups 0
        $script:Handler = { [pscustomobject]@{ value = @(1..5 | ForEach-Object { [pscustomobject]@{ id = (G $_); displayName = "G$_"; mailNickname = "g$_"; mail = ''; visibility = 'Private' } }); '@odata.nextLink' = 'https://graph.test/never' } }
        Assert-Equal (Invoke-GroupEnumeration -Engine $e -Auth (& $script:NewAuth) -Max 3) 3 'capped'
        Assert-Equal $e.Info().Groups 3 'three groups'
        Assert-Equal $script:RestCalls 1 'no page after the cap'
        $e2 = New-RunEngine 'enumbad' -Groups 0
        $script:Handler = { [pscustomobject]@{ nothing = 1 } }
        Assert-Throws { Invoke-GroupEnumeration -Engine $e2 -Auth (& $script:NewAuth) } 'malformed'
        Assert-Equal $e2.GetFlow('enum').State 'Pending' 'nothing committed'
    }

    It 'enumeration resume: continues from the stored cursor, or restarts when Graph rejects it (no duplicates)' {
        $script:mk = { param($n) [pscustomobject]@{ id = (G $n); displayName = "Group $n"; mailNickname = "g$n"; mail = "g$n@example.test"; visibility = 'Public' } }
        # first session: page 2 fails -> the enumeration is interrupted after page 1
        $e = New-RunEngine 'resume-enum' -Groups 0
        $script:Handler = { if ($Uri -like '*page=2') { throw (New-HttpFailure 500) } else { [pscustomobject]@{ value = @((& $script:mk 1), (& $script:mk 2)); '@odata.nextLink' = 'https://graph.test/groups?page=2' } } }
        Assert-Throws { Invoke-GroupEnumeration -Engine $e -Auth (& $script:NewAuth) -MaxRetry 2 } '500'
        Assert-Equal $e.GetFlow('enum').State 'Collecting' 'checkpointed'
        Assert-Equal $e.GetFlow('enum').Cursor 'https://graph.test/groups?page=2' 'cursor stored with the committed page'
        # second session: the cursor works
        $script:Uris = New-Object System.Collections.Generic.List[string]
        $script:Handler = { $script:Uris.Add($Uri); [pscustomobject]@{ value = @((& $script:mk 3)) } }
        Assert-Equal (Invoke-GroupEnumeration -Engine $e -Auth (& $script:NewAuth)) 3 'total'
        Assert-Equal ($script:Uris -join '|') 'https://graph.test/groups?page=2' 'resumed from the cursor, not from page 1'
        # the cursor is rejected: restart from the first page, groups already stored are de-duplicated
        $e2 = New-RunEngine 'resume-enum2' -Groups 0
        $script:Handler = { if ($Uri -like '*page=2') { throw (New-HttpFailure 500) } else { [pscustomobject]@{ value = @((& $script:mk 1), (& $script:mk 2)); '@odata.nextLink' = 'https://graph.test/groups?page=2' } } }
        Assert-Throws { Invoke-GroupEnumeration -Engine $e2 -Auth (& $script:NewAuth) -MaxRetry 2 } '500'
        $script:Handler = {
            if ($Uri -like '*page=2') { throw (New-HttpFailure 400) }
            else { [pscustomobject]@{ value = @((& $script:mk 1), (& $script:mk 2), (& $script:mk 3)) } }
        }
        Assert-Equal (Invoke-GroupEnumeration -Engine $e2 -Auth (& $script:NewAuth)) 3 'restarted total'
        Assert-Equal $e2.Info().Groups 3 'no duplicate group'
        Assert-Equal $e2.GetFlow('enum').Pass 1 'second pass'
    }

    It 'site URLs: streamed in bounded pages, blanks skipped, bad rows fail the flow, a re-run restarts the source' {
        $e = New-RunEngine 'sites' -Groups 3
        $csv = Join-Path $TestDrive 'sites.csv'
        $rows = @("GroupId,Url", "$(G 1),https://example.test/sites/one", "$(G 1),https://example.test/sites/one", ",https://example.test/sites/none", "00000000-0000-0000-0000-000000000000,https://example.test/sites/zero", "$(G 2),https://example.test/sites/two", "$(G 99),https://example.test/sites/orphan")
        [System.IO.File]::WriteAllLines($csv, $rows)
        Assert-Equal (Import-SiteUrlsToEngine -Engine $e -Path $csv -PageSize 2) 4 'rows imported (duplicate counted once by the engine)'
        $f = $e.GetFlow('sites')
        Assert-Equal $f.State 'Complete' 'complete'; Assert-Equal $f.Duplicates 1 'duplicate row'; Assert-Equal $e.Reconcile().SiteOrphans 1 'orphan'
        Assert-Equal (Import-SiteUrlsToEngine -Engine $e -Path $csv) 4 'a complete source is skipped'
        $e2 = New-RunEngine 'sites2' -Groups 1
        $bad = Join-Path $TestDrive 'bad.csv'
        [System.IO.File]::WriteAllLines($bad, @('GroupId,Url', "$(G 1),https://example.test/ok", 'not-a-guid,https://example.test/x'))
        Assert-Throws { Import-SiteUrlsToEngine -Engine $e2 -Path $bad } 'not a GUID'
        Assert-Equal $e2.GetFlow('sites').State 'Failed' 'flow failed'
        [System.IO.File]::WriteAllLines($bad, @('GroupId,Url', "$(G 1),http://example.test/insecure"))
        Assert-Throws { Import-SiteUrlsToEngine -Engine $e2 -Path $bad } 'https'
        [System.IO.File]::WriteAllLines($bad, @('Id,Link', "$(G 1),https://example.test/ok"))
        Assert-Throws { Import-SiteUrlsToEngine -Engine $e2 -Path $bad } 'GroupId and Url'
        [System.IO.File]::WriteAllLines($bad, @('GroupId,Url', "$(G 1),https://example.test/ok"))
        Assert-Equal (Import-SiteUrlsToEngine -Engine $e2 -Path $bad) 1 'a corrected file restarts the flow'
        Assert-Equal $e2.GetFlow('sites').State 'Complete' 'complete after the retry'
        $e3 = New-RunEngine 'sites-empty' -Groups 1
        $empty = Join-Path $TestDrive 'empty-sites.csv'
        [System.IO.File]::WriteAllLines($empty, @('GroupId,Url'))
        Assert-Throws { Import-SiteUrlsToEngine -Engine $e3 -Path $empty } 'no valid GROUP#0 rows'
        Assert-Equal $e3.GetFlow('sites').State 'Failed' 'empty source fails closed'
    }

    Context 'mocks scoped to this block (Pester 3 keeps an It-level mock until its parent ends)' {
        It 'interactive SharePoint path: prerequisites are checked and the run fails clearly when they are missing' -Skip:(-not $IsWindows) {
            Assert-Throws { Test-SpoPrerequisites -SpoAdminUrl '' } 'SiteUrlsCsv'
            Assert-Throws { Test-SpoPrerequisites -SpoAdminUrl 'https://contoso.sharepoint.com' } 'admin'
            Assert-Throws { Test-SpoPrerequisites -SpoAdminUrl 'http://contoso-admin.sharepoint.com' } 'admin'
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'powershell.exe' }
            Assert-Throws { Test-SpoPrerequisites -SpoAdminUrl 'https://contoso-admin.sharepoint.com' } 'powershell\.exe'
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\fake\powershell.exe' } } -ParameterFilter { $Name -eq 'powershell.exe' }
            Mock Test-SpoModuleAvailable { $false }
            Assert-Throws { Test-SpoPrerequisites -SpoAdminUrl 'https://contoso-admin.sharepoint.com' } 'module is not installed'
            Mock Test-SpoModuleAvailable { $true }
            Assert-Equal (Test-SpoPrerequisites -SpoAdminUrl 'https://contoso-admin.sharepoint.com/') 'C:\fake\powershell.exe' 'host returned'
        }    }


    Context 'SharePoint window launch (Start-Process mocked)' {
        It 'starts the window with quoted arguments (paths with spaces) and writes the worker script' {
            Mock Start-Process { $script:Started = @{ File = $FilePath; Args = @($ArgumentList) } }
            $dir = Join-Path $TestDrive 'folder with spaces'; New-Item -ItemType Directory -Path $dir | Out-Null
            Start-SpoCollection -PowerShellPath 'C:\fake\powershell.exe' -AdminUrl 'https://contoso-admin.sharepoint.com' -WorkerPath (Join-Path $dir 'w.ps1') -WorkerCode '# worker' `
                -SiteCsv (Join-Path $dir 's.csv') -Marker (Join-Path $dir 'm.status') -LogPath (Join-Path $dir 'sp.log')
            Assert-Equal $script:Started.File 'C:\fake\powershell.exe' 'host'
            Assert-True ($script:Started.Args -contains ('"' + (Join-Path $dir 'w.ps1') + '"')) 'worker path quoted'
            Assert-True ($script:Started.Args -contains 'https://contoso-admin.sharepoint.com') 'admin url as is'
            Assert-True (Test-Path (Join-Path $dir 'w.ps1')) 'worker script written'
        }
    }
    It 'the SharePoint guard waits for a finished OK marker and fails on FAIL or timeout' {
        $m = Join-Path $TestDrive 'sp.status'
        Set-Content $m 'OK 12'
        Assert-Equal (Wait-SpoCollection -Marker $m -TimeoutMin 1) 'OK 12' 'ok marker'
        Set-Content $m 'FAIL: Access denied'
        Assert-Throws { Wait-SpoCollection -Marker $m -TimeoutMin 1 -RunDir $TestDrive } 'failed'
        Remove-Item $m
        Assert-Throws { Wait-SpoCollection -Marker $m -TimeoutMin 0 -RunDir $TestDrive } 'Timeout'
    }

    It 'end to end (fake Graph, real engine): enumeration -> lists -> sites -> seal -> CSV + HTML' {
        $e = New-RunEngine 'e2e' -Groups 0
        $script:mk = { param($n, $team) [pscustomobject]@{ id = (G $n); displayName = "Équipe $n"; mailNickname = "g$n"; mail = "g$n@example.test"; visibility = 'Private'; resourceProvisioningOptions = $(if ($team) { @('Team') } else { @() }) } }
        $script:Handler = {
            if ($Method -eq 'POST') {
                $req = ($Body | ConvertFrom-Json).requests
                [pscustomobject]@{ responses = @($req | ForEach-Object {
                    if ($_.id -like '*|own') { New-Sub $_.id 200 @() }
                    else { New-Sub $_.id 200 @([pscustomobject]@{ id = [guid]::NewGuid().ToString(); userPrincipalName = 'a@example.test'; displayName = 'A' }, [pscustomobject]@{ id = [guid]::NewGuid().ToString(); displayName = 'Only Name' }, [pscustomobject]@{ id = '99999999-9999-9999-9999-999999999999' }) }
                }) }
            } elseif ($Uri -like '*page=2') { [pscustomobject]@{ value = @((& $script:mk 3 $false)) } }
            else { [pscustomobject]@{ value = @((& $script:mk 1 $false), (& $script:mk 2 $true)); '@odata.nextLink' = 'https://graph.test/groups?page=2' } }
        }
        $auth = & $script:NewAuth
        [void](Invoke-GroupEnumeration -Engine $e -Auth $auth)
        $c = Invoke-ListCollection -Engine $e -Auth $auth -Sequential
        Assert-Equal $c.Ok 6 'lists written'
        $sites = Join-Path $TestDrive 'e2e-sites.csv'
        [System.IO.File]::WriteAllLines($sites, @('GroupId,Url', "$(G 1),https://example.test/sites/one"))
        [void](Import-SiteUrlsToEngine -Engine $e -Path $sites)
        $seal = Complete-InventoryRun -Engine $e -ErrorsCsv (Join-Path $TestDrive 'e2e-errors.csv')
        Assert-True $seal.IsSealed 'sealed'
        $run = Join-Path $TestDrive 'e2e-out'; New-Item -ItemType Directory $run | Out-Null
        $x = @(Export-InventoryReports -Engine $e -RunDir $run -OutName inv -Format HTML -AlsoCsv)
        Assert-Equal $x.Count 2 'CSV and HTML'
        $rows = @(Import-Csv -LiteralPath (Join-Path $run 'inv.csv') -Encoding UTF8)
        Assert-Equal $rows.Count 3 'rows'
        $g1 = $rows | Where-Object externalDirectoryObjectId -eq (G 1)
        Assert-Equal $g1.displayName 'Équipe 1' 'Unicode'; Assert-Equal $g1.groupType 'SharePoint' 'site'; Assert-Equal $g1.ownerless 'Yes' 'ownerless'; Assert-Equal $g1.ownersCount '0' 'verified zero'
        Assert-Equal $g1.membersCount '3' 'members'
        $mem = $g1.members -split ';'
        Assert-True (($mem -contains 'a@example.test') -and ($mem -contains 'Only Name') -and ($mem -contains '99999999-9999-9999-9999-999999999999')) 'UPN, then display name, then id'
        Assert-Equal ($rows | Where-Object externalDirectoryObjectId -eq (G 2)).groupType 'Teams' 'team'
        Assert-Equal ($rows | Where-Object externalDirectoryObjectId -eq (G 3)).groupType 'Classic' 'classic'
        Assert-True (Test-Path (Join-Path $run 'inv.html')) 'html index'
        Assert-True (-not (Test-Path (Join-Path $run 'inv_parts'))) 'default HTML is one self-contained file'
        Assert-Throws { Export-InventoryReports -Engine $e -RunDir $run -OutName inv -Format CSV } 'already exists'
        Assert-Equal @(Export-InventoryReports -Engine $e -RunDir $run -OutName inv -Format CSV -Overwrite).Count 1 'overwrite allowed on request'
    }

    It 'sources keep the flat layout, no hard-coded tte path, a $PSScriptRoot WorkDir default and a UTF-8 BOM' {
        foreach ($n in 'Invoke-M365GroupsReporting.ps1', 'Get-SiteUrls.ps1') {
            $p = Join-Path $projectRoot $n
            $text = [System.IO.File]::ReadAllText($p)
            Assert-True ($text -notmatch 'Scripts\\tte') "$n has no hard-coded tte path"
            Assert-True ($text -notmatch 'Export-GroupConfigParallel') "$n does not call the missing exporter"
            Assert-True ($text -match '\$WorkDir\s*=\s*\$PSScriptRoot') "$n WorkDir defaults to PSScriptRoot"
            $b = [System.IO.File]::ReadAllBytes($p)
            Assert-True ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) "$n has a UTF-8 BOM"
        }
        $mainText = [System.IO.File]::ReadAllText((Join-Path $projectRoot 'Invoke-M365GroupsReporting.ps1'))
        Assert-True ($mainText -match 'ClientSecret.*supplied as a parameter') 'secret parameter disables transcript'
    }

    It 'loads the Purview-style configuration and applies safe run retention' {
        $config = Import-PowerShellDataFile (Join-Path $projectRoot 'config\M365GroupsReporting.config.psd1')
        Assert-True ($config.Storage.RetentionDays -gt 0) 'storage retention configured'
        Assert-True ($config.Logging.RetentionDays -gt 0) 'log retention configured'
        $root = Join-Path $TestDrive 'retention'; New-Item -ItemType Directory -Path $root | Out-Null
        $old = Join-Path $root 'run_20200101_000000'; New-Item -ItemType Directory -Path $old | Out-Null
        $opts = New-Object GroupInventory.Engine.EngineOptions -Property @{ DatabasePath=(Join-Path $old 'inventory.sqlite'); RunId='retention'; SkipMembers=$true; SitesRequired=$false }
        $sealed = [GroupInventory.Engine.InventoryEngine]::Create($opts)
        [void]$sealed.CompleteFlow('enum',0); Assert-True $sealed.Seal().IsSealed 'empty synthetic snapshot sealed'; $sealed.Dispose()
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$($opts.DatabasePath);Pooling=False")
        try { $db.Open(); $cmd=$db.CreateCommand(); $cmd.CommandText="UPDATE engine_meta SET value='2020-01-01T00:00:00Z' WHERE key='sealed_utc'"; [void]$cmd.ExecuteNonQuery() } finally { $db.Dispose() }
        Set-Content -LiteralPath (Join-Path $old 'group_inventory.csv') -Value 'export'
        Set-Content -LiteralPath (Join-Path $old 'run.log') -Value 'log'
        (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-400)
        Invoke-M365GroupsRetention -Root $root -StorageRetentionDays 180 -LogRetentionDays 30 -KeepIncompleteRuns $true
        Assert-True (Test-Path $old) 'only/latest completed snapshot preserved while idle'
        $newer = Join-Path $root 'run_20200103_000000'; New-Item -ItemType Directory -Path $newer | Out-Null
        $opts.DatabasePath = Join-Path $newer 'inventory.sqlite'
        $sealed = [GroupInventory.Engine.InventoryEngine]::Create($opts)
        [void]$sealed.CompleteFlow('enum',0); [void]$sealed.Seal(); $sealed.Dispose()
        Invoke-M365GroupsRetention -Root $root -StorageRetentionDays 180 -LogRetentionDays 30 -KeepIncompleteRuns $true
        Assert-True (-not (Test-Path $old)) 'older completed snapshot removed after a newer seal exists'
        $incomplete = Join-Path $root 'run_20200102_000000'; New-Item -ItemType Directory -Path $incomplete | Out-Null
        Set-Content -LiteralPath (Join-Path $incomplete '_inv_graph_errors.csv') -Value 'failure'
        (Get-Item $incomplete).LastWriteTime = (Get-Date).AddDays(-400)
        Invoke-M365GroupsRetention -Root $root -StorageRetentionDays 180 -LogRetentionDays 30 -KeepIncompleteRuns $true
        Assert-True (Test-Path $incomplete) 'incomplete old run kept'
    }
}
