// =============================================================================
//  Group Inventory engine, part 4: streaming exports (CSV and HTML only)
// -----------------------------------------------------------------------------
//  - Exports are refused unless the run is sealed (complete and reconciled) and its integrity
//    checks pass; the group count is compared with the value recorded when the run was sealed.
//  - Rows are streamed from a read-only SQLite connection straight to the output writer: no
//    row list and no per-group relation string is ever built in memory.
//  - Output is written to a temporary name next to the target, flushed to disk, verified
//    (row count, relation counts) and only then moved into place: a failed export never leaves
//    a partial final file. HTML publishes its parts folder first and the index file last.
//  - CSV: UTF-8 with BOM, CRLF, every field quoted, 12 columns (same as the previous releases).
//    Values that a spreadsheet could interpret as a formula (= + - @ TAB) get a leading
//    apostrophe unless NeutralizeFormulas is disabled.
//  - HTML: self-contained, no external resource, partitioned in files of HtmlRowsPerPart rows;
//    complete rows are gzip-compressed into browser chunks. The template provides filtering,
//    sorting, virtual scrolling, details and filtered CSV export. Relation cells only preview
//    HtmlMaxRelationsPerCell values; the embedded data remains complete.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace GroupInventory.Engine
{
    /// <summary>Read-only access to a run database (never takes the write lock, never writes).</summary>
    internal sealed class ReadOnlyDb : IDisposable
    {
        SqliteConnection _db;
        public string State { get; private set; }
        public bool SkipMembers { get; private set; }

        public static ReadOnlyDb Open(string path, bool requireSealed)
        {
            if (!File.Exists(path)) throw new EngineException("The inventory database does not exist: " + Path.GetFileName(path));
            SqliteRuntime.EnsureInitialized();
            var r = new ReadOnlyDb();
            try { r.Init(path, requireSealed); }
            catch { r.Dispose(); throw; }
            return r;
        }

        void Init(string path, bool requireSealed)
        {
            var b = new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadOnly, Cache = SqliteCacheMode.Private, Pooling = false };
            _db = new SqliteConnection(b.ToString());
            try
            {
                _db.Open();
                Exec("PRAGMA query_only=1;");
                if (Convert.ToInt64(Scalar("PRAGMA application_id;"), CultureInfo.InvariantCulture) != EngineInfo.ApplicationId)
                    throw new IncompatibleDatabaseException("The file is not a Group Inventory run database.");
                long uv = Convert.ToInt64(Scalar("PRAGMA user_version;"), CultureInfo.InvariantCulture);
                if (uv != EngineInfo.SchemaVersion) throw new IncompatibleDatabaseException("Unsupported schema version " + uv.ToString(CultureInfo.InvariantCulture) + ".");
                State = Meta("state");
                SkipMembers = Meta("skip_members") == "1";
            }
            catch (SqliteException e) { throw new IncompatibleDatabaseException("The inventory database could not be read (code " + e.SqliteErrorCode.ToString(CultureInfo.InvariantCulture) + ").", e); }
            if (requireSealed)
            {
                if (State != EngineInfo.StateSealed) throw new RunStateException("Export refused: the run is not sealed (state '" + State + "'). Complete the collection and seal the run first.");
                string qc = Convert.ToString(Scalar("PRAGMA quick_check;"), CultureInfo.InvariantCulture);
                if (qc != "ok") throw new IncompatibleDatabaseException("Export refused: integrity check failed: " + Text.Truncate(qc, 200));
                using (var c = _db.CreateCommand())
                {
                    c.CommandText = "PRAGMA foreign_key_check;";
                    using (var rd = c.ExecuteReader()) if (rd.Read()) throw new IncompatibleDatabaseException("Export refused: foreign key check failed.");
                }
                long groups = Convert.ToInt64(Scalar("SELECT COUNT(*) FROM grp;"), CultureInfo.InvariantCulture);
                long entries = Convert.ToInt64(Scalar("SELECT COUNT(*) FROM list_entry;"), CultureInfo.InvariantCulture);
                if (Meta("sealed_groups") != groups.ToString(CultureInfo.InvariantCulture) || Meta("sealed_entries") != entries.ToString(CultureInfo.InvariantCulture))
                    throw new IncompatibleDatabaseException("Export refused: the database content no longer matches the sealed totals.");
            }
        }

        void Exec(string sql) { using (var c = _db.CreateCommand()) { c.CommandText = sql; c.ExecuteNonQuery(); } }
        object Scalar(string sql) { using (var c = _db.CreateCommand()) { c.CommandText = sql; return c.ExecuteScalar(); } }
        public string Meta(string key)
        {
            using (var c = _db.CreateCommand())
            {
                c.CommandText = "SELECT value FROM engine_meta WHERE key=@k;";
                c.Parameters.AddWithValue("@k", key);
                return Convert.ToString(c.ExecuteScalar(), CultureInfo.InvariantCulture) ?? "";
            }
        }
        public long SealedGroups { get { return long.Parse(Meta("sealed_groups"), CultureInfo.InvariantCulture); } }

        public FlowInfo GetFlow(string name)
        {
            using (var c = _db.CreateCommand())
            {
                c.CommandText = "SELECT state,pass,next_page,rows_seen,dup_count,cursor,message FROM flow WHERE name=@n;";
                c.Parameters.AddWithValue("@n", name);
                using (var r = c.ExecuteReader())
                {
                    if (!r.Read()) return new FlowInfo { Name = name, State = "Unknown" };
                    return new FlowInfo { Name = name, State = ((FlowState)r.GetInt64(0)).ToString(), Pass = r.GetInt64(1), NextPage = r.GetInt64(2), RowsSeen = r.GetInt64(3), Duplicates = r.GetInt64(4), Cursor = r.GetString(5), Message = r.GetString(6) };
                }
            }
        }

        public RunInfo Info()
        {
            return new RunInfo
            {
                RunId = Meta("run_id"), State = State, SkipMembers = SkipMembers, SitesRequired = Meta("sites_required") == "1",
                SchemaVersion = EngineInfo.SchemaVersion, ProtocolVersion = EngineInfo.ProtocolVersion, SqliteVersion = Meta("sqlite_version"),
                Groups = Convert.ToInt64(Scalar("SELECT COUNT(*) FROM grp;"), CultureInfo.InvariantCulture),
                GroupsRemoved = Convert.ToInt64(Scalar("SELECT COUNT(*) FROM removed_group;"), CultureInfo.InvariantCulture),
                CreatedUtc = Meta("created_utc"), SealedUtc = Meta("sealed_utc"),
                TenantId = Meta("tenant_id"), LegacyTenantHistoryUnverified = Meta("legacy_tenant_history_unverified") == "1",
                Enum = GetFlow(EngineInfo.FlowEnum), Sites = GetFlow(EngineInfo.FlowSites)
            };
        }

        public GroupCursor Groups() { return new GroupCursor(_db, SkipMembers); }

        public void Dispose() { if (_db != null) { _db.Dispose(); _db = null; } }
    }

    /// <summary>Forward-only cursor over the groups (ordered by group id) and their relation entries.</summary>
    internal sealed class GroupCursor : IDisposable
    {
        readonly SqliteCommand _heads, _entries, _entriesLimited;
        readonly SqliteDataReader _rd;
        readonly bool _skip;
        public string Id, DisplayName, Alias, Mail, Visibility, SiteUrl;
        public bool IsTeam;
        public long Gid, OwnersCount, MembersCount; // MembersCount = -1: not collected

        public GroupCursor(SqliteConnection db, bool skip)
        {
            _skip = skip;
            _heads = db.CreateCommand();
            _heads.CommandText =
                "SELECT g.gid,g.group_id,g.display_name,g.alias,g.mail,g.visibility,g.is_team,s.url,o.state,o.stored_count,m.state,m.stored_count " +
                "FROM grp g JOIN list_stream o ON o.gid=g.gid AND o.kind=1 JOIN list_stream m ON m.gid=g.gid AND m.kind=2 " +
                "LEFT JOIN site_url s ON s.group_id=g.group_id ORDER BY g.group_id;";
            _entries = db.CreateCommand();
            _entries.CommandText = "SELECT display_value FROM list_entry WHERE gid=@g AND kind=@k ORDER BY entry_id;";
            _entries.Parameters.Add("@g", SqliteType.Integer); _entries.Parameters.Add("@k", SqliteType.Integer);
            _entriesLimited = db.CreateCommand();
            _entriesLimited.CommandText = "SELECT display_value FROM list_entry WHERE gid=@g AND kind=@k ORDER BY entry_id LIMIT @n;";
            _entriesLimited.Parameters.Add("@g", SqliteType.Integer); _entriesLimited.Parameters.Add("@k", SqliteType.Integer); _entriesLimited.Parameters.Add("@n", SqliteType.Integer);
            _rd = _heads.ExecuteReader();
        }

        public bool Next()
        {
            if (!_rd.Read()) return false;
            Gid = _rd.GetInt64(0); Id = _rd.GetString(1); DisplayName = _rd.GetString(2); Alias = _rd.GetString(3); Mail = _rd.GetString(4);
            Visibility = _rd.GetString(5); IsTeam = _rd.GetInt64(6) == 1; SiteUrl = _rd.IsDBNull(7) ? "" : _rd.GetString(7);
            long os = _rd.GetInt64(8), ms = _rd.GetInt64(10);
            if (os != (long)FlowState.Complete || !(ms == (long)FlowState.Complete || (_skip && ms == (long)FlowState.Skipped)))
                throw new EngineException("Export integrity failure: group " + Id + " has an incomplete list.");
            OwnersCount = _rd.GetInt64(9);
            MembersCount = ms == (long)FlowState.Skipped ? -1 : _rd.GetInt64(11);
            return true;
        }

        public string GroupType { get { return IsTeam ? "Teams" : (SiteUrl.Length == 0 ? "Classic" : "SharePoint"); } }

        /// <summary>Streams up to limit values (0 = all) of a relation to the sink; returns how many were read.</summary>
        public long ReadEntries(int kind, long limit, Action<string> sink)
        {
            var c = limit > 0 ? _entriesLimited : _entries;
            c.Parameters["@g"].Value = Gid; c.Parameters["@k"].Value = kind;
            if (limit > 0) c.Parameters["@n"].Value = limit;
            long n = 0;
            using (var r = c.ExecuteReader())
                while (r.Read()) { sink(r.GetString(0)); n++; }
            return n;
        }

        public void Dispose()
        {
            _rd.Dispose(); _heads.Dispose(); _entries.Dispose(); _entriesLimited.Dispose();
        }
    }

    public sealed partial class InventoryEngine
    {
        static readonly string[] Columns = { "displayName", "alias", "primarySmtpAddress", "groupType", "sharePointUrl", "visibility", "externalDirectoryObjectId", "owners", "members", "ownersCount", "membersCount", "ownerless" };

        static bool IsFormulaStart(char c) { return c == '=' || c == '+' || c == '-' || c == '@' || c == '\t' || c == '\r'; }

        static string Num(long n) { return n.ToString(CultureInfo.InvariantCulture); }

        sealed class CsvCtx
        {
            public TextWriter W;
            public bool Guard;
            public long Neutralized;
        }

        static void WriteCsvEscaped(TextWriter w, string s)
        {
            if (s.IndexOf('"') < 0) { w.Write(s); return; }
            w.Write(s.Replace("\"", "\"\""));
        }

        static void WriteCsvText(CsvCtx x, string s)
        {
            x.W.Write('"');
            if (x.Guard && s.Length > 0 && IsFormulaStart(s[0])) { x.W.Write('\''); x.Neutralized++; }
            WriteCsvEscaped(x.W, s);
            x.W.Write('"');
        }

        static string Sha256File(string path)
        {
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.SequentialScan))
            using (var sha = SHA256.Create())
            {
                byte[] d = sha.ComputeHash(fs);
                var sb = new StringBuilder(d.Length * 2);
                foreach (byte b in d) sb.Append(b.ToString("x2", CultureInfo.InvariantCulture));
                return sb.ToString();
            }
        }

        static void SyncedClose(StreamWriter w, FileStream fs)
        {
            w.Flush();
            fs.Flush(true);
            w.Dispose();
        }

        static string RequireTarget(ExportOptions o, string extension)
        {
            if (o == null) throw new ProtocolException("ExportOptions is required.");
            if (string.IsNullOrWhiteSpace(o.Path)) throw new ProtocolException("ExportOptions.Path is required.");
            string full = Path.GetFullPath(o.Path);
            if (!string.Equals(Path.GetExtension(full), extension, StringComparison.OrdinalIgnoreCase))
                throw new ProtocolException("The output file must have the " + extension + " extension (only CSV and HTML exports exist).");
            string dir = Path.GetDirectoryName(full);
            if (!Directory.Exists(dir)) throw new EngineException("The output folder does not exist.");
            return full;
        }

        /// <summary>Streams the sealed inventory to a CSV file (12 columns). Refused unless the run is sealed and intact.</summary>
        public ExportResult ExportCsv(ExportOptions o)
        {
            string target = RequireTarget(o, ".csv");
            if (o.CsvDelimiter != "," && o.CsvDelimiter != ";" && o.CsvDelimiter != "|" && o.CsvDelimiter != "\t")
                throw new ProtocolException("CsvDelimiter must be a comma, semicolon, pipe or tab.");
            if (string.Equals(target, _dbPath, StringComparison.OrdinalIgnoreCase)) throw new ProtocolException("The output path is the inventory database.");
            if (File.Exists(target) && !o.Overwrite) throw new EngineException("The output file already exists (set Overwrite to replace it): " + Path.GetFileName(target));
            string tmp = Path.Combine(Path.GetDirectoryName(target), "." + Path.GetFileName(target) + "." + Guid.NewGuid().ToString("N") + ".tmp");
            var res = new ExportResult { Path = target, Format = "CSV" };
            try
            {
                using (var db = ReadOnlyDb.Open(_dbPath, true))
                {
                    res.RowsTotal = db.SealedGroups;
                    var fs = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.SequentialScan);
                    var w = new StreamWriter(fs, new UTF8Encoding(true), 65536);
                    var x = new CsvCtx { W = w, Guard = o.NeutralizeFormulas };
                    try
                    {
                        for (int i = 0; i < Columns.Length; i++) { if (i > 0) w.Write(o.CsvDelimiter); w.Write('"'); w.Write(Columns[i]); w.Write('"'); }
                        w.Write("\r\n");
                        using (var g = db.Groups())
                            while (g.Next())
                            {
                                WriteCsvText(x, g.DisplayName); w.Write(o.CsvDelimiter);
                                WriteCsvText(x, g.Alias); w.Write(o.CsvDelimiter);
                                WriteCsvText(x, g.Mail); w.Write(o.CsvDelimiter);
                                WriteCsvText(x, g.GroupType); w.Write(o.CsvDelimiter);
                                WriteCsvText(x, g.SiteUrl); w.Write(o.CsvDelimiter);
                                WriteCsvText(x, g.Visibility); w.Write(o.CsvDelimiter);
                                WriteCsvText(x, g.Id); w.Write(o.CsvDelimiter);
                                WriteCsvRelation(x, g, (int)ListKind.Owners, g.OwnersCount); w.Write(o.CsvDelimiter);
                                if (g.MembersCount < 0) w.Write("\"\""); else WriteCsvRelation(x, g, (int)ListKind.Members, g.MembersCount);
                                w.Write(o.CsvDelimiter);
                                WriteCsvText(x, Num(g.OwnersCount)); w.Write(o.CsvDelimiter);
                                WriteCsvText(x, g.MembersCount < 0 ? "" : Num(g.MembersCount)); w.Write(o.CsvDelimiter);
                                WriteCsvText(x, g.OwnersCount == 0 ? "Yes" : "No");
                                w.Write("\r\n");
                                res.RowsWritten++;
                            }
                        SyncedClose(w, fs);
                    }
                    catch { w.Dispose(); throw; }
                    res.FormulaNeutralized = x.Neutralized;
                }
                if (res.RowsWritten != res.RowsTotal) throw new EngineException("Export integrity failure: " + Num(res.RowsWritten) + " rows written, " + Num(res.RowsTotal) + " groups sealed.");
                res.Bytes = new FileInfo(tmp).Length;
                res.Sha256 = Sha256File(tmp);
                if (File.Exists(target) && !o.Overwrite) throw new EngineException("The output file appeared during the export: " + Path.GetFileName(target));
                File.Move(tmp, target, o.Overwrite);
                res.Parts = 1;
                return res;
            }
            catch
            {
                try { if (File.Exists(tmp)) File.Delete(tmp); } catch (IOException) { } catch (UnauthorizedAccessException) { }
                throw;
            }
        }

        static void WriteCsvRelation(CsvCtx x, GroupCursor g, int kind, long expected)
        {
            x.W.Write('"');
            bool first = true;
            long n = g.ReadEntries(kind, 0, v =>
            {
                if (!first) x.W.Write(';');
                else if (x.Guard && v.Length > 0 && IsFormulaStart(v[0])) { x.W.Write('\''); x.Neutralized++; }
                WriteCsvEscaped(x.W, v);
                first = false;
            });
            x.W.Write('"');
            if (n != expected) throw new EngineException("Export integrity failure: group " + g.Id + " has " + Num(n) + " stored relations, " + Num(expected) + " expected.");
        }

        static void HtmlEnc(TextWriter w, string s)
        {
            int start = 0;
            for (int i = 0; i < s.Length; i++)
            {
                string rep = null;
                switch (s[i])
                {
                    case '&': rep = "&amp;"; break;
                    case '<': rep = "&lt;"; break;
                    case '>': rep = "&gt;"; break;
                    case '"': rep = "&quot;"; break;
                    case '\'': rep = "&#39;"; break;
                }
                if (rep == null) continue;
                if (i > start) w.Write(s.Substring(start, i - start));
                w.Write(rep);
                start = i + 1;
            }
            if (start < s.Length) w.Write(start == 0 ? s : s.Substring(start));
        }

        const string HtmlStyle = "body{font-family:Segoe UI,Arial,sans-serif;font-size:12px;margin:16px}h1{color:#22356f;font-size:18px}table{border-collapse:collapse;width:100%}" +
                                 "th{background:#22356f;color:#fff;padding:6px;text-align:left;position:sticky;top:0}td{border:1px solid #ddd;padding:5px;vertical-align:top;word-break:break-word}" +
                                 "tr:nth-child(even){background:#f5f7fb}.more{color:#777;font-style:italic}nav a{margin-right:12px}";

        static void HtmlHead(TextWriter w, string title)
        {
            w.Write("<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">");
            w.Write("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\">");
            w.Write("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>");
            HtmlEnc(w, title);
            w.Write("</title><style>" + HtmlStyle + "</style></head><body>");
        }

        static readonly JsonSerializerOptions HtmlJsonOptions = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase
        };

        sealed class HtmlTemplate
        {
            public string BeforeChunks, BetweenChunksAndMeta, AfterMeta;
        }

        sealed class HtmlGroupRow
        {
            public string DisplayName { get; set; }
            public string Alias { get; set; }
            public string PrimarySmtpAddress { get; set; }
            public string GroupType { get; set; }
            public string SharePointUrl { get; set; }
            public string Visibility { get; set; }
            public string ExternalDirectoryObjectId { get; set; }
            public List<string> Owners { get; set; }
            public List<string> Members { get; set; }
            public long OwnersCount { get; set; }
            public long? MembersCount { get; set; }
            public bool Ownerless { get; set; }
        }

        static HtmlTemplate LoadHtmlTemplate(ExportOptions o)
        {
            string path = string.IsNullOrWhiteSpace(o.HtmlTemplatePath)
                ? Path.Combine(Path.GetDirectoryName(typeof(InventoryEngine).Assembly.Location) ?? AppContext.BaseDirectory, "GroupInventory.template.html")
                : Path.GetFullPath(o.HtmlTemplatePath);
            if (!File.Exists(path)) throw new EngineException("The Group Inventory HTML template was not found: " + path);
            string text = File.ReadAllText(path, Encoding.UTF8);
            const string chunks = "%%GROUP_CHUNKS%%";
            const string meta = "%%GROUP_META%%";
            int a = text.IndexOf(chunks, StringComparison.Ordinal);
            int b = text.IndexOf(meta, StringComparison.Ordinal);
            if (a < 0 || b < a || a != text.LastIndexOf(chunks, StringComparison.Ordinal) || b != text.LastIndexOf(meta, StringComparison.Ordinal))
                throw new EngineException("The Group Inventory HTML template must contain %%GROUP_CHUNKS%% then %%GROUP_META%% exactly once: " + path);
            return new HtmlTemplate
            {
                BeforeChunks = text.Substring(0, a),
                BetweenChunksAndMeta = text.Substring(a + chunks.Length, b - a - chunks.Length),
                AfterMeta = text.Substring(b + meta.Length)
            };
        }

        sealed class HtmlPartWriter : IDisposable
        {
            readonly StreamWriter _writer;
            readonly FileStream _file;
            readonly HtmlTemplate _template;
            readonly ExportOptions _options;
            readonly List<HtmlGroupRow> _rows = new List<HtmlGroupRow>();
            long _chunks;
            bool _closed;

            public HtmlPartWriter(string path, HtmlTemplate template, ExportOptions options)
            {
                _template = template;
                _options = options;
                _file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.SequentialScan);
                _writer = new StreamWriter(_file, new UTF8Encoding(false), 65536);
                _writer.Write(template.BeforeChunks);
            }

            public void Add(GroupCursor g)
            {
                var row = new HtmlGroupRow
                {
                    DisplayName = g.DisplayName,
                    Alias = g.Alias,
                    PrimarySmtpAddress = g.Mail,
                    GroupType = g.GroupType,
                    SharePointUrl = g.SiteUrl,
                    Visibility = g.Visibility,
                    ExternalDirectoryObjectId = g.Id,
                    Owners = new List<string>(),
                    Members = new List<string>(),
                    OwnersCount = g.OwnersCount,
                    MembersCount = g.MembersCount < 0 ? (long?)null : g.MembersCount,
                    Ownerless = g.OwnersCount == 0
                };
                long owners = g.ReadEntries((int)ListKind.Owners, 0, row.Owners.Add);
                if (owners != g.OwnersCount)
                    throw new EngineException("Export integrity failure: group " + g.Id + " has " + Num(owners) + " readable owners, " + Num(g.OwnersCount) + " expected.");
                if (g.MembersCount >= 0)
                {
                    long members = g.ReadEntries((int)ListKind.Members, 0, row.Members.Add);
                    if (members != g.MembersCount)
                        throw new EngineException("Export integrity failure: group " + g.Id + " has " + Num(members) + " readable members, " + Num(g.MembersCount) + " expected.");
                }
                _rows.Add(row);
                if (_rows.Count >= _options.HtmlChunkRows) FlushChunk();
            }

            void FlushChunk()
            {
                if (_rows.Count == 0) return;
                var people = new List<string>();
                var dictionary = new Dictionary<string, int>(StringComparer.Ordinal);
                Func<List<string>, int[]> pack = values =>
                {
                    var ids = new int[values.Count];
                    for (int i = 0; i < values.Count; i++)
                    {
                        int id;
                        if (!dictionary.TryGetValue(values[i], out id))
                        {
                            id = people.Count;
                            dictionary.Add(values[i], id);
                            people.Add(values[i]);
                        }
                        ids[i] = id;
                    }
                    return ids;
                };
                var packed = new List<object>(_rows.Count);
                foreach (var row in _rows)
                    packed.Add(new
                    {
                        row.DisplayName, row.Alias, row.PrimarySmtpAddress, row.GroupType,
                        row.SharePointUrl, row.Visibility, row.ExternalDirectoryObjectId,
                        Owners = pack(row.Owners), Members = pack(row.Members),
                        row.OwnersCount, row.MembersCount, row.Ownerless
                    });
                byte[] json = JsonSerializer.SerializeToUtf8Bytes(new { version = 2, people, rows = packed }, HtmlJsonOptions);
                using (var buffer = new MemoryStream())
                {
                    using (var gzip = new GZipStream(buffer, CompressionLevel.Fastest, true))
                        gzip.Write(json, 0, json.Length);
                    _writer.Write("<script type=\"application/x-group-inventory-chunk\">");
                    _writer.Write(Convert.ToBase64String(buffer.ToArray()));
                    _writer.Write("</script>\n");
                }
                _chunks++;
                _rows.Clear();
            }

            public void Close(long rows, long totalRows, long part, long totalParts, string fileName, string partsName,
                string runSealedUtc, string[] siblings)
            {
                if (_closed) return;
                FlushChunk();
                var meta = new Dictionary<string, object>
                {
                    { "rows", rows }, { "totalRows", totalRows }, { "file", fileName }, { "partIndex", part }, { "partCount", totalParts },
                    { "chunks", _chunks }, { "index", fileName }, { "partsDirectory", partsName },
                    { "runSealedUtc", runSealedUtc }, { "relationPreview", _options.HtmlMaxRelationsPerCell },
                    { "siblings", siblings }
                };
                meta["title"] = _options.Title;
                meta["author"] = "Nicolas Fabert";
                meta["companyName"] = _options.CompanyName;
                meta["timeZone"] = _options.TimeZone;
                meta["csvDelimiter"] = _options.CsvDelimiter;
                meta["neutralizeFormulas"] = _options.NeutralizeFormulas;
                if (_options.ShowTenantInformation)
                {
                    meta["tenantId"] = _options.TenantId;
                    meta["organization"] = _options.Organization;
                    meta["environmentName"] = _options.EnvironmentName;
                    meta["tenantIdentitySource"] = _options.TenantIdentitySource;
                    meta["legacyTenantHistoryUnverified"] = _options.LegacyTenantHistoryUnverified;
                }
                string metadata = JsonSerializer.Serialize(meta, HtmlJsonOptions).Replace("</", "<\\/");
                _writer.Write(_template.BetweenChunksAndMeta);
                _writer.Write(metadata);
                _writer.Write(_template.AfterMeta);
                SyncedClose(_writer, _file);
                _closed = true;
            }

            public void Dispose()
            {
                if (!_closed) _writer.Dispose();
            }
        }

        /// <summary>
        /// Writes a self-contained HTML report. By default all rows are in Path, like PurviewDlpReport; the legacy
        /// index plus sibling parts layout remains available with HtmlSingleFile=false.
        /// </summary>
        public ExportResult ExportHtml(ExportOptions o)
        {
            string index = RequireTarget(o, ".html");
            if (o.HtmlRowsPerPart < 1 || o.HtmlRowsPerPart > 10000) throw new ProtocolException("HtmlRowsPerPart must be between 1 and 10000.");
            if (o.HtmlMaxRelationsPerCell < 1 || o.HtmlMaxRelationsPerCell > 10000) throw new ProtocolException("HtmlMaxRelationsPerCell must be between 1 and 10000.");
            if (o.HtmlChunkRows < 1 || o.HtmlChunkRows > 5000) throw new ProtocolException("HtmlChunkRows must be between 1 and 5000.");
            string dir = Path.GetDirectoryName(index);
            string name = Path.GetFileNameWithoutExtension(index);
            string partsName = name + "_parts";
            string finalParts = Path.Combine(dir, partsName);
            if ((File.Exists(index) || Directory.Exists(finalParts)) && !o.Overwrite) throw new EngineException("The output already exists (set Overwrite to replace it): " + Path.GetFileName(index));
            string token = Guid.NewGuid().ToString("N");
            string stage = Path.Combine(dir, "." + name + "." + token + ".tmp");
            string stageParts = Path.Combine(stage, partsName);
            string stageIndex = Path.Combine(stage, Path.GetFileName(index));
            string old = Path.Combine(dir, "." + name + "." + token + ".old");
            var res = new ExportResult { Path = index, Format = "HTML" };
            try
            {
                Directory.CreateDirectory(o.HtmlSingleFile ? stage : stageParts);
                HtmlTemplate template = LoadHtmlTemplate(o);
                var ranges = new List<long[]>();
                using (var db = ReadOnlyDb.Open(_dbPath, true))
                {
                    res.RowsTotal = db.SealedGroups;
                    long totalParts = o.HtmlSingleFile ? 1 : Math.Max(1, (res.RowsTotal + o.HtmlRowsPerPart - 1) / o.HtmlRowsPerPart);
                    using (var g = db.Groups())
                    {
                        HtmlPartWriter partWriter = null;
                        long part = 0, inPart = 0;
                        try
                        {
                            if (res.RowsTotal == 0)
                            {
                                part = 1;
                                partWriter = new HtmlPartWriter(o.HtmlSingleFile ? stageIndex : Path.Combine(stageParts, PartFile(part)), template, o);
                                ranges.Add(new long[] { part, 0, 0 });
                            }
                            while (g.Next())
                            {
                                if (partWriter == null)
                                {
                                    part++; inPart = 0;
                                    string filePath = o.HtmlSingleFile ? stageIndex : Path.Combine(stageParts, PartFile(part));
                                    partWriter = new HtmlPartWriter(filePath, template, o);
                                    ranges.Add(new long[] { part, res.RowsWritten + 1, 0 });
                                }
                                partWriter.Add(g);
                                res.RowsWritten++; inPart++;
                                ranges[ranges.Count - 1][2] = res.RowsWritten;
                                if (!o.HtmlSingleFile && inPart >= o.HtmlRowsPerPart)
                                {
                                    partWriter.Close(inPart, res.RowsTotal, part, totalParts,
                                        o.HtmlSingleFile ? Path.GetFileName(index) : PartFile(part),
                                        o.HtmlSingleFile ? "" : partsName, db.Meta("sealed_utc"),
                                        o.HtmlSingleFile ? new[] { Path.GetFileName(index) } : PartNames(totalParts));
                                    partWriter = null;
                                }
                            }
                            if (partWriter != null)
                            {
                                partWriter.Close(inPart, res.RowsTotal, part, totalParts,
                                    o.HtmlSingleFile ? Path.GetFileName(index) : PartFile(part),
                                    o.HtmlSingleFile ? "" : partsName, db.Meta("sealed_utc"),
                                    o.HtmlSingleFile ? new[] { Path.GetFileName(index) } : PartNames(totalParts));
                                partWriter = null;
                            }
                        }
                        catch { if (partWriter != null) partWriter.Dispose(); throw; }
                    }
                    if (db.Meta("sealed_utc").Length == 0) throw new EngineException("Export integrity failure: the seal timestamp is missing.");
                    if (!o.HtmlSingleFile) WriteHtmlIndex(stageIndex, name, partsName, db, res, ranges, o, "");
                }
                if (res.RowsWritten != res.RowsTotal) throw new EngineException("Export integrity failure: " + Num(res.RowsWritten) + " rows written, " + Num(res.RowsTotal) + " groups sealed.");
                res.Parts = ranges.Count;
                res.RelationsTruncated = 0;
                long bytes = o.HtmlSingleFile ? new FileInfo(stageIndex).Length : new FileInfo(stageIndex).Length;
                if (!o.HtmlSingleFile) foreach (var f in Directory.GetFiles(stageParts)) bytes += new FileInfo(f).Length;
                res.Bytes = bytes;
                res.Sha256 = Sha256File(stageIndex);

                if (o.HtmlSingleFile) PromoteSingle(o, index, finalParts, stageIndex, old);
                else Promote(o, index, finalParts, stageIndex, stageParts, old);
                return res;
            }
            finally
            {
                try { if (Directory.Exists(stage)) Directory.Delete(stage, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        }

        /// <summary>
        /// Publishes a fully built and verified export. Without Overwrite nothing existing is touched. With Overwrite the previous export
        /// is only set aside (renamed, never deleted) and is deleted after the new one is completely in place; if any step fails everything
        /// done so far is undone explicitly and the previous export is back exactly as it was.
        /// </summary>
        static void Promote(ExportOptions o, string index, string finalParts, string stageIndex, string stageParts, string old)
        {
            bool hadParts = Directory.Exists(finalParts), hadIndex = File.Exists(index);
            if ((hadParts || hadIndex) && !o.Overwrite) throw new EngineException("The output appeared during the export: " + Path.GetFileName(index));
            string oldIndex = old + ".index";
            bool partsAside = false, indexAside = false, partsPublished = false, indexPublished = false;
            try
            {
                if (hadParts) { Directory.Move(finalParts, old); partsAside = true; }
                if (hadIndex) { File.Move(index, oldIndex); indexAside = true; }
                if (o.TestFailPromotionAt == 1) throw new IOException("Simulated promotion failure (step 1).");
                Directory.Move(stageParts, finalParts); partsPublished = true;
                if (o.TestFailPromotionAt == 2) throw new IOException("Simulated promotion failure (step 2).");
                File.Move(stageIndex, index); indexPublished = true;
            }
            catch (Exception e)
            {
                var problems = new List<string>();
                try { if (indexPublished && File.Exists(index)) File.Move(index, stageIndex); } catch (Exception r) { problems.Add("index: " + r.Message); }
                try { if (partsPublished && Directory.Exists(finalParts)) Directory.Move(finalParts, stageParts); } catch (Exception r) { problems.Add("parts: " + r.Message); }
                try { if (indexAside && !File.Exists(index)) File.Move(oldIndex, index); } catch (Exception r) { problems.Add("previous index kept as " + Path.GetFileName(oldIndex) + ": " + r.Message); }
                try { if (partsAside && !Directory.Exists(finalParts)) Directory.Move(old, finalParts); } catch (Exception r) { problems.Add("previous parts kept as " + Path.GetFileName(old) + ": " + r.Message); }
                if (problems.Count > 0)
                    throw new EngineException("HTML export promotion failed (" + e.Message + ") and the rollback was incomplete; the previous export is preserved under hidden names next to it: " + string.Join("; ", problems), e);
                throw new EngineException("HTML export promotion failed (" + e.Message + "); the previous export was restored and nothing new was published.", e);
            }
            // complete success: only now is the previous export deleted (best effort; leftovers are harmless hidden names)
            try { if (partsAside && Directory.Exists(old)) Directory.Delete(old, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            try { if (indexAside && File.Exists(oldIndex)) File.Delete(oldIndex); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }

        static void PromoteSingle(ExportOptions o, string index, string finalParts, string stageIndex, string old)
        {
            bool hadParts = Directory.Exists(finalParts), hadIndex = File.Exists(index);
            if ((hadParts || hadIndex) && !o.Overwrite) throw new EngineException("The output already exists (set Overwrite to replace it): " + Path.GetFileName(index));
            string oldIndex = old + ".index";
            bool partsAside = false, indexAside = false, indexPublished = false;
            try
            {
                if (hadParts) { Directory.Move(finalParts, old); partsAside = true; }
                if (hadIndex) { File.Move(index, oldIndex); indexAside = true; }
                if (o.TestFailPromotionAt == 1) throw new IOException("Simulated promotion failure (step 1).");
                File.Move(stageIndex, index); indexPublished = true;
            }
            catch (Exception e)
            {
                var problems = new List<string>();
                try { if (indexPublished && File.Exists(index)) File.Move(index, stageIndex); } catch (Exception r) { problems.Add("index: " + r.Message); }
                try { if (indexAside && !File.Exists(index)) File.Move(oldIndex, index); } catch (Exception r) { problems.Add("previous index kept as " + Path.GetFileName(oldIndex) + ": " + r.Message); }
                try { if (partsAside && !Directory.Exists(finalParts)) Directory.Move(old, finalParts); } catch (Exception r) { problems.Add("previous parts kept as " + Path.GetFileName(old) + ": " + r.Message); }
                if (problems.Count > 0)
                    throw new EngineException("HTML export promotion failed (" + e.Message + ") and rollback was incomplete: " + string.Join("; ", problems), e);
                throw new EngineException("HTML export promotion failed (" + e.Message + "); the previous export was restored and nothing new was published.", e);
            }
            try { if (partsAside && Directory.Exists(old)) Directory.Delete(old, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            try { if (indexAside && File.Exists(oldIndex)) File.Delete(oldIndex); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }

        static string PartFile(long part) { return "part_" + part.ToString("D5", CultureInfo.InvariantCulture) + ".html"; }

        static string[] PartNames(long totalParts)
        {
            var names = new string[totalParts];
            for (long i = 0; i < totalParts; i++) names[i] = PartFile(i + 1);
            return names;
        }

        static void WriteHtmlIndex(string path, string name, string partsName, ReadOnlyDb db, ExportResult res, List<long[]> ranges, ExportOptions o, string companion)
        {
            var fs = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536);
            var w = new StreamWriter(fs, new UTF8Encoding(false), 65536);
            try
            {
                HtmlHead(w, "M365 groups inventory");
                w.Write("<h1>M365 groups inventory</h1><p>");
                w.Write(Num(res.RowsTotal) + " groups in " + Num(ranges.Count) + " interactive page(s) of at most " + Num(o.HtmlRowsPerPart) + " rows. Run sealed (UTC): ");
                HtmlEnc(w, db.Meta("sealed_utc"));
                w.Write(".</p><p class=\"more\">Each page supports search, filtering, sorting and virtual scrolling. Relation cells preview at most ");
                w.Write(Num(o.HtmlMaxRelationsPerCell));
                w.Write(" values; the complete lists remain available in the page details and filters.");
                w.Write("</p>");
                w.Write("<table><thead><tr><th>page</th><th>groups</th></tr></thead><tbody>");
                foreach (var r in ranges)
                {
                    w.Write("<tr><td><a href=\"" + Uri.EscapeDataString(partsName) + "/" + PartFile(r[0]) + "\">part " + Num(r[0]) + "</a></td><td>" + Num(r[1]) + " - " + Num(r[2]) + "</td></tr>");
                }
                w.Write("</tbody></table></body></html>\n");
                SyncedClose(w, fs);
            }
            catch { w.Dispose(); throw; }
        }
    }
}
