# Offline tests of the Group Inventory engine (C# .NET 8 + SQLite): staging, checkpoints, resume after a
# simulated crash, de-duplication, fail-closed sealing, atomic CSV/HTML exports, Unicode/quoting and a bounded
# synthetic benchmark. No network, no credentials, no tenant data: every identity below is synthetic.
# Run:  Invoke-Pester -Path .\GroupInventory.Engine.Tests.ps1
#   Optional large run (>= 400,000 objects):  $env:GROUP_INVENTORY_BENCH_OBJECTS = 400000
# The engine is built on demand with Build-Engine.ps1 (offline, no download). Plain assertion helpers are used so
# the file works with the legacy and the modern Should syntax.

Describe 'GroupInventory engine' {
    BeforeAll {
        $projectRoot = Split-Path -Parent $PSScriptRoot
        $src = Join-Path $projectRoot 'Invoke-M365GroupsReporting.ps1'
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$parseErrors)
        $d = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Import-GroupInventoryEngine' }, $false)
        . ([scriptblock]::Create($d[0].Extent.Text))
        $engineDir = Join-Path $projectRoot 'engine\bin'
        if (-not (Test-Path -LiteralPath (Join-Path $engineDir 'GroupInventory.Engine.dll'))) { & (Join-Path $projectRoot 'Build-Engine.ps1') | Out-Null }
        Import-GroupInventoryEngine -EngineDir $engineDir

        function Assert-Equal { param($Actual, $Expected, [string]$What)
            if ("$Actual" -ne "$Expected") { throw "Expected [$What] = '$Expected' but got '$Actual'" } }
        function Assert-True { param($Condition, [string]$What)
            if (-not $Condition) { throw "Expected true: $What" } }
        function Assert-Throws { param([scriptblock]$Script, [string]$Pattern)
            $msg = $null
            try { & $Script } catch { $msg = $_.Exception.Message }
            if ($null -eq $msg) { throw "Expected an exception matching '$Pattern' but none was thrown" }
            if ($Pattern -and $msg -notmatch $Pattern) { throw "Exception '$msg' does not match '$Pattern'" } }

        function G { param([int]$n) [guid]::new($n, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0).ToString() }
        function New-Opts { param([string]$Name, [switch]$SkipMembers, [switch]$NoSites, [hashtable]$Extra)
            $dir = Join-Path $TestDrive $Name; New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $o = New-Object GroupInventory.Engine.EngineOptions
            $o.DatabasePath = Join-Path $dir 'inventory.sqlite'; $o.RunId = 'test'; $o.SkipMembers = [bool]$SkipMembers; $o.SitesRequired = -not $NoSites
            $o.EnqueueTimeoutMs = 3000; $o.OperationTimeoutMs = 20000
            if ($Extra) { foreach ($k in $Extra.Keys) { $o.$k = $Extra[$k] } }
            $o }
        function New-Grp { param([int]$n, [string]$Name = "Group $n", [bool]$Team = $false)
            $g = New-Object GroupInventory.Engine.GroupRecord
            $g.Id = G $n; $g.DisplayName = $Name; $g.Alias = "alias$n"; $g.Mail = "alias$n@example.test"; $g.Visibility = 'Private'; $g.IsTeam = $Team
            $g }
        function Add-Groups { param($E, $Groups, [switch]$NoComplete)
            $r = $E.AddGroupPage(0, [GroupInventory.Engine.GroupRecord[]]@($Groups), '')
            if ($r.IsFailed) { throw "group page failed: $($r.Message)" }
            if (-not $NoComplete) { $c = $E.CompleteFlow('enum', @($Groups).Count); if ($c.IsFailed) { throw "enum complete failed: $($c.Message)" } } }
        function Put-List { param($E, [int]$Group, [int]$Kind, [string[]]$Users = @())
            $ids = [string[]]@($Users | ForEach-Object { G (1000 + [int]($_ -replace '\D', '')) })
            $E.AppendListPage((G $Group), $Kind, 0, $ids, [string[]]@($Users), '', $true, $Users.Count) }
        function Complete-Sites { param($E, $Map = @{})
            $ids = [string[]]@($Map.Keys | ForEach-Object { G $_ }); $urls = [string[]]@($Map.Keys | ForEach-Object { $Map[$_] })
            $r = $E.AddSitePage(0, $ids, $urls, ''); if ($r.IsFailed) { throw "site page failed: $($r.Message)" }
            $c = $E.CompleteFlow('sites', $ids.Count); if ($c.IsFailed) { throw "sites complete failed: $($c.Message)" } }
        function Get-Sql { param([string]$Db, [string]$Sql)
            $c = New-Object Microsoft.Data.Sqlite.SqliteConnection("Data Source=$Db;Mode=ReadOnly;Pooling=False")
            try { $c.Open(); $m = $c.CreateCommand(); $m.CommandText = $Sql; $m.ExecuteScalar() } finally { $c.Dispose() } }
        function Invoke-Sql { param([string]$Db, [string]$Sql)
            $c = New-Object Microsoft.Data.Sqlite.SqliteConnection("Data Source=$Db;Mode=ReadWrite;Pooling=False")
            try { $c.Open(); $m = $c.CreateCommand(); $m.CommandText = $Sql; [void]$m.ExecuteNonQuery() } finally { $c.Dispose() } }
        # three groups, everything collected, sealed
        function New-SealedRun { param([string]$Name, [switch]$SkipMembers, [hashtable]$Extra)
            $o = New-Opts $Name -SkipMembers:$SkipMembers -Extra $Extra
            $e = [GroupInventory.Engine.InventoryEngine]::Create($o)
            Add-Groups $e @((New-Grp 1 'Alpha'), (New-Grp 2 'Beta' $true), (New-Grp 3 'Gamma'))
            Complete-Sites $e @{ 1 = 'https://example.test/sites/alpha' }
            foreach ($g in 1, 2, 3) { [void](Put-List $e $g 1 @("o$g@example.test")) }
            if (-not $SkipMembers) { [void](Put-List $e 1 2 @('m1@example.test', 'm2@example.test')); [void](Put-List $e 2 2 @()); [void](Put-List $e 3 2 @('m3@example.test')) }
            $s = $e.Seal(); if (-not $s.IsSealed) { throw "seal failed: $($s.Message)" }
            [pscustomobject]@{ Engine = $e; Db = $o.DatabasePath; Dir = (Split-Path $o.DatabasePath) } }
    }

    # ------------------------------------------------------------------ schema, durability policy, single writer
    It 'creates a versioned database with the durable rollback-journal policy and no sidecar' {
        $o = New-Opts 'schema'
        $e = [GroupInventory.Engine.InventoryEngine]::Create($o)
        Add-Groups $e @((New-Grp 1)) -NoComplete
        $i = $e.Info()
        Assert-Equal $i.SchemaVersion 1 'schema version'
        Assert-Equal $i.ProtocolVersion 1 'protocol version'
        Assert-Equal $i.JournalMode 'delete' 'journal mode'
        Assert-Equal $i.State 'collecting' 'state'
        Assert-True ([version]($i.SqliteVersion) -ge [version]'3.35') 'SQLite 3.35+'
        Assert-True (Test-Path "$($o.DatabasePath).lock") 'lock file while the engine is open'
        Assert-True (-not (Test-Path "$($o.DatabasePath)-wal") -and -not (Test-Path "$($o.DatabasePath)-shm") -and -not (Test-Path "$($o.DatabasePath)-journal")) 'no WAL/SHM/journal sidecar'
        $e.Dispose()
        Assert-True (-not (Test-Path "$($o.DatabasePath).lock")) 'lock removed on dispose'
        Assert-Equal (Get-Sql $o.DatabasePath 'PRAGMA application_id') 0x47494E56 'application id'
        Assert-Equal (Get-Sql $o.DatabasePath 'PRAGMA user_version') 1 'user_version'
        Assert-Equal (Get-Sql $o.DatabasePath 'PRAGMA page_size') 8192 'page size'
        Assert-Equal (Get-Sql $o.DatabasePath 'SELECT COUNT(DISTINCT id) FROM pragma_foreign_key_list(''list_entry'')') 1 'foreign key on list_entry'
        Assert-Equal (Get-Sql $o.DatabasePath 'PRAGMA quick_check') 'ok' 'quick_check'
    }

    It 'one writer per database: a second engine is refused while the first is open; create never overwrites' {
        $o = New-Opts 'single'
        $e = [GroupInventory.Engine.InventoryEngine]::Create($o)
        Assert-Throws { [GroupInventory.Engine.InventoryEngine]::Resume((New-Opts 'single')) } 'in use'
        $e.Dispose()
        Assert-Throws { [GroupInventory.Engine.InventoryEngine]::Create((New-Opts 'single')) } 'already exists'
        $e2 = [GroupInventory.Engine.InventoryEngine]::Resume((New-Opts 'single'))
        Assert-Equal $e2.Info().Groups 0 'resumed empty run'
        $e2.Dispose()
        Assert-Throws { $e2.Info() } 'Disposed'
    }

    It 'resume refuses a foreign, newer-schema, other-run, other-setting or unreadable database' {
        $o = New-Opts 'ident'
        [GroupInventory.Engine.InventoryEngine]::Create($o).Dispose()
        Assert-Throws { $x = New-Opts 'ident'; $x.RunId = 'another'; [GroupInventory.Engine.InventoryEngine]::Resume($x) } 'run id mismatch'
        Assert-Throws { [GroupInventory.Engine.InventoryEngine]::Resume((New-Opts 'ident' -SkipMembers)) } 'SkipMembers'
        $adopt = New-Opts 'ident' -SkipMembers; $adopt.AdoptRunSettings = $true
        $e = [GroupInventory.Engine.InventoryEngine]::Resume($adopt); $e.Dispose()
        Assert-Equal $adopt.SkipMembers $false 'AdoptRunSettings takes the stored setting'
        Invoke-Sql $o.DatabasePath 'PRAGMA user_version=99'
        Assert-Throws { [GroupInventory.Engine.InventoryEngine]::Resume((New-Opts 'ident')) } 'newer than this engine'
        Invoke-Sql $o.DatabasePath 'PRAGMA user_version=1'
        Invoke-Sql $o.DatabasePath 'PRAGMA application_id=1'
        Assert-Throws { [GroupInventory.Engine.InventoryEngine]::Resume((New-Opts 'ident')) } 'not a Group Inventory'
        $junk = New-Opts 'junk'; [IO.File]::WriteAllText($junk.DatabasePath, ('not a database ' * 400))
        Assert-Throws { [GroupInventory.Engine.InventoryEngine]::Resume($junk) } '.'
        Assert-True (-not (Test-Path "$($junk.DatabasePath).lock")) 'no lock left after a refused open'
    }

    # ------------------------------------------------------------------ bounds and sanitising
    It 'rejects frames that break the bounds without storing anything' {
        $o = New-Opts 'bounds' -Extra @{ MaxEntriesPerFrame = 3; MaxFieldChars = 40 }
        $e = [GroupInventory.Engine.InventoryEngine]::Create($o)
        Add-Groups $e @((New-Grp 1)) -NoComplete
        Assert-Throws { $e.AddGroupPage(1, [GroupInventory.Engine.GroupRecord[]]@((New-Grp 2), (New-Grp 3), (New-Grp 4), (New-Grp 5)), '') } 'at most 3'
        Assert-Throws { $e.AddGroupPage(1, [GroupInventory.Engine.GroupRecord[]]@((New-Grp 2 ('x' * 41))), '') } 'exceeds 40'
        $bad = New-Grp 2; $bad.Id = 'not-a-guid'
        Assert-Throws { $e.AddGroupPage(1, [GroupInventory.Engine.GroupRecord[]]@($bad), '') } 'valid GUID'
        Assert-Throws { $e.AppendListPage((G 1), 3, 0, [string[]]@(), [string[]]@(), '', $true, 0) } 'kind'
        Assert-Throws { $e.AppendListPage((G 1), 1, 0, [string[]]@((G 9)), [string[]]@(), '', $true, 1) } 'same length'
        Assert-Throws { $e.AppendListPage((G 77), 1, 0, [string[]]@(), [string[]]@(), '', $true, 0) } 'unregistered'
        Assert-Throws { $e.AddGroupPage(1, [GroupInventory.Engine.GroupRecord[]]@((New-Grp 2)), ('c' * 5000)) } 'cursor'
        Assert-Throws { $e.CompleteFlow('other', 1) } 'Unknown flow'
        Assert-Equal $e.Info().Groups 1 'only the valid page was stored'
        $e.Dispose()
    }

    It 'members cannot be written when the run skips them' {
        $o = New-Opts 'skipbounds' -SkipMembers
        $e = [GroupInventory.Engine.InventoryEngine]::Create($o)
        Add-Groups $e @((New-Grp 1))
        Assert-Throws { $e.AppendListPage((G 1), 2, 0, [string[]]@(), [string[]]@(), '', $true, 0) } 'SkipMembers'
        $e.Dispose()
    }

    # ------------------------------------------------------------------ de-duplication, replay and conflicts
    It 'enumeration: identical duplicates are idempotent, replays are acknowledged, conflicts fail the flow' {
        $e = [GroupInventory.Engine.InventoryEngine]::Create((New-Opts 'enumdup'))
        $r = $e.AddGroupPage(0, [GroupInventory.Engine.GroupRecord[]]@((New-Grp 1), (New-Grp 1), (New-Grp 2)), 'https://graph.example.test/next')
        Assert-Equal $r.Status 'Applied' 'page 0'
        Assert-Equal $r.Duplicates 1 'duplicate by id'
        Assert-Equal $e.GetFlow('enum').Cursor 'https://graph.example.test/next' 'cursor checkpoint'
        Assert-Equal $e.GetFlow('enum').NextPage 1 'next page'
        $again = $e.AddGroupPage(0, [GroupInventory.Engine.GroupRecord[]]@((New-Grp 1), (New-Grp 1), (New-Grp 2)), 'https://graph.example.test/next')
        Assert-Equal $again.Status 'Replayed' 'same page, same content'
        Assert-Equal $e.GetFlow('enum').RowsSeen 3 'a replay does not count twice'
        $conflict = $e.AddGroupPage(0, [GroupInventory.Engine.GroupRecord[]]@((New-Grp 3)), '')
        Assert-Equal $conflict.Status 'Failed' 'same page number, other content'
        Assert-Equal $e.GetFlow('enum').State 'Failed' 'flow failed'
        Assert-True ($e.GetFailures(10)[0].Message -match 'conflict') 'failure recorded'
        $after = $e.AddGroupPage(1, [GroupInventory.Engine.GroupRecord[]]@((New-Grp 3)), '')
        Assert-Equal $after.Status 'Failed' 'no page after a failure until reset'
        Assert-Equal $e.Info().Groups 2 'only the committed groups'
        $e.Dispose()
    }

    It 'enumeration: a gap in the page sequence and a conflicting attribute in one pass are conflicts' {
        $e = [GroupInventory.Engine.InventoryEngine]::Create((New-Opts 'enumgap'))
        Add-Groups $e @((New-Grp 1)) -NoComplete
        Assert-Equal $e.AddGroupPage(5, [GroupInventory.Engine.GroupRecord[]]@((New-Grp 2)), '').Status 'Failed' 'gap'
        Assert-Equal $e.GetFlow('enum').State 'Failed' 'flow failed by the gap'
        [void]$e.ResetFlow('enum')
        Assert-Equal $e.GetFlow('enum').Pass 1 'new pass'
        Assert-Equal $e.AddGroupPage(0, [GroupInventory.Engine.GroupRecord[]]@((New-Grp 1)), '').Status 'Applied' 'group 1 confirmed in pass 1'
        Assert-Equal $e.AddGroupPage(1, [GroupInventory.Engine.GroupRecord[]]@((New-Grp 1 'Other name')), '').Status 'Failed' 'same group, other attributes, same pass'
        $e.Dispose()
    }

    It 'a restarted enumeration keeps confirmed groups and removes the ones that disappeared' {
        $e = [GroupInventory.Engine.InventoryEngine]::Create((New-Opts 'stale'))
        Add-Groups $e @((New-Grp 1), (New-Grp 2), (New-Grp 3)) -NoComplete
        [void]$e.ResetFlow('enum')
        $r = $e.AddGroupPage(0, [GroupInventory.Engine.GroupRecord[]]@((New-Grp 1), (New-Grp 2 'Beta renamed')), '')
        Assert-Equal $r.Status 'Applied' 'pass 1'
        $c = $e.CompleteFlow('enum', 2)
        Assert-Equal $c.Status 'Applied' 'complete'
        Assert-True ($c.Message -match '1 stale') 'stale group reported'
        Assert-Equal $e.Info().Groups 2 'group 3 removed'
        Assert-Equal $e.CompleteFlow('enum', 2).Status 'Replayed' 'completing twice is idempotent'
        $e.Dispose()
    }

    It 'lists: pages are de-duplicated by object id, replays are idempotent, counts must reconcile' {
        $e = [GroupInventory.Engine.InventoryEngine]::Create((New-Opts 'lists'))
        Add-Groups $e @((New-Grp 1), (New-Grp 2), (New-Grp 3))
        $u1 = (G 1001); $u2 = (G 1002); $u3 = (G 1003)
        $p0 = $e.AppendListPage((G 1), 1, 0, [string[]]@($u1, $u2, $u1), [string[]]@('u1', 'u2', 'u1'), 'https://graph.example.test/p1', $false, 0)
        Assert-Equal $p0.Status 'Applied' 'page 0'; Assert-Equal $p0.Duplicates 1 'duplicate inside a page'
        Assert-Equal $e.AppendListPage((G 1), 1, 0, [string[]]@($u1, $u2, $u1), [string[]]@('u1', 'u2', 'u1'), 'https://graph.example.test/p1', $false, 0).Status 'Replayed' 'replay of the last page'
        $p1 = $e.AppendListPage((G 1), 1, 1, [string[]]@($u2, $u3), [string[]]@('u2', 'u3'), '', $true, 5)
        Assert-Equal $p1.Status 'Applied' 'final page'; Assert-Equal $p1.Duplicates 1 'duplicate across pages'
        Assert-Equal $e.AppendListPage((G 1), 1, 0, [string[]]@($u1), [string[]]@('u1'), '', $true, 1).Status 'Replayed' 'a completed list ignores a restart'
        $r = $e.Reconcile()
        Assert-Equal $r.OwnerEntries 3 'distinct owners'; Assert-Equal $r.Duplicates 2 'duplicates removed'
        # declared total that does not match -> failed list, entries purged
        $bad = $e.AppendListPage((G 2), 1, 0, [string[]]@($u1), [string[]]@('u1'), '', $true, 9)
        Assert-Equal $bad.Status 'Failed' 'count mismatch'; Assert-True ($bad.Message -match 'Count mismatch') 'message'
        # conflicting display values for one id in one list
        $c = $e.AppendListPage((G 3), 1, 0, [string[]]@($u1, $u1), [string[]]@('first', 'second'), '', $true, 2)
        Assert-Equal $c.Status 'Failed' 'conflicting values'
        $r = $e.Reconcile()
        Assert-Equal $r.ListsFailed 2 'two failed lists'; Assert-Equal $r.OwnerEntries 3 'failed lists left no entries'
        Assert-True (-not ($r.Problems -match 'still hold entries')) 'no stray entries'
        # a sequence gap fails the list; a restart at page 0 recovers it
        [void]$e.AppendListPage((G 2), 2, 0, [string[]]@($u1), [string[]]@('u1'), 'c', $false, 0)
        Assert-Equal $e.AppendListPage((G 2), 2, 4, [string[]]@($u2), [string[]]@('u2'), '', $true, 2).Status 'Failed' 'gap'
        Assert-Equal $e.AppendListPage((G 2), 2, 1, [string[]]@($u2), [string[]]@('u2'), '', $true, 1).Status 'Failed' 'no continuation after failure'
        Assert-Equal $e.AppendListPage((G 2), 2, 0, [string[]]@($u1), [string[]]@('u1'), '', $true, 1).Status 'Applied' 'restart at page 0'
        Assert-Equal $e.FailList((G 2), 2, 500, 'x').Status 'Failed' 'a complete list cannot be failed'
        $e.Dispose()
    }

    It 'a missing or failed list is never an empty list: it blocks the seal and is reported' {
        $o = New-Opts 'failclosed'
        $e = [GroupInventory.Engine.InventoryEngine]::Create($o)
        Add-Groups $e @((New-Grp 1), (New-Grp 2))
        Complete-Sites $e @{ 1 = 'https://example.test/sites/one' }
        [void](Put-List $e 1 1 @('o1@example.test')); [void](Put-List $e 1 2 @('m1@example.test'))
        [void]$e.FailList((G 2), 1, 403, 'HTTP 403: Forbidden')
        $seal = $e.Seal()
        Assert-Equal $seal.IsSealed $false 'not sealed'
        Assert-True ($seal.Message -match 'incomplete') 'message says incomplete'
        $f = @($seal.Reconcile.Failures)
        Assert-True (@($f | Where-Object { $_.Request -eq 'owners' -and $_.Status -eq 403 -and $_.GroupId -eq (G 2) }).Count -eq 1) 'owners 403 reported'
        Assert-True (@($f | Where-Object { $_.Request -eq 'members' -and $_.GroupId -eq (G 2) -and $_.Message -match 'never completed' }).Count -eq 1) 'untouched members list reported'
        Assert-Equal $seal.Reconcile.VerifiedEmptyOwners 0 'no owner count invented'
        $out = Join-Path (Split-Path $o.DatabasePath) 'final.csv'
        Assert-Throws { $e.ExportCsv((New-Object GroupInventory.Engine.ExportOptions -Property @{ Path = $out })) } 'not sealed'
        Assert-True (-not (Test-Path $out)) 'no final file'
        Assert-Equal @(Get-ChildItem (Split-Path $o.DatabasePath) -Force | Where-Object Name -like '*.tmp').Count 0 'no temporary file'
        # FailGroups fails every unfinished list of the groups (worker crash)
        Assert-Equal $e.FailGroups([string[]]@((G 2)), 'Worker failed: boom').Rows 1 'one unfinished list (members)'
        Assert-Equal @($e.GetWorkBatch(0, 10)).Count 1 'only group 2 still needs work'
        Assert-Equal $e.GetWorkBatch(0, 10)[0].NeedOwners $true 'owners needed'
        $e.Dispose()
    }

    It 'seal is immutable; a sealed run opens read-only and can still be exported' {
        $run = New-SealedRun 'sealed'
        Assert-Equal $run.Engine.Info().State 'sealed' 'state'
        Assert-Throws { $run.Engine.AddGroupPage(9, [GroupInventory.Engine.GroupRecord[]]@((New-Grp 9)), '') } 'sealed'
        Assert-Throws { $run.Engine.ResetFlow('sites') } 'sealed'
        $run.Engine.Dispose()
        $ro = [GroupInventory.Engine.InventoryEngine]::OpenSealed((New-Opts 'sealed'))
        Assert-Equal $ro.Info().Groups 3 'read-only info'
        Assert-Throws { $ro.AddGroupPage(9, [GroupInventory.Engine.GroupRecord[]]@((New-Grp 9)), '') } 'read-only'
        $x = $ro.ExportCsv((New-Object GroupInventory.Engine.ExportOptions -Property @{ Path = (Join-Path $run.Dir 'out.csv') }))
        Assert-Equal $x.RowsWritten 3 'rows exported'
        $ro.Dispose()
    }

    # ------------------------------------------------------------------ crash and resume
    It 'simulated crash: the uncommitted operation is invisible and resume recollects only what is incomplete' {
        $dir = Join-Path $TestDrive 'crash'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $image = Join-Path $dir 'image.sqlite'
        $o = New-Opts 'crash' -Extra @{ TestCrashAtOp = 7; TestCrashImagePath = $image }
        $e = [GroupInventory.Engine.InventoryEngine]::Create($o)
        Add-Groups $e @((New-Grp 1), (New-Grp 2), (New-Grp 3))                       # ops 1, 2
        Complete-Sites $e @{ 1 = 'https://example.test/sites/one' }                   # ops 3, 4
        [void](Put-List $e 1 1 @('o1@example.test'))                                  # op 5: owners of group 1 complete (committed)
        [void]$e.AppendListPage((G 1), 2, 0, [string[]]@((G 1001)), [string[]]@('m1'), 'https://graph.example.test/p', $false, 0)   # op 6: members, one page (committed)
        Assert-Throws { Put-List $e 1 2 @('m1@example.test', 'm2@example.test') } 'Simulated crash'                              # op 7: dies before commit
        Assert-True $e.IsFaulted 'engine faulted'
        Assert-Throws { $e.Info() } 'Simulated crash'
        $e.Dispose()
        Assert-True (Test-Path $image) 'crash image captured'

        $o2 = New-Opts 'crash2'; Copy-Item $image $o2.DatabasePath
        if (Test-Path "$image-journal") { Copy-Item "$image-journal" "$($o2.DatabasePath)-journal" }
        $r = [GroupInventory.Engine.InventoryEngine]::Resume($o2)
        $i = $r.Info()
        Assert-Equal $i.Groups 3 'groups survived'
        Assert-Equal $i.Enum.State 'Complete' 'enumeration checkpoint survived'
        Assert-Equal $i.Sites.State 'Complete' 'sites checkpoint survived'
        Assert-Equal $i.ListsComplete 1 'only the committed list is complete'
        Assert-Equal $i.ListsCollecting 0 'the interrupted list was reset'
        Assert-Equal $i.ListsPending 5 'five lists remain'
        $work = @($r.GetWorkBatch(0, 10))
        Assert-Equal $work.Count 3 'three groups with work'
        Assert-Equal $work[0].NeedOwners $false 'group 1 owners are kept'; Assert-Equal $work[0].NeedMembers $true 'group 1 members redone'
        Assert-True (-not (Test-Path "$($o2.DatabasePath)-journal")) 'no journal left after recovery'
        Assert-Equal $r.Reconcile().MemberEntries 0 'no partial member entries'
        # finish the run selectively
        [void](Put-List $r 1 2 @('m1@example.test', 'm2@example.test'))
        foreach ($g in 2, 3) { [void](Put-List $r $g 1 @("o$g@example.test")); [void](Put-List $r $g 2 @()) }
        $s = $r.Seal(); Assert-True $s.IsSealed "sealed after resume: $($s.Message)"
        $csv = Join-Path (Split-Path $o2.DatabasePath) 'resumed.csv'
        [void]$r.ExportCsv((New-Object GroupInventory.Engine.ExportOptions -Property @{ Path = $csv }))
        $rows = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
        Assert-Equal $rows.Count 3 'rows'; Assert-Equal $rows[0].membersCount '2' 'members of group 1'
        $r.Dispose()
    }

    It 'killed process: committed work stays, interrupted lists are reset and failed lists are retried on resume' {
        $o = New-Opts 'killed'
        $e = [GroupInventory.Engine.InventoryEngine]::Create($o)
        Add-Groups $e @((New-Grp 1), (New-Grp 2))
        Complete-Sites $e @{}
        [void](Put-List $e 1 1 @('o1@example.test'))
        [void]$e.AppendListPage((G 1), 2, 0, [string[]]@((G 1001), (G 1002)), [string[]]@('a', 'b'), 'https://graph.example.test/p', $false, 0)
        [void]$e.FailList((G 2), 1, 429, 'throttled')
        $e.AbortForTest()
        $r = [GroupInventory.Engine.InventoryEngine]::Resume((New-Opts 'killed'))
        $i = $r.Info()
        Assert-Equal $i.ListsComplete 1 'complete list kept'; Assert-Equal $i.ListsCollecting 0 'interrupted list reset'
        Assert-Equal $i.ListsFailed 1 'failed list still reported until recollected'
        Assert-Equal @($r.GetWorkBatch(0, 10)).Count 2 'failed and interrupted lists are in the work list'
        Assert-Equal $r.AppendListPage((G 2), 1, 0, [string[]]@((G 1003)), [string[]]@('c'), '', $true, 1).Status 'Applied' 'a failed list restarts at page 0'
        Assert-Equal $r.GetFailures(10).Count 0 'its failure was cleared'
        $r.Dispose()
    }

    # ------------------------------------------------------------------ backpressure
    It 'a full bounded queue blocks producers (backpressure) and a timed-out write is idempotent' {
        $gate = New-Object System.Threading.ManualResetEventSlim($false)
        $o = New-Opts 'pressure' -Extra @{ QueueCapacity = 1; EnqueueTimeoutMs = 250; OperationTimeoutMs = 400; WriterGate = $gate }
        $e = [GroupInventory.Engine.InventoryEngine]::Create($o)
        $page = [GroupInventory.Engine.GroupRecord[]]@((New-Grp 1))
        Assert-Throws { $e.AddGroupPage(0, $page, '') } 'did not acknowledge'
        Assert-Throws { $e.AddGroupPage(1, [GroupInventory.Engine.GroupRecord[]]@((New-Grp 2)), '') } 'backpressure'
        $gate.Set()
        Start-Sleep -Milliseconds 300
        Assert-Equal $e.AddGroupPage(0, $page, '').Status 'Replayed' 'the first write was applied once, replay is idempotent'
        Assert-Equal $e.Info().Groups 1 'one group'
        $e.Dispose()
    }

    # ------------------------------------------------------------------ site URLs
    It 'sites: duplicates are idempotent, conflicting URLs fail the flow, orphans are counted, a reset restarts' {
        $e = [GroupInventory.Engine.InventoryEngine]::Create((New-Opts 'sites'))
        Add-Groups $e @((New-Grp 1))
        $r = $e.AddSitePage(0, [string[]]@((G 1), (G 1), (G 50)), [string[]]@('https://example.test/s/a', 'https://example.test/s/a', 'https://example.test/s/orphan'), '')
        Assert-Equal $r.Duplicates 1 'same url twice'
        Assert-Equal $e.AddSitePage(1, [string[]]@((G 1)), [string[]]@('https://example.test/s/OTHER'), '').Status 'Failed' 'conflicting URLs'
        Assert-Equal $e.GetFlow('sites').State 'Failed' 'flow failed'
        Assert-Throws { $e.AddSitePage(2, [string[]]@((G 1)), [string[]]@('http://example.test/insecure'), '') } 'https'
        [void]$e.ResetFlow('sites')
        Assert-Equal $e.GetFlow('sites').RowsSeen 0 'cleared'
        Complete-Sites $e @{ 1 = 'https://example.test/s/a'; 50 = 'https://example.test/s/orphan' }
        Assert-Equal $e.Reconcile().SiteOrphans 1 'orphan site counted'
        $e.Dispose()
        $o = New-Opts 'nosites' -NoSites
        $n = [GroupInventory.Engine.InventoryEngine]::Create($o)
        Add-Groups $n @((New-Grp 1)); [void](Put-List $n 1 1 @('o@example.test')); [void](Put-List $n 1 2 @())
        Assert-Throws { $n.AddSitePage(0, [string[]]@((G 1)), [string[]]@('https://example.test/x'), '') } 'not collected'
        Assert-True $n.Seal().IsSealed 'a run without required sites seals'
        $n.Dispose()
    }

    It 'binds nonsecret authenticated tenant provenance, rejects cross-tenant reuse and marks legacy history' {
        $o=New-Opts 'tenant-bound' -NoSites
        $e=[GroupInventory.Engine.InventoryEngine]::Create($o)
        $tenant='11111111-1111-1111-1111-111111111111'
        try {
            Assert-True (-not $e.BindAuthenticatedTenant($tenant).IsFailed) 'initial binding'
            Assert-Equal $e.Info().TenantId $tenant 'bound tenant'
            Assert-True (-not $e.Info().LegacyTenantHistoryUnverified) 'new empty snapshot has verified provenance'
            Assert-True $e.BindAuthenticatedTenant('22222222-2222-2222-2222-222222222222').IsFailed 'different tenant refused'
            [void]$e.CompleteFlow('enum',0);Assert-True $e.Seal().IsSealed 'seal after rejected tenant binding'
        } finally {$e.Dispose()}
        Assert-Equal ([GroupInventory.Engine.InventoryEngine]::InspectSealedSnapshot($o.DatabasePath)).TenantId $tenant 'binding persisted'
        $o=New-Opts 'tenant-legacy' -NoSites
        $e=[GroupInventory.Engine.InventoryEngine]::Create($o)
        try {
            Add-Groups $e @((New-Grp 1)) -NoComplete
            Assert-True (-not $e.BindAuthenticatedTenant($tenant).IsFailed) 'legacy run remains compatible'
            Assert-True $e.Info().LegacyTenantHistoryUnverified 'historical attribution warning retained'
        } finally {$e.Dispose()}
    }

    # ------------------------------------------------------------------ CSV export
    It 'CSV: 12 columns, UTF-8 BOM, CRLF, every field quoted, Unicode and quotes round-trip, formulas neutralised' {
        $o = New-Opts 'csv'
        $e = [GroupInventory.Engine.InventoryEngine]::Create($o)
        $names = @('Équipe "Ünïcödé", 日本語 😀', '=SUM(A1:A9)', ('bad' + [char]0xD800 + 'x'), "two`nlines", "comma, quote"" and ; semicolon")
        Add-Groups $e @(for ($i = 0; $i -lt $names.Count; $i++) { New-Grp ($i + 1) $names[$i] ($i -eq 0) })
        Complete-Sites $e @{ 1 = 'https://example.test/sites/one'; 2 = 'https://example.test/sites/two' }
        [void](Put-List $e 1 1 @('o1@example.test', '+weird@example.test')); [void](Put-List $e 1 2 @('m1@example.test'))
        foreach ($g in 2..5) { [void](Put-List $e $g 1 @()); [void](Put-List $e $g 2 @("m$g@example.test")) }
        Assert-True $e.Seal().IsSealed 'sealed'
        $csv = Join-Path (Split-Path $o.DatabasePath) 'inv.csv'
        $x = $e.ExportCsv((New-Object GroupInventory.Engine.ExportOptions -Property @{ Path = $csv }))
        Assert-Equal $x.RowsWritten 5 'rows'; Assert-Equal $x.RowsTotal 5 'total'; Assert-True ($x.FormulaNeutralized -ge 2) 'formula guard counted'
        Assert-Equal $x.Sha256 (Get-FileHash $csv -Algorithm SHA256).Hash.ToLowerInvariant() 'sha256 of the written file'
        $b = [IO.File]::ReadAllBytes($csv)
        Assert-True ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) 'UTF-8 BOM'
        $text = [Text.Encoding]::UTF8.GetString($b).TrimStart([char]0xFEFF)
        Assert-True ($text.Contains("`r`n") -and -not ($text -match "(?<!\r)\n")) 'CRLF only'
        $header = ($text -split "`r`n")[0]
        Assert-Equal $header '"displayName","alias","primarySmtpAddress","groupType","sharePointUrl","visibility","externalDirectoryObjectId","owners","members","ownersCount","membersCount","ownerless"' 'header'
        $rows = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
        Assert-Equal $rows.Count 5 'parsed rows'
        $r1 = $rows | Where-Object externalDirectoryObjectId -eq (G 1)
        Assert-Equal $r1.displayName 'Équipe "Ünïcödé", 日本語 😀' 'Unicode and quoting round-trip'
        Assert-Equal $r1.groupType 'Teams' 'team'; Assert-Equal $r1.sharePointUrl 'https://example.test/sites/one' 'site url'
        Assert-Equal $r1.owners "'+weird@example.test;o1@example.test" 'owners joined in canonical id order, formula guard on the first value'
        Assert-Equal $r1.ownersCount '2' 'ownersCount'; Assert-Equal $r1.membersCount '1' 'membersCount'; Assert-Equal $r1.ownerless 'No' 'ownerless'
        $r2 = $rows | Where-Object externalDirectoryObjectId -eq (G 2)
        Assert-Equal $r2.displayName "'=SUM(A1:A9)" 'formula neutralised'; Assert-Equal $r2.groupType 'SharePoint' 'site => SharePoint'; Assert-Equal $r2.ownerless 'Yes' 'ownerless'; Assert-Equal $r2.ownersCount '0' 'verified zero'
        Assert-Equal ($rows | Where-Object externalDirectoryObjectId -eq (G 3)).displayName "bad$([char]0xFFFD)x" 'lone surrogate replaced'
        Assert-Equal ($rows | Where-Object externalDirectoryObjectId -eq (G 4)).displayName 'two lines' 'line break normalised'
        Assert-Equal ($rows | Where-Object externalDirectoryObjectId -eq (G 5)).displayName 'comma, quote" and ; semicolon' 'comma, quote and semicolon'
        Assert-Equal ($rows | Where-Object externalDirectoryObjectId -eq (G 3)).groupType 'Classic' 'no site => Classic'
        Assert-True ($e.Summary().SanitizedFields -ge 2) 'sanitised fields counted'
        $raw = $e.ExportCsv((New-Object GroupInventory.Engine.ExportOptions -Property @{ Path = (Join-Path (Split-Path $o.DatabasePath) 'raw.csv'); NeutralizeFormulas = $false }))
        Assert-Equal $raw.FormulaNeutralized 0 'formula guard off'
        Assert-True ((Get-Content (Join-Path (Split-Path $o.DatabasePath) 'raw.csv') -Raw -Encoding UTF8).Contains('"=SUM(A1:A9)"')) 'raw value kept when asked'
        $e.Dispose()
    }

    It 'CSV: SkipMembers leaves members and membersCount empty (not zero)' {
        $run = New-SealedRun 'csvskip' -SkipMembers
        $csv = Join-Path $run.Dir 'skip.csv'
        [void]$run.Engine.ExportCsv((New-Object GroupInventory.Engine.ExportOptions -Property @{ Path = $csv }))
        $rows = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
        Assert-Equal $rows.Count 3 'rows'
        foreach ($r in $rows) { Assert-Equal $r.members '' 'members not collected'; Assert-Equal $r.membersCount '' 'membersCount not collected' }
        Assert-Equal $rows[0].ownersCount '1' 'owners still collected'
        $run.Engine.Dispose()
    }

    It 'configured CSV delimiter and opt-in HTML branding/timezone/tenant metadata are preserved safely' {
        $run = New-SealedRun 'metadata'
        try {
            $o=New-Object GroupInventory.Engine.ExportOptions -Property @{Path=(Join-Path $run.Dir 'semicolon.csv');CsvDelimiter=';'}
            [void]$run.Engine.ExportCsv($o)
            Assert-Equal @(Import-Csv -LiteralPath $o.Path -Delimiter ';').Count 3 'configured delimiter round-trip'
            $o.CsvDelimiter='invalid';$o.Path=Join-Path $run.Dir 'invalid.csv'
            Assert-Throws {$run.Engine.ExportCsv($o)} 'CsvDelimiter'
            Assert-True (-not (Test-Path $o.Path)) 'invalid delimiter leaves no partial file'
            $o=New-Object GroupInventory.Engine.ExportOptions -Property @{Path=(Join-Path $run.Dir 'meta.html');HtmlSingleFile=$true;HtmlChunkRows=1;Title='<synthetic-title>';CompanyName='Synthetic Company';TimeZone='Europe/Paris';TenantId='synthetic-tenant';EnvironmentName='Synthetic environment';CsvDelimiter='|'}
            [void]$run.Engine.ExportHtml($o)
            $html=[IO.File]::ReadAllText($o.Path)
            $meta=[regex]::Match($html,'<script id="group-meta" type="application/json">(?<json>.*?)</script>').Groups['json'].Value | ConvertFrom-Json
            Assert-Equal $meta.chunks 3 'multiple independent dictionaries'
            Assert-Equal $meta.title '<synthetic-title>' 'title JSON round-trip'
            Assert-Equal $meta.companyName 'Synthetic Company' 'branding'
            Assert-Equal $meta.timeZone 'Europe/Paris' 'time zone'
            Assert-Equal $meta.csvDelimiter '|' 'browser CSV delimiter'
            Assert-True (-not $meta.PSObject.Properties['tenantId']) 'tenant metadata omitted by default'
            Assert-True (-not $html.Contains('<synthetic-title>')) 'branding cannot inject raw HTML'
            $o.Path=Join-Path $run.Dir 'opt-in.html';$o.ShowTenantInformation=$true
            [void]$run.Engine.ExportHtml($o)
            $meta=[regex]::Match([IO.File]::ReadAllText($o.Path),'<script id="group-meta" type="application/json">(?<json>.*?)</script>').Groups['json'].Value | ConvertFrom-Json
            Assert-Equal $meta.tenantId 'synthetic-tenant' 'opt-in tenant'
            Assert-Equal $meta.environmentName 'Synthetic environment' 'opt-in environment'
        } finally { $run.Engine.Dispose() }
    }

    It 'export is atomic: an existing file is kept, overwrite replaces it, a failed export leaves no file' {
        $run = New-SealedRun 'atomic'
        $csv = Join-Path $run.Dir 'inv.csv'
        $opt = { param($ow) New-Object GroupInventory.Engine.ExportOptions -Property @{ Path = $csv; Overwrite = $ow } }
        $first = $run.Engine.ExportCsv((& $opt $false))
        $before = (Get-FileHash $csv).Hash
        Assert-Throws { $run.Engine.ExportCsv((& $opt $false)) } 'already exists'
        Assert-Equal (Get-FileHash $csv).Hash $before 'existing file untouched'
        $second = $run.Engine.ExportCsv((& $opt $true))
        Assert-Equal $second.Sha256 $first.Sha256 'deterministic export'
        Assert-Throws { $run.Engine.ExportCsv((New-Object GroupInventory.Engine.ExportOptions -Property @{ Path = (Join-Path $run.Dir 'inv.json') })) } 'only CSV and HTML|\.csv'
        Assert-Equal @(Get-ChildItem $run.Dir -Force | Where-Object Name -like '*.tmp').Count 0 'no temporary file'
        $run.Engine.Dispose()
        # tampering after the seal: stored count no longer matches the relations -> export fails mid-stream, nothing is published
        Invoke-Sql $run.Db 'UPDATE list_stream SET stored_count=stored_count+1 WHERE gid=1 AND kind=1'
        $ro = [GroupInventory.Engine.InventoryEngine]::OpenSealed((New-Opts 'atomic'))
        $victim = Join-Path $run.Dir 'tampered.csv'
        Assert-Throws { $ro.ExportCsv((New-Object GroupInventory.Engine.ExportOptions -Property @{ Path = $victim })) } 'integrity failure'
        Assert-True (-not (Test-Path $victim)) 'no partial final file'
        Assert-Equal @(Get-ChildItem $run.Dir -Force | Where-Object Name -like '*.tmp').Count 0 'temporary file removed'
        $ro.Dispose()
        # removing an entry changes the sealed totals: refused before anything is written
        Invoke-Sql $run.Db 'UPDATE list_stream SET stored_count=stored_count-1 WHERE gid=1 AND kind=1'
        Invoke-Sql $run.Db 'DELETE FROM list_entry WHERE entry_id=(SELECT entry_id FROM list_entry LIMIT 1)'
        $ro = [GroupInventory.Engine.InventoryEngine]::OpenSealed((New-Opts 'atomic'))
        Assert-Throws { $ro.ExportCsv((New-Object GroupInventory.Engine.ExportOptions -Property @{ Path = $victim })) } 'no longer matches'
        $ro.Dispose()
    }

    # ------------------------------------------------------------------ HTML export
    It 'HTML: compressed, interactive, partitioned, virtualized and atomically published' {
        $o = New-Opts 'html'
        $e = [GroupInventory.Engine.InventoryEngine]::Create($o)
        $names = @('<script>alert(1)</script>', 'Tom & "Jerry" <b>', 'plain', 'É日本😀', 'five')
        Add-Groups $e @(for ($i = 0; $i -lt $names.Count; $i++) { New-Grp ($i + 1) $names[$i] })
        Complete-Sites $e @{ 1 = 'https://example.test/sites/one?a=1&b=2' }
        [void](Put-List $e 1 1 @('<o1>@example.test', 'o2@example.test', 'o3@example.test', 'o4@example.test', 'o5@example.test'))
        [void](Put-List $e 1 2 @('m1@example.test'))
        foreach ($g in 2..5) { [void](Put-List $e $g 1 @('o@example.test')); [void](Put-List $e $g 2 @()) }
        Assert-True $e.Seal().IsSealed 'sealed'
        $index = Join-Path (Split-Path $o.DatabasePath) 'inv.html'
        $x = $e.ExportHtml((New-Object GroupInventory.Engine.ExportOptions -Property @{ Path = $index; HtmlRowsPerPart = 2; HtmlMaxRelationsPerCell = 2 }))
        Assert-Equal $x.Parts 3 'parts'; Assert-Equal $x.RowsWritten 5 'rows'; Assert-Equal $x.RelationsTruncated 0 'relations remain complete'
        Assert-True (Test-Path $index) 'index'
        $parts = @(Get-ChildItem (Join-Path (Split-Path $index) 'inv_parts') -Filter 'part_*.html' | Sort-Object Name)
        Assert-Equal $parts.Count 3 'part files'; Assert-Equal $parts[0].Name 'part_00001.html' 'part name'
        $all = (Get-Content $index -Raw -Encoding UTF8) + ($parts | ForEach-Object { Get-Content $_.FullName -Raw -Encoding UTF8 })
        Assert-True ($all.Contains('application/x-group-inventory-chunk')) 'compressed data chunk'
        Assert-True ($all.Contains('DecompressionStream')) 'browser decompression'
        Assert-True ($all.Contains('requestAnimationFrame')) 'virtual scrolling'
        Assert-True ($all.Contains('Export filtered CSV')) 'filtered export action'
        Assert-True ($all.Contains('Display name') -and $all.Contains('Owner') -and $all.Contains('Member') -and $all.Contains('Minimum owners')) 'field filters'
        Assert-True ($all.Contains('class="tile-icon"') -and $all.Contains('viewBox="0 0 24 24"')) 'Purview-style inline SVG icons'
        Assert-True ($all -notmatch '<script>alert\(1\)</script>') 'group values are not injected as HTML'
        $decodedRows = New-Object System.Collections.Generic.List[object]
        foreach ($part in $parts) {
            $chunk = [regex]::Match((Get-Content $part.FullName -Raw), '<script type="application/x-group-inventory-chunk">(?<data>[A-Za-z0-9+/=]+)</script>')
            Assert-True $chunk.Success 'chunk payload found'
            $compressed = [Convert]::FromBase64String($chunk.Groups['data'].Value)
            $input = New-Object IO.MemoryStream(, $compressed)
            $gzip = New-Object IO.Compression.GZipStream($input, ([IO.Compression.CompressionMode]::Decompress))
            $reader = New-Object IO.StreamReader($gzip, ([Text.Encoding]::UTF8))
            $json = $reader.ReadToEnd(); $reader.Dispose(); $gzip.Dispose(); $input.Dispose()
            $data = $json | ConvertFrom-Json
            Assert-Equal $data.version 2 'dictionary chunk schema'
            Assert-True ($data.people.Count -gt 0) 'local relation dictionary'
            foreach ($row in @($data.rows)) {
                $row.owners = @($row.owners | ForEach-Object { $data.people[$_] })
                $row.members = @($row.members | ForEach-Object { $data.people[$_] })
                $decodedRows.Add($row)
            }
        }
        Assert-True ($decodedRows[0].displayName -eq '<script>alert(1)</script>') 'group data survives inside compressed JSON'
        Assert-True ($decodedRows[1].displayName -eq 'Tom & "Jerry" <b>') 'special characters survive JSON encoding'
        Assert-True ($decodedRows[0].owners[0] -eq '<o1>@example.test') 'relation values survive JSON encoding'
        Assert-True ($decodedRows[0].sharePointUrl -eq 'https://example.test/sites/one?a=1&b=2') 'URL survives JSON encoding'
        Assert-True ($decodedRows[3].displayName -eq 'É日本😀') 'Unicode survives JSON encoding'
        Assert-True ($all -notmatch '(?i)(src|href|action)\s*=\s*"\s*(https?:|//|javascript:)') 'no external resource or script link'
        Assert-True ((Get-Content $index -Raw) -match 'inv_parts/part_00003\.html') 'index links the parts'
        Assert-Equal @(Get-ChildItem (Split-Path $index) -Force | Where-Object Name -like '.*').Count 0 'no staging folder left'
        Assert-Throws { $e.ExportHtml((New-Object GroupInventory.Engine.ExportOptions -Property @{ Path = $index })) } 'already exists'
        [void]$e.ExportHtml((New-Object GroupInventory.Engine.ExportOptions -Property @{ Path = $index; Overwrite = $true; HtmlRowsPerPart = 10 }))
        Assert-Equal @(Get-ChildItem (Join-Path (Split-Path $index) 'inv_parts') -Filter 'part_*.html').Count 1 'overwrite replaced the parts'
        Assert-Throws { $e.ExportHtml((New-Object GroupInventory.Engine.ExportOptions -Property @{ Path = $index; Overwrite = $true; HtmlRowsPerPart = 0 })) } 'HtmlRowsPerPart'
        $e.Dispose()
    }

    It 'HTML promotion restores previous single-file and partitioned exports after injected failures' {
        $run=New-SealedRun 'html-rollback'
        $index=Join-Path $run.Dir 'rollback.html'
        $parts=Join-Path $run.Dir 'rollback_parts'
        try {
            $options=New-Object GroupInventory.Engine.ExportOptions -Property @{Path=$index;HtmlRowsPerPart=2}
            [void]$run.Engine.ExportHtml($options)
            $indexHash=(Get-FileHash $index).Hash
            $partHashes=@(Get-ChildItem $parts -File | Sort-Object Name | ForEach-Object {(Get-FileHash $_.FullName).Hash}) -join ','
            $options.Overwrite=$true
            foreach($step in 1,2) {
                $options.TestFailPromotionAt=$step
                Assert-Throws {$run.Engine.ExportHtml($options)} 'previous export was restored'
                Assert-Equal (Get-FileHash $index).Hash $indexHash 'previous index preserved'
                Assert-Equal (@(Get-ChildItem $parts -File | Sort-Object Name | ForEach-Object {(Get-FileHash $_.FullName).Hash}) -join ',') $partHashes 'previous parts preserved'
            }
            $options.HtmlSingleFile=$true;$options.TestFailPromotionAt=1
            Assert-Throws {$run.Engine.ExportHtml($options)} 'previous export was restored'
            Assert-Equal (Get-FileHash $index).Hash $indexHash 'partition-to-single rollback index'
            Assert-True (Test-Path $parts) 'partition-to-single rollback parts'
            $options.TestFailPromotionAt=0;[void]$run.Engine.ExportHtml($options)
            Assert-True (-not (Test-Path $parts)) 'successful single-file conversion removes obsolete parts'
            $singleHash=(Get-FileHash $index).Hash;$options.TestFailPromotionAt=1
            Assert-Throws {$run.Engine.ExportHtml($options)} 'previous export was restored'
            Assert-Equal (Get-FileHash $index).Hash $singleHash 'previous single-file export preserved'
            Assert-Equal @(Get-ChildItem $run.Dir -Force | Where-Object Name -like '.rollback.*').Count 0 'no staging/rollback remnants'
        } finally {$run.Engine.Dispose()}
    }

    # ------------------------------------------------------------------ synthetic benchmark (bounded) and multi-thread writer
    It 'synthetic benchmark: 8 threads, bounded queue, sealed, exported, bounded memory' {
        $dir = Join-Path $TestDrive 'bench'
        $r = [GroupInventory.Engine.SyntheticBenchmark]::Run($dir, 1500, 2, 8, 8, 16)
        Assert-True $r.Sealed 'sealed'
        Assert-Equal $r.Groups 1500 'groups'; Assert-Equal $r.ListEntries 15000 'entries'; Assert-Equal $r.TotalObjects 16500 'objects'
        Assert-True ($r.MaxQueueDepth -le 16) "queue stayed bounded ($($r.MaxQueueDepth) <= 16)"
        Assert-True ($r.Transactions -gt 0 -and $r.Transactions -le $r.Operations) 'writes are grouped into bounded transactions'
        Assert-True ($r.PeakManagedMb -lt 256) "managed memory stays small ($([int]$r.PeakManagedMb) MB)"
        Assert-Equal $r.HtmlParts 2 'html parts'
        Assert-Equal @(Import-Csv -LiteralPath $r.CsvPath -Encoding UTF8).Count 1500 'csv rows'
        Assert-Equal (Get-Sql $r.DatabasePath 'PRAGMA quick_check') 'ok' 'database intact'
        Assert-True (-not (Test-Path "$($r.DatabasePath)-journal") -and -not (Test-Path "$($r.DatabasePath)-wal")) 'no sidecar'
    }

    It 'optional large run (set GROUP_INVENTORY_BENCH_OBJECTS, e.g. 400000): >= N cumulative objects, streamed' -Skip:(-not $env:GROUP_INVENTORY_BENCH_OBJECTS) {
        $n = [int]$env:GROUP_INVENTORY_BENCH_OBJECTS
        $groups = [int][Math]::Ceiling($n / 20)                       # 1 group + 2 owners + 17 members = 20 objects
        $r = [GroupInventory.Engine.SyntheticBenchmark]::Run((Join-Path $TestDrive 'bench-large'), $groups, 2, 17, 32, 64)
        Write-Host ("benchmark: {0} objects, write {1:N1}s, seal {2:N1}s, csv {3:N1}s, html {4:N1}s, peak managed {5:N0} MB, db {6:N0} MB" -f $r.TotalObjects, $r.WriteSeconds, $r.SealSeconds, $r.CsvSeconds, $r.HtmlSeconds, $r.PeakManagedMb, ($r.DatabaseBytes / 1MB))
        Assert-True ($r.TotalObjects -ge $n) 'object count reached'
        Assert-True $r.Sealed 'sealed'
        Assert-True ($r.PeakManagedMb -lt 512) 'bounded memory'
    }
}

