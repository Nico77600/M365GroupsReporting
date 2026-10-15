---
title: M365GroupsReporting
subtitle: Administrator guide
version: 1.0.0
author: Nicolas Fabert
updated: 2026-10-14
---
# M365GroupsReporting

> A complete, fail-closed inventory of Microsoft 365 groups, owners, members and SharePoint site URLs.

```cards
database | Durable snapshots | SQLite checkpoints, one bounded writer, reconciliation before sealing.
chart | Self-contained reports | CSV and a single HTML file with complete relations, filters and a virtualized grid.
shield | External credentials | Explicit authentication modes; secrets never enter the engine or package.
```

<!-- icon: download -->
## 1. Installation and quick start

Use PowerShell 7.4+ on Windows x64 or arm64. The delivery package contains a compiled .NET 8 engine
and SQLite dependencies under `lib\engine`; no SDK or download is needed to run it.
Developers need an installed .NET SDK plus the .NET 8 targeting pack or runtime to build offline.

```powershell
.\Invoke-M365GroupsReporting.ps1 -SiteUrlsCsv .\siteurls.csv
.\Invoke-M365GroupsReporting.ps1 -SiteUrlsCsv .\siteurls.csv -Format HTML
.\Invoke-M365GroupsReporting.ps1 -ResumeRun .\data\run_20260101_120000 -OverwriteExport
Get-Help .\Invoke-M365GroupsReporting.ps1 -Full
```

The default configuration produces CSV and HTML. `-Format CSV` or `-Format HTML` overrides it.
A valid SharePoint `GroupId,Url` source is required for a new run; an empty source fails closed.
`Get-SiteUrls.ps1` collects `GROUP#0` sites. Its interactive SharePoint route requires Windows
PowerShell 5.1 and `Microsoft.Online.SharePoint.PowerShell`, modern authentication and an admin URL.
It remains unqualified outside the existing lab; a prepared site CSV is the recommended route.

The commands above run a finalized release package. For a source Git checkout, first run
`.\Build-Engine.ps1`, then pass `-SourceDevelopment` to either source entry point. That explicit
unauthenticated mode is rejected in runtime artifacts and is never a release-validation result.

<!-- icon: settings -->
## 2. Configuration and paths

Edit `config\M365GroupsReporting.config.psd1`. Like the actual PurviewDlpReport importer,
all relative paths are resolved from the **tool root**, even for a configuration elsewhere.
Environment variables in path values are expanded. Command-line overrides are preserved.
Configuration is validated before creating a run.

| Setting | Meaning |
| --- | --- |
| `Storage.DatabasePath` | Snapshot base directory and database filename; default `.\data\M365GroupsReporting.sqlite` |
| `Storage.RetentionDays` | Age of older sealed snapshots eligible for removal; zero keeps all |
| `Storage.KeepIncompleteRuns` | Incomplete/unknown/corrupt snapshots are always preserved for safety |
| `Logging.Path`, `RetentionDays` | Independent log root and file-age retention; zero keeps all |
| `Report.OutputPath` | Report root; one `run_<timestamp>` subdirectory per snapshot |
| `Report.Formats` | `@('CSV','HTML')`; use either or both |
| `Report.FilePrefix` | `M365GroupsReporting`; must be a valid filename part |
| `Report.CsvDelimiter` | Semicolon by default; comma, pipe and tab also supported |
| `Report.TimeZone` | `Europe/Paris`; report seal time rendered in this zone |
| `Report.Title`, `CompanyName` | Report heading and optional company branding |
| `Report.ShowTenantInformation` | False by default; opt-in tenant and environment display |
| `Report.EnvironmentName` | Optional label shown only when tenant display is enabled |
| `Collection.ThrottleLimit`, `MaxGroups`, `SkipMembers` | Concurrency, deliberate sample limit and member collection |
| `Report.HtmlPartitioned`, `HtmlRowsPerPart`, `HtmlMaxRelations` | Legacy partitioning, part size and preview length only |

**Accepted domain difference:** inventory runs are immutable full snapshots, not Purview's incrementally
updated event-history database. `Storage.DatabasePath` therefore yields
`<database parent>\run_<stamp>\<database filename>` for each new run; it never overwrites a snapshot.
`-DatabasePath` overrides that prototype. `-ResumeRun` accepts the actual database or its folder;
legacy `inventory.sqlite` runs remain supported.

`-WorkDir` is a compatibility override: it places snapshots, reports and logs together in
`<WorkDir>\run_<stamp>`. Explicit `-DatabasePath`, `-OutputPath` and `-LogPath` take precedence for
their corresponding paths. `-OutName` overrides `FilePrefix`. The former config-relative paths,
`Storage.WorkDirectory`, `Report.Format` and `Report.OutputName` are migrated to the explicit keys.
Do not use the removed keys in a custom configuration.

<!-- icon: key -->
## 3. Authentication and permissions

Choose `Authentication.Mode` (or `-AuthMode`) explicitly:

