# M365 Groups Reporting

**By Nicolas Fabert** · Version 1.0.0

Read-only Microsoft 365 groups, owners, members and SharePoint URLs, collected into a restartable SQLite snapshot and exported as CSV and self-contained HTML.

## Requirements

- Windows and **PowerShell 7.4+**; Windows PowerShell 5.1 is not an inventory runtime.
- An application with consented Graph read permissions; certificate authentication is preferred.
- SharePoint `GroupId,Url` CSV, or a separate SharePoint administrator session with Windows PowerShell 5.1 and `Microsoft.Online.SharePoint.PowerShell`.
- Bundled .NET 8 engine and original SQLite binaries; no SDK is needed to run this package.

## Quick start

Review the publisher and trusted chain before unblocking downloaded files. Follow organizational execution policy; never disable signature or integrity checks.

```powershell
Get-ChildItem . -Recurse -File -Force | Unblock-File
notepad .\config\M365GroupsReporting.config.psd1
.\Invoke-M365GroupsReporting.ps1 -SiteUrlsCsv C:\InventoryInput\siteurls.csv
.\Invoke-M365GroupsReporting.ps1 -ResumeRun .\data\run_YYYYMMDD_HHMMSS -NoRetention
```

Edit only `config\M365GroupsReporting.config.psd1` among the distributed files. Keep secrets external. Tenant/environment display is off by default. A skipped members list is *not collected*, not zero. Final files are produced only after required sources and lists reconcile and the snapshot seals.

### Signed package integrity

The two entry scripts, verifier and manifest require valid, timestamped Nicolas Fabert signatures. Expected signer: `0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6`.

Before business logic, assembly loading or native SQLite loading, the independently signed verifier authenticates the raw manifest and its fixed inventory of stable files: the engine DLL, managed/native dependencies, both templates, guides, this README, license, notices and named images. Missing or changed bytes, untrusted signers, absent timestamps, unexpected stable files and reparse points fail closed. A signed manifest copied from the source layout is not a package manifest.

`.publication-pending` is an unsigned preparation artifact and **cannot run**. There is no unsigned production fallback. `-SourceDevelopment` is for an actual source Git checkout only and is rejected here. Chain/revocation checks may require issuer connectivity; an unavailable trusted chain is a blocking failure.

## Content

| Item | Role |
|---|---|
| `Invoke-M365GroupsReporting.ps1` | PowerShell 7 inventory entry |
| `Get-SiteUrls.ps1` | Optional SharePoint CSV collector |
| `Test-PackageIntegrity.ps1` | Independently authenticated verifier |
| `M365GroupsReporting.PackageIntegrity.psd1` | Signed raw SHA256 inventory of this exact runtime layout |
| `config\` | Editable configuration; excluded from immutable hashes |
| `lib\engine\` | Compiled engine, original SQLite dependencies and engine template |
| `templates\` | Report template |
| `docs\` | Administrator/developer guide and synthetic public previews |
| `README.md`, `LICENSE`, `THIRD-PARTY-NOTICES.md` | Runtime documentation and license notices |

Runtime outputs `data`, `logs`, `reports` and `.M365GroupsReporting.executed` are not trusted executable code. Source/build/CI/tests, tenant outputs, lab files, credentials, backups and SDK intermediates are never packaged.

The exact root input names `siteurls.csv` and `app_creds.json` are also mutable data, not hashed executable authority. This preserves the collector's default CSV location and the compatibility credential-file path; prefer a protected credentials file outside the tool folder. No other code or documentation name is exempt.

## Documentation

- [Administrator and developer guide](docs/GroupInventory-Guide.md)
- Self-contained [HTML guide](docs/GroupInventory-Guide.html), with light/dark themes and navigation
- Project, releases and change log: https://github.com/Nico77600/M365GroupsReporting
- [MIT license](LICENSE) and [third-party notices](THIRD-PARTY-NOTICES.md)

## Disclaimer

This Script is a Personal project.
It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
