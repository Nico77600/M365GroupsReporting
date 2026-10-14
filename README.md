# M365GroupsReporting (groups, owners, members, SharePoint site URLs)

PowerShell 7.4+ orchestrator + offline C# engine (.NET 8, SQLite) that produces a **CSV or HTML** inventory of the
Microsoft 365 (Unified) groups of a tenant. Sized for **at least 400,000 cumulative objects** (groups + owners + members).

* **PowerShell** (`Invoke-M365GroupsReporting.ps1`) owns configuration, authentication and every Graph / SharePoint call.
* **Configuration** (`config\M365GroupsReporting.config.psd1`) follows the PurviewDlpReport pattern: operational settings
  and retention are centralized; secrets remain external through explicit authentication modes.
* **The engine** (`src\`, `GroupInventory.Engine.dll`) is passive and offline: it never receives a credential or a token.
  It owns staging in a durable SQLite database, checkpoints, de-duplication, reconciliation, sealing and the streaming exports.
* **Fail-closed**: if any source, page, worker or list is incomplete, or a count does not reconcile, the run is **not sealed**
  and **no final file is produced**. Owners/members are never assumed empty.
* A SharePoint source with no valid `GROUP#0` rows is rejected; a group returning HTTP 404 during list collection is
  removed only after a direct group re-check confirms that it disappeared.

Parity changes are validated offline (fake Graph, synthetic data), without altering existing tenant/lab snapshots.
No signing, commit or publication is part of this work.

## Quick start

```powershell
.\Build-Engine.ps1                                             # offline build of engine\bin (no download)
.\Invoke-M365GroupsReporting.ps1 -SiteUrlsCsv .\siteurls.csv        # CSV + single-file HTML; external credentials
.\Invoke-M365GroupsReporting.ps1 -SiteUrlsCsv .\siteurls.csv -Format HTML
.\Invoke-M365GroupsReporting.ps1 -ResumeRun .\run_20260101_120000 -SiteUrlsCsv .\siteurls.csv    # continue an interrupted/incomplete run
```

Edit `config\M365GroupsReporting.config.psd1` to change database/log/report paths, concurrency, branding,
formats, delimiter, time zone and retention. Relative paths resolve from the tool root, exactly like PurviewDlpReport,
not from `config\`. Command-line parameters override configuration for one execution.
See the [administrator guide](docs/GroupInventory-Guide.md) or generated `docs\GroupInventory-Guide.html`.

For a clean delivery directory (without credentials, databases, runs or build intermediates):

```powershell
.\tools\Build-Documentation.ps1
.\tools\New-GroupInventoryPackage.ps1
```

The source keeps `Invoke-M365GroupsReporting.ps1` and `Get-SiteUrls.ps1` at the root;
the offline engine sources are under `src`, canonical tests under `tests`, the HTML template under `templates`,
and packaging/documentation helpers under `tools` and `docs`. Root test files remain compatibility wrappers.
Development still builds to `engine\bin`; delivery uses `lib\engine` and ships no `bin` directory.

* `-SiteUrlsCsv` is a `GroupId,Url` file (see `Get-SiteUrls.ps1`, interactive SharePoint Admin helper). It is the supported route.
* `-SpoAdminUrl https://<tenant>-admin.sharepoint.com` keeps the previous interactive behaviour (a new Windows PowerShell 5.1
  window, `Get-SPOSite -Template GROUP#0`). **It has not been qualified outside a lab.** Its prerequisites (admin URL shape,
  `powershell.exe`, `Microsoft.Online.SharePoint.PowerShell` module for Windows PowerShell 5.1) are verified before any work and
  the run fails with an explicit message when one is missing.
* Authentication: **prefer `Certificate`** with a local RSA private key and its matching public certificate registered
  to the configured AppId. `ClientSecretFile` (external protected JSON: `TenantId`, `ClientId`, `ClientSecret`) and
  `ClientSecretEnvironment` are compatibility/lab modes; the default file mode preserves existing deployments.
  `-ClientSecret` is deprecated and disables transcripts while retaining fixed secret-safe lifecycle diagnostics.
  Secrets and private keys never reach the engine/package.

## Run folder