* **Certificate (preferred):** configure `Tenant.TenantId`, `Authentication.AppId` and
  `CertificateThumbprint`. The certificate must be currently valid and contain an RSA private key
  in `Cert:\CurrentUser\My` or `Cert:\LocalMachine\My`; register its matching public certificate
  on that App Registration. A certificate from another app cannot authenticate this AppId.
  JWT assertions expire after five minutes. No secret or private key is placed on the command line or exported.
* **ClientSecretFile:** the compatibility/lab mode, with an external protected JSON file containing
  `TenantId`, `ClientId` and `ClientSecret`. `Authentication.CredentialsPath` or `-CredFile` references
  the file; it is never copied into runs, packages or the engine. Protect it with user-only NTFS ACLs.
  Configured tenant/application identities must match the file.
  Prefer a location outside the tool folder. The exact compatibility name `app_creds.json` and
  the collector's default `siteurls.csv` are mutable inputs, never hashed code or distributed assets.
* **ClientSecretEnvironment:** another compatibility/lab mode; configure tenant/application IDs and an environment variable named by
  `Authentication.SecretEnvironmentVariable` (default `M365_GROUPS_CLIENT_SECRET`). Provision it through
  a protected process environment, not through a literal command in shell history.

After token acquisition, a snapshot is bound to its authenticated collection tenant. Another tenant
is rejected on collection/resume and offline reporting. Existing legacy snapshots remain compatible:
unbound offline reports label tenant information as configuration-only, and first authenticated
binding of a legacy snapshot retains an explicit historical-attribution warning. Tenant IDs are
nonsecret provenance metadata; app secrets and access tokens are never stored.

**Accepted domain difference:** Graph app-only inventory is not Security & Compliance PowerShell.
Purview's `Interactive`/`Certificate` IPPS model cannot be reused verbatim. Certificate is preferred;
the explicit external-secret modes and default file configuration preserve the existing Graph lab path.
The app needs admin-consented Graph application permissions for groups and their owners/members
(normally `Group.Read.All` and `User.Read.All`, or equivalent least-privilege permissions validated
for the directory object types actually returned). SharePoint collection uses its own delegated admin sign-in.

`-ClientSecret` is deprecated compatibility only. It disables the transcript so the invocation cannot
be captured; fixed lifecycle diagnostics are still written. Do not use it for scheduled tasks.
OAuth response bodies and malformed credentials-file details are suppressed. Credentials and tokens
are cleared from script variables at cleanup; the engine receives no authentication material.
Caller-owned transcripts, shell history, process arguments and debug traces are outside the tool's control.

<!-- icon: flow -->
## 4. Collection, resume and retention

```steps
Stage sites | Stream the SharePoint CSV; reject an empty or malformed source.
Enumerate groups | Checkpoint each Graph page; resume from its cursor or restart with de-duplication.
Collect lists | Parallel Graph batches feed one bounded SQLite writer; retry throttling and authentication.
Reconcile and seal | Require every source/list and stored count to reconcile before any final export.
Export and retain | Atomically promote verified files; close engine/transcript, then apply retention after success.
```

HTTP 404 is a confirmed delete only after a direct group re-check. Failed or interrupted lists are
not reported as empty. `-SkipMembers` produces an uncollected/null member count, never a false zero.
Resume keeps completed lists; interrupted lists restart from their first page.
A sealed run is re-exported without credentials. Existing exports require `-OverwriteExport`.

Retention uses validated SQLite **sealed state and seal time**, not export filenames or directory
timestamps. It never deletes active/locked, incomplete, unreadable, corrupt or reparse-point runs.
It preserves the latest completed snapshot even when idle beyond retention. The current execution
is excluded. A second exclusive writer-compatible lock is taken before removal.
Logs are aged by each `.log` file's timestamp, not folder age; active logs and incomplete-run logs are
preserved. Log retention is independently callable/testable. `-NoRetention` skips both policies.
Report directories have no implicit destructive retention; protect/delete exports deliberately.

<!-- icon: chart -->
## 5. CSV and HTML

CSV contains 12 quoted fields, UTF-8 BOM, CRLF, configured delimiter and complete `;`-joined relation
lists. Formula-shaped values are neutralized unless `-RawCsvValues` is deliberately selected.
HTML filtered CSV obeys the same delimiter/guard, column order and relation representation.
Treat all snapshots and exports as tenant data.

HTML is one self-contained file by default. Gzip/base64 chunks are decoded progressively with
`DecompressionStream`; no external script, font, image or network call is required.
Chunk-local relation dictionaries are merged into browser-global dictionaries; typed filter masks
avoid lowercasing every repeated owner/member for every filter pass.
Display name, alias, SMTP, type, site URL, visibility, owner, member, count and ownerless filters
remain inventory-specific. The Purview theme's full variables, decorative header, metric icons,
filtered summary, member-count distribution, top-ten ranking, filters card, grid, overlay, details
dialog, focus and responsive styling are retained. Uncollected member counts are excluded from rankings.
`-HtmlMaxRelations` limits only the preview; complete relations remain filterable and exportable.
Only viewport rows appear in the DOM. `-HtmlPartitioned` opts into the legacy multi-file layout.

<!-- icon: beaker -->
## 6. Development and validation