# SIG # Begin signature block
# MIIghQYJKoZIhvcNAQcCoIIgdjCCIHICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCFrg059Utic3Sr
# vi0WzShijADX7c+cyreLl8XctHR5i6CCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCD+R5DhOZCk
# WSn32l0PkTJ1cWCpj3VnDjqziryovHVgzDANBgkqhkiG9w0BAQEFAASCAgBYULP8
# X2GgqKv2qNexovI7bshTGQHpWVLnrX/JMheFtOKBHZchrB+0/g5Cu2N/QoIOvsK8
# FT2985MSk4RpWkMak7FBmv2nlz4bsG/EG8tv7uZagKVVp4BK7wfFbVzQhk9nTYId
# 9zwcl2QwDDqaOTbYI/ML6w4u7p3VxnXq2x8VocUux6D/RXLqQrhF7sRzMZ07/GLo
# FeB3EWlQYI1CYWvmvhk6SgI1/qs+B3yRw4/Pr44xi21LW26lJ7+ZChfDd2IZIorb
# ut9YsQMabsZpalJ7hTKTSVbX4ux2ifFiU79V4cuWVjgTIFfBEFP/auFLRnFkEAz/
# N6SxPzXalZS0gFkvJWQ3ajsmviaYnwylucT85edy8FYIKHLlgJLxIjNGqwmM8+AM
# PKLB6UD9nsec6ppfgMOre+k9hqcFBHMoWQ1Sd+ZZDPPZkVx2eTvCs7qtVBdhSxRu
# T5iEQ6Tr4ZiDlzT3xKSa4OumQvCPTan9lCtvzBcbIoF3EQ5yzQyrUv/WJSxkVEl9
# W/kQZICFqez0JvS9Akkoq8H1P3NXllAqhSYWSr2O2hKBvkHKnHwr3thYEl3i4wBA
# R2UVM63tJ1tCMh3A+mLjvtSNSzU+HJ5qyFKsdMkXSvVat/7LQB1u5RB8jE4I+LnJ
# uZT661bpNQXDhsS68U/gdhjgLgW1MtaizdLkVqGCDykwgg8lBgorBgEEAYI3AwMB
# MYIPFTCCDxEGCSqGSIb3DQEHAqCCDwIwgg7+AgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEILwCy5rLO2/huvHCWqzw2JPhS28ct+DfEw285h2KR8SqAghMyAooor6o
# yBgPMjAyNjEwMTQxNzA3MDFaMAMCAQECEF5JFZmePKKDQjFitiK/i1egggwAMIIE
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
# HAYJKoZIhvcNAQkFMQ8XDTI2MTAxNDE3MDcwMVowKAYJKoZIhvcNAQk0MRswGTAL
# BglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIGOgedVDWL47
# EshwBQ3xAVrsKNRLdiB94VnkD6vl/dTPMIHJBgsqhkiG9w0BCRACLzGBuTCBtjCB
# szCBsAQgVCr5oWqNci5mEUl4iumUwYqaruWmXLNEolSa+Wx5x4swgYswd6R1MHMx
# CzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjER
# MA8GA1UECgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5n
# IElzc3VpbmcgUlNBIENBIFIxAhAfaxZi0i4bbF3xwMGgYA44MAoGCCqGSM49BAMC
# BEcwRQIhAKJUJTpcWLlszUabeID0YLqYwAZgOukZm7iTt9Ztogp1AiBYXM3DFlxP
# M8B3bRnS7LvuqaSHtGAqbHavlOjHq1IsFQ==
# SIG # End signature block