Default: `data\run_<yyyyMMdd_HHmmss>\M365GroupsReporting.sqlite`,
`reports\run_<stamp>\M365GroupsReporting.csv/html`, and `logs\run_<stamp>\`.
`Storage.DatabasePath` defines the database filename and snapshot parent directory.
**Accepted domain difference:** immutable inventories require snapshots instead of Purview's mutable event history.
`-WorkDir` preserves the legacy combined `<WorkDir>\run_<stamp>\` layout unless output/log paths are overridden.

| File | Content |
| --- | --- |
| `M365GroupsReporting.sqlite` (`inventory.sqlite` in legacy WorkDir runs) | durable tenant-data snapshot |
| `run.log`, `resume_<stamp>.log` | transcripts, retained according to `Logging.RetentionDays` |
| `M365GroupsReporting.csv` | final CSV (configured `Report.FilePrefix`) |
| `M365GroupsReporting.html` | final single-file interactive HTML report |
| `M365GroupsReporting_parts\part_00001.html` ... | optional legacy partitioned layout (`-HtmlPartitioned`) |
| `_inv_graph_errors.csv` | failures, only when the run is incomplete (no final file then) |
| `_inv_sites.csv`, `_inv_sp.status`, `sp.log`, `_inv_sp_worker.ps1` | SharePoint intermediates |

After successful export and engine/log closure, retention removes only older validated sealed snapshots.
The latest completed snapshot, active/locked runs and incomplete/unknown/corrupt snapshots are preserved.
Logs age independently by each file's timestamp; incomplete-run and locked logs are protected.
Separate report folders are not automatically deleted. Zero disables the corresponding policy.

`_inv_graph.csv` (the former Graph intermediate) no longer exists: the database is the intermediate.

## Parameters (changes)

* `-Format CSV|HTML` only; omitted uses `Report.Formats` (both by default). **JSON/JSONL were removed** together with `-JsonArrayMax`.
* Explicit config paths: `Storage.DatabasePath`, `Logging.Path`, `Report.OutputPath`; overrides `-DatabasePath -LogPath -OutputPath`.
* `-AuthMode -CertificateThumbprint` override explicit authentication. Title/company/tenant/environment display,
  time zone, formats, filename prefix and delimiter are authoritative configuration defaults.
* `-ConfigPath`, `-ResumeRun <run folder|inventory.sqlite>`, `-OverwriteExport`, `-HtmlPartitioned`, `-HtmlRowsPerPart` (10000), `-HtmlMaxRelations` (25), `-RawCsvValues`, `-NoRetention`: new.
* `-HtmlMax` (total HTML row cap) was removed: every group is in the interactive report.
* Unchanged: `-WorkDir -CredFile -TenantId -ClientId -ClientSecret -OutName -ThrottleLimit -SkipMembers -Max -GridView -GridViewMax -SpTimeoutMin -SpoAdminUrl -SiteUrlsCsv`.
  `-GridView` shows at most `-GridViewMax` rows of the CSV (the CSV is also exported when `-Format HTML`). `-Max N` collects a deliberate sample of N groups.

## How a run works

1. Site URLs (CSV: streamed into the engine first so that a bad file fails early; interactive: a window works in parallel).
2. Group enumeration (Graph, `$top=999`): one engine transaction per page; the checkpoint (page number, content hash and the next-page cursor) is committed with the page.
3. Owners/members: `GetWorkBatch` gives the groups that still have a pending, interrupted or failed list; runspace workers call Graph `$batch`,
   follow `@odata.nextLink`, and write each page through the engine's **single bounded writer**. Memory use does not grow with the tenant size.
4. `Seal`: exact reconciliation (every group has a complete owners list and, unless `-SkipMembers`, a complete members list; stored rows = declared
   counts = rows present; no stray rows; enumeration and sites flows complete; stale groups removed; `quick_check` and `foreign_key_check`). Only then the run is sealed (immutable).
5. Exports of the sealed run, streamed to a temporary name, flushed, verified and moved into place atomically.

### Resume

`-ResumeRun` reopens the database (schema/application/run-id/setting checks, integrity check, SQLite hot-journal recovery), keeps every completed list,
resets lists that were interrupted mid-way to *pending*, retries *failed* lists, and re-reads only an unfinished enumeration (from its stored cursor; if Graph rejects
the cursor the enumeration restarts and de-duplicates by id) or an unfinished site source. A sealed run is only re-exported. If you did not pass `-SkipMembers`
the run keeps the setting it was created with; passing the opposite is refused.

Limit: a list interrupted in the middle is recollected from its first page (the page checkpoints exist in the database, but resuming inside a list is not used).

## Output formats

**CSV** - UTF-8 **with BOM**, CRLF, every field quoted, header + these 12 columns (unchanged):
`displayName, alias, primarySmtpAddress, groupType, sharePointUrl, visibility, externalDirectoryObjectId, owners, members, ownersCount, membersCount, ownerless`.
`owners`/`members` are `;`-joined (UPN, else display name, else id) in directory-object-id order; with `-SkipMembers` `members` and `membersCount` are empty
(not collected, not 0); `groupType` is `Teams`, `SharePoint` (has a site URL) or `Classic`; rows are ordered by group id. Values that a spreadsheet could take for a formula
(first character `= + - @` or TAB) get a leading apostrophe and are counted in the export result, unless `-RawCsvValues`. Control characters become spaces and unpaired surrogates `U+FFFD` (counted).

**HTML** - self-contained (inline CSS/JavaScript, no external resource, restrictive CSP meta), like PurviewDlpReport:
`M365GroupsReporting.html` contains all groups as gzip-compressed chunks and provides field-specific filters for name,
alias, SMTP, type, SharePoint URL, visibility, owner, member, relation counts and ownerless state, plus sorting,
virtual scrolling, details and filtered CSV export. Full Purview theme variables and neutral components include
filtered summary, member-count distribution and top-ten group ranking. Relation dictionaries and typed masks
optimize repeated owner/member filtering. `-HtmlMaxRelations` limits only
the visible relation preview; complete owner/member lists remain embedded in the compressed data. Use
`-HtmlPartitioned` only when separate HTML files are explicitly required.

An existing export is never overwritten unless `-OverwriteExport`.

## Engine (engine\)

`Build-Engine.ps1` runs `dotnet build engine\GroupInventory.Engine.csproj` into `engine\bin`. No `PackageReference`: SQLite comes from `lib\sqlite`
(`Microsoft.Data.Sqlite` 10.0.12, SQLitePCLRaw 2.1.12, natives win-x64/win-arm64). If the .NET 8 targeting pack is not installed the script compiles against the newest
installed `Microsoft.NETCore.App 8.0.x` runtime instead (nothing is downloaded); it fails with a precise message when there is no SDK or no .NET 8 runtime.
Rebuild after changing `src`.

* `InventoryEngine.Create / Resume / OpenSealed`; `AddGroupPage`, `AddSitePage`, `AppendListPage`, `FailList`, `FailGroups`, `CompleteFlow`, `MarkFlowFailed`, `ResetFlow`,
  `GetFlow`, `GetWorkBatch`, `GetFailures`, `Info`, `Reconcile`, `Seal`, `ExportCsv`, `ExportHtml`, `Summary`.
* A write returns only after the transaction holding it (and its checkpoint) is committed. Same page + same content = replayed (idempotent); same page + other content, or a gap =
  conflict that fails the flow/list. Duplicates are removed by object id (a different value for the same id fails the list).
* One writer thread owns the single write connection; producers feed a bounded queue (`QueueCapacity`) and block, then fail with a backpressure error, when it is full;
  transactions are bounded by rows and time. Bounds per frame: entries, characters per field and per frame. An unexpected writer error faults the engine (restart and resume).
* SQLite policy, verified after being set: `journal_mode=DELETE` (rollback journal, WAL never), `synchronous=FULL`, `foreign_keys=ON`, `trusted_schema=OFF`, `cell_size_check=ON`,
  `temp_store=MEMORY`, `mmap_size=0`, `application_id`/`user_version` (schema 1) + metadata/protocol version, `quick_check`/`foreign_key_check` at resume, seal and export,
  a `<db>.lock` file against a second writer, no `-wal/-shm` sidecar.
* Exports read through a separate **read-only** connection, require a sealed run whose totals still match, and never keep partial output.

## Tests (offline: no network, no credentials)

```powershell
Invoke-Pester -Path .\tests\Invoke-M365GroupsReporting.Tests.ps1,.\tests\GroupInventory.Engine.Tests.ps1,.\tests\M365GroupsReporting.Parity.Tests.ps1
$env:GROUP_INVENTORY_BENCH_OBJECTS = 400000; Invoke-Pester -Path .\tests\GroupInventory.Engine.Tests.ps1
```

Both files pass with the installed Pester 3.4.0 and 6.1.0. The engine is built on demand if `engine\bin` is missing. Synthetic benchmark on a developer workstation
(in-process, no Graph latency): 20,000 groups x (2 owners + 17 members) = 400,000 objects, 32 producer threads: write ~21 s, seal ~0.6 s, CSV ~1 s, HTML (20 parts) ~1 s,
managed heap growth ~13 MB, database ~38 MB.

## Known limits / not done

* Certificate mode was live-qualified on 2026-10-14 with a dedicated registered RSA certificate: a 100-group sample,
  200 complete owner/member lists, successful reconciliation/seal, CSV and single-file HTML, using the existing
  SharePoint CSV route. Existing app credentials and consent were preserved. This is not a certificate-mode full-tenant
  or interactive SharePoint qualification; environment-secret mode remains unqualified live.
* Packaging is locally validated; no signing, commit, publication or GitHub change is part of this work.
* Resume restarts an interrupted list from its first page; resuming inside a very large list is not implemented.
* Windows x64/arm64 only (bundled natives). The database and the exports contain tenant data; this repository must not receive them
  (`app_creds.json`, `run_*`, `*.sqlite` are listed in `.gitignore`).