Canonical engine sources live in `src`, tests in `tests`, configuration in `config`, template in
`templates`, and documentation/packaging helpers in `tools`. Root PowerShell entry points and root
Pester files are compatibility entry points. `engine\GroupInventory.Engine.csproj` and `engine\bin`
remain the existing offline development build path; packages relocate the compiled runtime to
`lib\engine` and exclude every `bin` directory.

```powershell
.\Build-Engine.ps1
Invoke-Pester -Path .\tests\Invoke-M365GroupsReporting.Tests.ps1,.\tests\GroupInventory.Engine.Tests.ps1,.\tests\M365GroupsReporting.Parity.Tests.ps1
$env:GROUP_INVENTORY_BENCH_OBJECTS = 400000
Invoke-Pester -Path .\tests\GroupInventory.Engine.Tests.ps1
.\tools\Build-Documentation.ps1
.\tools\New-GroupInventoryPackage.ps1 -Stage Prepare -Destination C:\ReviewedArtifacts\M365GroupsReporting-1.0.0
```

Tests are offline, synthetic and use existing Pester tooling. Never point validation at tenant runs.
The large benchmark creates 20,000 groups, 40,000 owners and 340,000 members with 32 producers.

<!-- icon: shield -->
## 7. Safe delivery and remaining qualifications

The package helper uses only allow-listed runtime files and includes this generated HTML guide and
third-party notices. It sanitizes tenant IDs/domains, SharePoint URL, app/certificate identities,
company/environment values, output/storage/log paths and branding. Tenant display resets to false.
All text is scanned for original tenant/branding values, literal secrets, JWTs and private keys.
The destination must be outside the source and not its ancestor; junction/symlink paths are refused.
Executed destinations, databases, run/data/report/log/bin folders and unknown destinations cannot be
replaced with `-Force`. Failed scanning does not change an existing package. The package builder never publishes.

Offline synthetic tests do not qualify certificate or environment-secret authentication at full-tenant
scale. Tenant qualification evidence, credentials, certificate stores and lab overrides are private and
outside the public repository and package.
The interactive SharePoint path remains lab-only; snapshot semantics and inventory-specific fields
are accepted domain differences, not omissions of the Purview baseline.

### Signed package integrity

The source layout remains at the root to preserve build procedures. A Git checkout is explicitly
**source development**, not an authenticated runtime distribution. Use `-SourceDevelopment` only in
that checkout; packaged artifacts reject it. Source engine output is deliberately unauthenticated,
and must never be substituted for a signed release.

The independently signed `Test-PackageIntegrity.ps1` uses the public Purview verifier's trust pattern:
valid timestamped owner signature, trusted signer `0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6`,
authentication of the raw PSD1 before parsing, an exact allow-listed inventory, raw SHA256 hashes,
script-signature checks and rejection of protected reparse points or unexpected stable files.
Both entry points verify before business logic; the engine loader verifies again before assembly load.
Vendor DLLs keep their original bytes and authorship; manifest authentication protects the actual
compiled `lib\engine\GroupInventory.Engine.dll`, SQLite managed/native dependencies and templates.
README, license, third-party notices, guides and named public images are also immutable.

Only `config\M365GroupsReporting.config.psd1` is excluded from the immutable inventory. Runtime
`data`, `logs`, `reports` and the execution marker are not loaded as code. Source, CI, tests, labs,
credentials, databases, logs, backups and SDK intermediates are not packaged.

**Signing preparation is not successful authentication.** The source manifest describes source
paths and is regenerated after source bytes are frozen; it is never copied into a relocated package.
The package manifest is created from the actual staged runtime bytes after configuration sanitization
and DLL/template copying. The owner must approve and sign the exact staged scripts first:

```powershell
.\tools\New-GroupInventoryPackage.ps1 -Stage Prepare -Destination C:\ReviewedArtifacts\M365GroupsReporting-1.0.0
# Owner approval, exact script signing and timestamping happen separately.
.\tools\New-GroupInventoryPackage.ps1 -Stage RefreshManifest -Destination C:\ReviewedArtifacts\M365GroupsReporting-1.0.0
# Owner signs and timestamps the newly generated manifest separately.
.\tools\New-GroupInventoryPackage.ps1 -Stage Finalize -Destination C:\ReviewedArtifacts\M365GroupsReporting-1.0.0
```

RefreshManifest requires trusted timestamped script signatures. Finalize independently authenticates
the manifest and all package bytes before removing `.publication-pending`. Pending artifacts cannot
run. There is no unsigned production fallback, signature bypass or automatic trust-root import.
Chain/revocation validation may need issuer services; an unavailable trusted chain blocks delivery.
Do not edit immutable files after manifest generation or signing. Certificate rotation requires owner
review of every pinned trust boundary and a new version; never replace published assets.

Raw Git blobs must be checked independently after the owner freezes signed source bytes. Local native
signature checks, offline mocks, rendered visual approval, hosted CI and live GitHub security settings
are separate gates. This candidate does not claim that any pending gate has passed.

<!-- icon: info -->
## Disclaimer

This Script is a Personal project.
It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
