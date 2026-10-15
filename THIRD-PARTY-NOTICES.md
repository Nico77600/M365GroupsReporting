# Third-party components

The bundled SQLite binaries are unmodified local runtime dependencies.
Development uses `lib\sqlite`; delivery packages use `lib\engine`.

| Component | Version | License |
| --- | --- | --- |
| Microsoft.Data.Sqlite.Core | 10.0.12 | MIT: https://github.com/dotnet/efcore/blob/main/LICENSE.txt |
| SQLitePCLRaw.core | 2.1.12 | Apache-2.0: https://github.com/ericsink/SQLitePCL.raw/blob/master/LICENSE.TXT |
| SQLitePCLRaw.provider.e_sqlite3 | 2.1.12 | Apache-2.0 |
| SQLitePCLRaw.bundle_e_sqlite3 | 2.1.12 | Apache-2.0 |
| SQLitePCLRaw.lib.e_sqlite3 | 2.1.12 | Apache-2.0 (packaging); SQLite is public domain: https://sqlite.org/copyright.html |

Native runtimes: Windows x64 and arm64. The Group Inventory engine and template are
local product components, not downloaded dependencies. Packages include no database.
