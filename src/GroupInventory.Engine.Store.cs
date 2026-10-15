// =============================================================================
//  Group Inventory engine, part 2: durable, resumable SQLite run store
// -----------------------------------------------------------------------------
//  One database per inventory run. The file is durable: it survives interruptions and is
//  reopened with Store.Open to continue a run (completed lists are kept, incomplete lists are
//  recollected, nothing else is redone).
//  Journal / durability policy (verified after it is set, fail closed on any difference):
//    journal_mode=DELETE   rollback journal only, removed at every commit; WAL is NEVER enabled
//    synchronous=FULL      a checkpoint acknowledged to the caller is on disk
//    foreign_keys=ON, trusted_schema=OFF, cell_size_check=ON, temp_store=MEMORY, mmap_size=0
//  A -wal / -shm file, or a -journal file outside a transaction, is an unexpected sidecar: the
//  engine stops. A hot rollback journal left by a crash is replayed by SQLite when the file is
//  reopened; the engine then verifies quick_check / foreign_key_check before using the run.
//  All access to this class happens on the single writer thread of InventoryEngine.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using Microsoft.Data.Sqlite;

namespace GroupInventory.Engine
{
    internal struct StreamRow { public bool Found; public int State; public long NextSeq, Stored, Dup; public string LastHash; }
    internal struct FlowRow { public bool Found; public int State; public long Pass, NextPage, Rows, Dup; public string LastHash, Cursor, Message; }

    internal sealed class Store : IDisposable
    {
        const string Schema = @"
CREATE TABLE engine_meta(key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE collection_state(id INTEGER NOT NULL PRIMARY KEY, name TEXT NOT NULL UNIQUE) WITHOUT ROWID;
INSERT INTO collection_state(id,name) VALUES (0,'pending'),(1,'collecting'),(2,'complete'),(3,'failed'),(4,'skipped');
CREATE TABLE list_kind(id INTEGER NOT NULL PRIMARY KEY, name TEXT NOT NULL UNIQUE) WITHOUT ROWID;
INSERT INTO list_kind(id,name) VALUES (1,'owners'),(2,'members');
CREATE TABLE flow(
  name TEXT NOT NULL PRIMARY KEY CHECK(name IN ('enum','sites')),
  state INTEGER NOT NULL REFERENCES collection_state(id),
  pass INTEGER NOT NULL DEFAULT 0 CHECK(pass>=0),
  next_page INTEGER NOT NULL DEFAULT 0 CHECK(next_page>=0),
  rows_seen INTEGER NOT NULL DEFAULT 0 CHECK(rows_seen>=0),
  dup_count INTEGER NOT NULL DEFAULT 0 CHECK(dup_count>=0),
  last_hash TEXT NOT NULL DEFAULT '',
  cursor TEXT NOT NULL DEFAULT '',
  message TEXT NOT NULL DEFAULT '') WITHOUT ROWID;
CREATE TABLE grp(
  gid INTEGER PRIMARY KEY,
  group_id TEXT NOT NULL UNIQUE CHECK(length(group_id)=36 AND group_id=lower(group_id)),
  display_name TEXT NOT NULL, alias TEXT NOT NULL, mail TEXT NOT NULL, visibility TEXT NOT NULL,
  is_team INTEGER NOT NULL CHECK(is_team IN (0,1)),
  pass INTEGER NOT NULL CHECK(pass>=0));
CREATE INDEX ix_grp_pass ON grp(pass);
CREATE TABLE list_stream(
  gid INTEGER NOT NULL REFERENCES grp(gid),
  kind INTEGER NOT NULL REFERENCES list_kind(id),
  state INTEGER NOT NULL REFERENCES collection_state(id),
  next_seq INTEGER NOT NULL DEFAULT 0 CHECK(next_seq>=0),
  stored_count INTEGER NOT NULL DEFAULT 0 CHECK(stored_count>=0),
  dup_count INTEGER NOT NULL DEFAULT 0 CHECK(dup_count>=0),
  declared_count INTEGER CHECK(declared_count IS NULL OR declared_count>=0),
  last_hash TEXT NOT NULL DEFAULT '',
  cursor TEXT NOT NULL DEFAULT '',
  http_status INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(gid, kind),
  CHECK(state<>2 OR declared_count IS NOT NULL)) WITHOUT ROWID;
CREATE INDEX ix_list_stream_state ON list_stream(state);
CREATE TABLE list_entry(
  gid INTEGER NOT NULL,
  kind INTEGER NOT NULL,
  entry_id TEXT NOT NULL CHECK(length(entry_id)=36 AND entry_id=lower(entry_id)),
  display_value TEXT NOT NULL CHECK(length(display_value)>0),
  PRIMARY KEY(gid, kind, entry_id),
  FOREIGN KEY(gid, kind) REFERENCES list_stream(gid, kind)) WITHOUT ROWID;
CREATE TABLE site_url(
  group_id TEXT NOT NULL PRIMARY KEY CHECK(length(group_id)=36 AND group_id=lower(group_id)),
  url TEXT NOT NULL CHECK(url LIKE 'https://%')) WITHOUT ROWID;
CREATE TABLE failure(
  id INTEGER PRIMARY KEY,
  gid INTEGER REFERENCES grp(gid),
  flow TEXT NOT NULL DEFAULT '',
  kind INTEGER NOT NULL,
  http_status INTEGER NOT NULL,
  message TEXT NOT NULL);
CREATE INDEX ix_failure_gid ON failure(gid);
CREATE TABLE removed_group(
  group_id TEXT NOT NULL PRIMARY KEY CHECK(length(group_id)=36 AND group_id=lower(group_id)),
  display_name TEXT NOT NULL,
  reason TEXT NOT NULL) WITHOUT ROWID;
";
        static readonly string[] SidecarSuffixes = { "-journal", "-wal", "-shm" };

        readonly EngineOptions _o;
        readonly Dictionary<string, SqliteCommand> _cmds = new Dictionary<string, SqliteCommand>();
        SqliteConnection _db;
        bool _inTx;
        int _txRows;
        long _txStartTicks;
        string _state = EngineInfo.StateCollecting;
        bool _skipMembers;
        public long Transactions;
        public string DbPath { get; private set; }
        public string SqliteVersion { get; private set; }
        public bool SkipMembers { get { return _skipMembers; } }

        Store(EngineOptions o) { _o = o; }

        // ------------------------------------------------------------------ create / open
        public static Store Create(EngineOptions o)
        {
            var s = Prepare(o);
            if (File.Exists(s.DbPath) || Directory.Exists(s.DbPath)) throw new EngineException("The inventory database already exists; resume it instead of creating it.");
            foreach (var x in SidecarSuffixes)
                if (File.Exists(s.DbPath + x)) throw new EngineException("Unexpected SQLite sidecar present before creation: " + Path.GetFileName(s.DbPath) + x);
            try
            {
                s.OpenConnection(SqliteOpenMode.ReadWriteCreate);
                s.Configure(true);
                s.Begin();
                s.Exec(Schema);
                s.Exec("PRAGMA application_id=" + EngineInfo.ApplicationId.ToString(CultureInfo.InvariantCulture) + ";");
                s.Exec("PRAGMA user_version=" + EngineInfo.SchemaVersion.ToString(CultureInfo.InvariantCulture) + ";");
                s.SetMeta("schema_version", EngineInfo.SchemaVersion.ToString(CultureInfo.InvariantCulture));
                s.SetMeta("protocol_version", EngineInfo.ProtocolVersion.ToString(CultureInfo.InvariantCulture));
                s.SetMeta("run_id", o.RunId ?? "");
                s.SetMeta("skip_members", o.SkipMembers ? "1" : "0");
                s.SetMeta("sites_required", o.SitesRequired ? "1" : "0");
                s.SetMeta("sqlite_version", s.SqliteVersion);
                s.SetMeta("created_utc", DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture));
                s.SetMeta("state", EngineInfo.StateCollecting);
                var c = s.Q("INSERT INTO flow(name,state) VALUES(@n,@s);");
                Set(c, "@n", EngineInfo.FlowEnum); Set(c, "@s", (int)FlowState.Pending); c.ExecuteNonQuery();
                Set(c, "@n", EngineInfo.FlowSites); Set(c, "@s", o.SitesRequired ? (int)FlowState.Pending : (int)FlowState.Skipped); c.ExecuteNonQuery();
                s.Commit();
                s._skipMembers = o.SkipMembers;
                s.Expect("journal_mode", "delete", false);
                s.Expect("page_size", o.PageSize.ToString(CultureInfo.InvariantCulture), false);
                s.AssertNoSidecars(false);
            }
            catch { s.Dispose(); throw; }
            return s;
        }

        /// <summary>Reopens an existing run: schema/identity/integrity checks, then recovery of the incomplete lists.</summary>
        public static Store Open(EngineOptions o)
        {
            var s = Prepare(o);
            if (!File.Exists(s.DbPath)) throw new EngineException("The inventory database does not exist: " + Path.GetFileName(s.DbPath));
            try
            {
                s.OpenConnection(SqliteOpenMode.ReadWrite);
                s.Configure(false);
                s.CheckIdentity(o);
                s.RemoveNonHotJournal();
                s.VerifyIntegrity();
                if (s._state == EngineInfo.StateCollecting) s.RecoverIncomplete();
            }
            catch { s.Dispose(); throw; }
            return s;
        }

        static Store Prepare(EngineOptions o)
        {
            if (o == null) throw new ArgumentNullException("o");
            if (string.IsNullOrWhiteSpace(o.DatabasePath)) throw new EngineException("DatabasePath is required.");
            var s = new Store(o);
            s.DbPath = Path.GetFullPath(o.DatabasePath);
            string dir = Path.GetDirectoryName(s.DbPath);
            if (!Directory.Exists(dir)) throw new EngineException("The run directory does not exist.");
            return s;
        }

        void OpenConnection(SqliteOpenMode mode)
        {
            SqliteRuntime.EnsureInitialized();
            var b = new SqliteConnectionStringBuilder { DataSource = DbPath, Mode = mode, Cache = SqliteCacheMode.Private, Pooling = false };
            _db = new SqliteConnection(b.ToString());
            try { _db.Open(); }
            catch (SqliteException e) { throw new IncompatibleDatabaseException("SQLite could not open the inventory database (code " + e.SqliteErrorCode.ToString(CultureInfo.InvariantCulture) + ").", e); }
            SqliteVersion = Convert.ToString(Scalar("SELECT sqlite_version();"), CultureInfo.InvariantCulture);
            var vp = SqliteVersion.Split('.');
            int maj, min;
            if (vp.Length < 2 || !int.TryParse(vp[0], out maj) || !int.TryParse(vp[1], out min) || maj < 3 || (maj == 3 && min < 35))
                throw new EngineException("Unsupported SQLite provider version '" + SqliteVersion + "' (3.35 or later required).");
        }

        void Configure(bool create)
        {
            Exec("PRAGMA busy_timeout=5000;");
            if (create)
            {
                Expect("page_size", _o.PageSize.ToString(CultureInfo.InvariantCulture), true);
                Expect("auto_vacuum", "0", true);
            }
            Expect("journal_mode", "delete", true);
            Expect("synchronous", "2", true);
            Expect("temp_store", "2", true);
            Expect("mmap_size", "0", true);
            Expect("foreign_keys", "1", true);
            Expect("trusted_schema", "0", true);
            Expect("cell_size_check", "1", true);
            Exec("PRAGMA cache_size=-" + Math.Max(1024, _o.CacheKb).ToString(CultureInfo.InvariantCulture) + ";");
        }

        void CheckIdentity(EngineOptions o)
        {
            long appId, userVersion;
            try
            {
                appId = Convert.ToInt64(Scalar("PRAGMA application_id;"), CultureInfo.InvariantCulture);
                userVersion = Convert.ToInt64(Scalar("PRAGMA user_version;"), CultureInfo.InvariantCulture);
            }
            catch (SqliteException e) { throw new IncompatibleDatabaseException("The file is not a readable SQLite database (code " + e.SqliteErrorCode.ToString(CultureInfo.InvariantCulture) + ").", e); }
            if (appId != EngineInfo.ApplicationId) throw new IncompatibleDatabaseException("The file is not a Group Inventory run database.");
            if (userVersion > EngineInfo.SchemaVersion) throw new IncompatibleDatabaseException("The database uses schema version " + userVersion.ToString(CultureInfo.InvariantCulture) + ", newer than this engine supports (" + EngineInfo.SchemaVersion.ToString(CultureInfo.InvariantCulture) + ").");
            if (userVersion < EngineInfo.SchemaVersion) throw new IncompatibleDatabaseException("The database uses schema version " + userVersion.ToString(CultureInfo.InvariantCulture) + "; no migration is available for this engine (" + EngineInfo.SchemaVersion.ToString(CultureInfo.InvariantCulture) + ").");
            if (GetMeta("schema_version") != EngineInfo.SchemaVersion.ToString(CultureInfo.InvariantCulture)) throw new IncompatibleDatabaseException("The schema metadata does not match the schema version.");
            if (GetMeta("protocol_version") != EngineInfo.ProtocolVersion.ToString(CultureInfo.InvariantCulture)) throw new IncompatibleDatabaseException("The run was created with another engine protocol version (" + GetMeta("protocol_version") + ").");
            if (!string.IsNullOrEmpty(o.RunId) && GetMeta("run_id") != o.RunId) throw new IncompatibleDatabaseException("The database belongs to another inventory run (run id mismatch).");
            _skipMembers = GetMeta("skip_members") == "1";
            if (o.AdoptRunSettings) o.SkipMembers = _skipMembers;
            if (_skipMembers != o.SkipMembers) throw new IncompatibleDatabaseException("The run was created " + (_skipMembers ? "with" : "without") + " SkipMembers; it cannot be resumed with the opposite setting.");
            _state = GetMeta("state");
            if (_state != EngineInfo.StateCollecting && _state != EngineInfo.StateSealed) throw new IncompatibleDatabaseException("Unknown run state '" + _state + "'.");
        }

        /// <summary>
        /// SQLite has already rolled back a valid (hot) journal by the time the identity pragmas were read. A journal that is
        /// still there after that is not hot (a crash before it was synced): it carries nothing and is removed, otherwise the
        /// no-sidecar policy would wrongly refuse a run that crashed at an unlucky moment.
        /// </summary>
        void RemoveNonHotJournal()
        {
            string j = DbPath + "-journal";
            if (!File.Exists(j)) return;
            try { File.Delete(j); }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) { throw new EngineException("A leftover rollback journal could not be removed: " + Path.GetFileName(j), e); }
        }

        /// <summary>
        /// Crash recovery: entries of lists that never completed are removed in bounded chunks and those lists go back to
        /// 'pending' (failed lists stay failed until recollected). Completed lists and flows are untouched.
        /// </summary>
        void RecoverIncomplete()
        {
            var dirty = new List<long>();
            using (var c = _db.CreateCommand())
            {
                c.CommandText = "SELECT gid,kind FROM list_stream WHERE state IN (1,3);";
                using (var r = c.ExecuteReader()) while (r.Read()) dirty.Add(r.GetInt64(0) * 4 + r.GetInt64(1));
            }
            Begin();
            foreach (long k in dirty) PurgeEntries(k / 4, (int)(k % 4));
            Exec("UPDATE list_stream SET state=0,next_seq=0,stored_count=0,dup_count=0,declared_count=NULL,last_hash='',cursor='',http_status=0 WHERE state=1;");
            Commit();
        }

        // ------------------------------------------------------------------ helpers
        SqliteCommand Q(string sql)
        {
            SqliteCommand c;
            if (!_cmds.TryGetValue(sql, out c))
            {
                c = _db.CreateCommand();
                c.CommandText = sql;
                _cmds[sql] = c;
            }
            return c;
        }

        static void Set(SqliteCommand c, string name, object value)
        {
            if (c.Parameters.Contains(name)) c.Parameters[name].Value = value ?? DBNull.Value;
            else c.Parameters.AddWithValue(name, value ?? DBNull.Value);
        }

        public void Exec(string sql)
        {
            using (var c = _db.CreateCommand()) { c.CommandText = sql; c.ExecuteNonQuery(); }
        }

        public object Scalar(string sql)
        {
            using (var c = _db.CreateCommand()) { c.CommandText = sql; return c.ExecuteScalar(); }
        }

        long ScalarLong(string sql) { return Convert.ToInt64(Scalar(sql), CultureInfo.InvariantCulture); }

        void Expect(string name, string expected, bool set)
        {
            if (set) Exec("PRAGMA " + name + "=" + (name == "journal_mode" ? expected.ToUpperInvariant() : expected) + ";");
            string actual = Convert.ToString(Scalar("PRAGMA " + name + ";"), CultureInfo.InvariantCulture);
            if (!string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase))
                throw new EngineException("SQLite policy check failed: PRAGMA " + name + " is '" + actual + "', expected '" + expected + "'. Refusing to continue (no fallback).");
        }

        public string GetMeta(string key)
        {
            var c = Q("SELECT value FROM engine_meta WHERE key=@k;");
            Set(c, "@k", key);
            return Convert.ToString(c.ExecuteScalar(), CultureInfo.InvariantCulture) ?? "";
        }

        public void SetMeta(string key, string value)
        {
            var c = Q("INSERT INTO engine_meta(key,value) VALUES(@k,@v) ON CONFLICT(key) DO UPDATE SET value=excluded.value;");
            Set(c, "@k", key); Set(c, "@v", value);
            c.ExecuteNonQuery();
        }

        public WriteResult BindAuthenticatedTenant(string tenantId)
        {
            string current = GetMeta("tenant_id");
            if (current.Length > 0)
                return string.Equals(current, tenantId, StringComparison.OrdinalIgnoreCase)
                    ? Replayed("Authenticated tenant already matches the snapshot.")
                    : Fail("The snapshot belongs to another authenticated tenant; use a separate snapshot.");
            if (_state == EngineInfo.StateSealed) return Fail("An unbound sealed snapshot cannot be attributed offline.");
            bool legacy = ScalarLong("SELECT COUNT(*) FROM grp;") > 0;
            SetMeta("tenant_id", tenantId);
            SetMeta("legacy_tenant_history_unverified", legacy ? "1" : "0");
            return new WriteResult { Status = WriteStatus.Applied, Message = legacy
                ? "Authenticated tenant bound; historical rows of this legacy snapshot remain unverified."
                : "Snapshot bound to the authenticated collection tenant." };
        }

        public bool InTransaction { get { return _inTx; } }
        public int TxRows { get { return _txRows; } }

        public void Begin()
        {
            if (_inTx) return;
            Exec("BEGIN IMMEDIATE;");
            _inTx = true;
            _txRows = 0;
            _txStartTicks = Stopwatch.GetTimestamp();
        }

        public void Commit()
        {
            if (!_inTx) return;
            Exec("COMMIT;");
            _inTx = false;
            _txRows = 0;
            Transactions++;
        }

        public void Rollback()
        {
            if (!_inTx || _db == null) return;
            try { Exec("ROLLBACK;"); } catch (SqliteException) { }
            _inTx = false;
            _txRows = 0;
        }

        public bool TxIsFull { get { return _inTx && _txRows >= _o.TxMaxRows; } }

        public bool TxIsAged
        {
            get
            {
                if (!_inTx) return false;
                double ms = (Stopwatch.GetTimestamp() - _txStartTicks) * 1000.0 / Stopwatch.Frequency;
                return ms >= _o.TxMaxMs;
            }
        }

        void CommitIfFull() { if (TxIsFull) { Commit(); Begin(); } }

        /// <summary>Unexpected sidecars: -wal/-shm are never allowed; -journal only while a transaction is open.</summary>
        public void AssertNoSidecars(bool journalAllowed)
        {
            foreach (var x in SidecarSuffixes)
            {
                if (x == "-journal" && journalAllowed) continue;
                if (File.Exists(DbPath + x))
                    throw new EngineException("Unexpected SQLite sidecar file '" + Path.GetFileName(DbPath) + x + "' (policy: rollback journal removed at commit, WAL never enabled).");
            }
        }

        /// <summary>Test hook: copies the database and its journal (the writer is paused, the transaction is open).</summary>
        public void CopyCrashImage(string target)
        {
            CopyShared(DbPath, target);
            if (File.Exists(DbPath + "-journal")) CopyShared(DbPath + "-journal", target + "-journal");
        }

        static void CopyShared(string source, string target)
        {
            using (var i = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var o = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None))
                i.CopyTo(o);
        }

        void RequireCollecting()
        {
            if (_state != EngineInfo.StateCollecting) throw new RunStateException("The run is sealed (immutable); it cannot be modified.");
        }

        static WriteResult Fail(string message) { return new WriteResult { Status = WriteStatus.Failed, Message = message }; }
        static WriteResult Replayed(string message) { return new WriteResult { Status = WriteStatus.Replayed, Message = message }; }

        static string Num(long n) { return n.ToString(CultureInfo.InvariantCulture); }

        // ------------------------------------------------------------------ flows
        public FlowRow GetFlow(string name)
        {
            var c = Q("SELECT state,pass,next_page,rows_seen,dup_count,last_hash,cursor,message FROM flow WHERE name=@n;");
            Set(c, "@n", name);
            using (var r = c.ExecuteReader())
            {
                if (!r.Read()) return new FlowRow();
                return new FlowRow
                {
                    Found = true, State = (int)r.GetInt64(0), Pass = r.GetInt64(1), NextPage = r.GetInt64(2), Rows = r.GetInt64(3),
                    Dup = r.GetInt64(4), LastHash = r.GetString(5), Cursor = r.GetString(6), Message = r.GetString(7)
                };
            }
        }

        void SaveFlow(string name, FlowState st, long pass, long nextPage, long rows, long dup, string hash, string cursor, string message)
        {
            var c = Q("UPDATE flow SET state=@s,pass=@p,next_page=@np,rows_seen=@r,dup_count=@d,last_hash=@h,cursor=@c,message=@m WHERE name=@n;");
            Set(c, "@n", name); Set(c, "@s", (int)st); Set(c, "@p", pass); Set(c, "@np", nextPage); Set(c, "@r", rows);
            Set(c, "@d", dup); Set(c, "@h", hash ?? ""); Set(c, "@c", Text.Truncate(cursor, 4096)); Set(c, "@m", Text.Truncate(message, 400));
            c.ExecuteNonQuery();
        }

        WriteResult FailFlow(string name, string message)
        {
            var f = GetFlow(name);
            SaveFlow(name, FlowState.Failed, f.Pass, f.NextPage, f.Rows, f.Dup, f.LastHash, f.Cursor, message);
            var c = Q("INSERT INTO failure(gid,flow,kind,http_status,message) VALUES(NULL,@f,0,0,@m);");
            Set(c, "@f", name); Set(c, "@m", Text.Truncate(message, 400));
            c.ExecuteNonQuery();
            _txRows += 2;
            return Fail(message);
        }

        /// <summary>Null when the page must be applied; otherwise the early (replayed / failed) result.</summary>
        WriteResult FlowGate(string name, FlowRow f, long seq, string hash)
        {
            if (!f.Found) throw new ProtocolException("Unknown flow '" + name + "'.");
            if (f.State == (int)FlowState.Skipped) throw new ProtocolException("Flow '" + name + "' is not collected for this run.");
            if (f.State == (int)FlowState.Complete)
            {
                if (seq == f.NextPage - 1 && hash == f.LastHash) return Replayed("Flow '" + name + "' is already complete (page replayed).");
                return Fail("Flow '" + name + "' is already complete; the page was ignored.");
            }
            if (f.State == (int)FlowState.Failed) return Fail("Flow '" + name + "' has failed (" + f.Message + "); reset it before sending pages.");
            if (seq == f.NextPage) return null;
            if (f.NextPage > 0 && seq == f.NextPage - 1 && hash == f.LastHash) return Replayed("Page " + Num(seq) + " of flow '" + name + "' replayed (already committed).");
            string why = seq == f.NextPage - 1 ? "same page number with different content" : "expected page " + Num(f.NextPage) + ", received " + Num(seq);
            return FailFlow(name, "Checkpoint conflict on flow '" + name + "': " + why + ".");
        }

        public WriteResult ApplyGroupPage(long seq, string hash, GroupRecord[] groups, string cursor)
        {
            RequireCollecting();
            var f = GetFlow(EngineInfo.FlowEnum);
            var early = FlowGate(EngineInfo.FlowEnum, f, seq, hash);
            if (early != null) return early;
            Exec("SAVEPOINT pg;");
            long inserted = 0, dups = 0, updated = 0;
            int rows = 0;
            var ins = Q("INSERT INTO grp(group_id,display_name,alias,mail,visibility,is_team,pass) VALUES(@g,@n,@a,@m,@v,@t,@p) ON CONFLICT(group_id) DO NOTHING RETURNING gid;");
            var get = Q("SELECT gid,display_name,alias,mail,visibility,is_team,pass FROM grp WHERE group_id=@g;");
            foreach (var g in groups)
            {
                Set(ins, "@g", g.Id); Set(ins, "@n", g.DisplayName); Set(ins, "@a", g.Alias); Set(ins, "@m", g.Mail);
                Set(ins, "@v", g.Visibility); Set(ins, "@t", g.IsTeam ? 1 : 0); Set(ins, "@p", f.Pass);
                object newGid = ins.ExecuteScalar();
                if (newGid != null)
                {
                    long gid = Convert.ToInt64(newGid, CultureInfo.InvariantCulture);
                    InsertStream(gid, (int)ListKind.Owners, FlowState.Pending);
                    InsertStream(gid, (int)ListKind.Members, _skipMembers ? FlowState.Skipped : FlowState.Pending);
                    inserted++; rows += 3;
                    continue;
                }
                long egid, epass; string en, ea, em, ev; bool et;
                Set(get, "@g", g.Id);
                using (var r = get.ExecuteReader())
                {
                    r.Read();
                    egid = r.GetInt64(0); en = r.GetString(1); ea = r.GetString(2); em = r.GetString(3); ev = r.GetString(4); et = r.GetInt64(5) == 1; epass = r.GetInt64(6);
                }
                bool same = en == g.DisplayName && ea == g.Alias && em == g.Mail && ev == g.Visibility && et == g.IsTeam;
                if (same)
                {
                    dups++;
                    if (epass < f.Pass) { Exec("UPDATE grp SET pass=" + Num(f.Pass) + " WHERE gid=" + Num(egid) + ";"); rows++; }
                    continue;
                }
                if (epass >= f.Pass)
                {
                    Exec("ROLLBACK TO pg;");
                    Exec("RELEASE pg;");
                    return FailFlow(EngineInfo.FlowEnum, "Conflicting attributes for group " + g.Id + " within the same enumeration pass.");
                }
                var up = Q("UPDATE grp SET display_name=@n,alias=@a,mail=@m,visibility=@v,is_team=@t,pass=@p WHERE gid=@i;");
                Set(up, "@n", g.DisplayName); Set(up, "@a", g.Alias); Set(up, "@m", g.Mail); Set(up, "@v", g.Visibility);
                Set(up, "@t", g.IsTeam ? 1 : 0); Set(up, "@p", f.Pass); Set(up, "@i", egid);
                up.ExecuteNonQuery();
                updated++; rows++;
            }
            Exec("RELEASE pg;");
            SaveFlow(EngineInfo.FlowEnum, FlowState.Collecting, f.Pass, seq + 1, f.Rows + groups.Length, f.Dup + dups, hash, cursor, "");
            _txRows += rows + groups.Length + 1;
            return new WriteResult { Status = WriteStatus.Applied, Rows = inserted, Duplicates = dups, Message = updated > 0 ? Num(updated) + " group(s) updated by a later enumeration pass." : "" };
        }

        void InsertStream(long gid, int kind, FlowState st)
        {
            var c = Q("INSERT INTO list_stream(gid,kind,state) VALUES(@g,@k,@s);");
            Set(c, "@g", gid); Set(c, "@k", kind); Set(c, "@s", (int)st);
            c.ExecuteNonQuery();
        }

        public WriteResult ApplySitePage(long seq, string hash, string[] ids, string[] urls, string cursor)
        {
            RequireCollecting();
            var f = GetFlow(EngineInfo.FlowSites);
            var early = FlowGate(EngineInfo.FlowSites, f, seq, hash);
            if (early != null) return early;
            Exec("SAVEPOINT pg;");
            long inserted = 0, dups = 0;
            var ins = Q("INSERT INTO site_url(group_id,url) VALUES(@g,@u) ON CONFLICT(group_id) DO NOTHING;");
            var get = Q("SELECT url FROM site_url WHERE group_id=@g;");
            for (int i = 0; i < ids.Length; i++)
            {
                Set(ins, "@g", ids[i]); Set(ins, "@u", urls[i]);
                if (ins.ExecuteNonQuery() == 1) { inserted++; continue; }
                Set(get, "@g", ids[i]);
                string existing = Convert.ToString(get.ExecuteScalar(), CultureInfo.InvariantCulture);
                if (existing == urls[i]) { dups++; continue; }
                Exec("ROLLBACK TO pg;");
                Exec("RELEASE pg;");
                return FailFlow(EngineInfo.FlowSites, "Conflicting SharePoint site URLs for group " + ids[i] + " (ambiguous mapping).");
            }
            Exec("RELEASE pg;");
            SaveFlow(EngineInfo.FlowSites, FlowState.Collecting, f.Pass, seq + 1, f.Rows + ids.Length, f.Dup + dups, hash, cursor, "");
            _txRows += ids.Length + 1;
            return new WriteResult { Status = WriteStatus.Applied, Rows = inserted, Duplicates = dups };
        }

        public WriteResult CompleteFlow(string name, long declared)
        {
            RequireCollecting();
            var f = GetFlow(name);
            if (!f.Found) throw new ProtocolException("Unknown flow '" + name + "'.");
            if (f.State == (int)FlowState.Skipped) throw new ProtocolException("Flow '" + name + "' is not collected for this run.");
            if (f.State == (int)FlowState.Complete) return declared == f.Rows ? Replayed("Flow '" + name + "' is already complete.") : Fail("Flow '" + name + "' is already complete with " + Num(f.Rows) + " rows, not " + Num(declared) + ".");
            if (f.State == (int)FlowState.Failed) return Fail("Flow '" + name + "' has failed (" + f.Message + "); it cannot be completed.");
            if (declared != f.Rows) return FailFlow(name, "Flow '" + name + "' count mismatch: producer declared " + Num(declared) + " rows, " + Num(f.Rows) + " received.");
            long stale = 0;
            if (name == EngineInfo.FlowEnum) stale = PurgeStaleGroups(f.Pass);
            f = GetFlow(name);
            SaveFlow(name, FlowState.Complete, f.Pass, f.NextPage, f.Rows, f.Dup, f.LastHash, "", stale > 0 ? Num(stale) + " group(s) absent from the final enumeration pass were removed." : "");
            _txRows++;
            return new WriteResult { Status = WriteStatus.Applied, Rows = f.Rows, Duplicates = f.Dup, Message = stale > 0 ? Num(stale) + " stale group(s) removed." : "" };
        }

        public WriteResult MarkFlowFailed(string name, string message)
        {
            RequireCollecting();
            var f = GetFlow(name);
            if (!f.Found) throw new ProtocolException("Unknown flow '" + name + "'.");
            if (f.State == (int)FlowState.Skipped) throw new ProtocolException("Flow '" + name + "' is not collected for this run.");
            if (f.State == (int)FlowState.Complete) return Fail("Flow '" + name + "' is already complete.");
            return FailFlow(name, Text.Truncate(message, 400));
        }

        /// <summary>Restarts a flow from page 0. 'enum' keeps the registered groups (a new pass re-confirms them); 'sites' clears the URLs.</summary>
        public WriteResult ResetFlow(string name)
        {
            RequireCollecting();
            var f = GetFlow(name);
            if (!f.Found) throw new ProtocolException("Unknown flow '" + name + "'.");
            if (f.State == (int)FlowState.Skipped) throw new ProtocolException("Flow '" + name + "' is not collected for this run.");
            long pass = f.Pass;
            if (name == EngineInfo.FlowEnum) pass++;
            else
            {
                var del = Q("DELETE FROM site_url WHERE group_id IN (SELECT group_id FROM site_url LIMIT @n);");
                for (;;)
                {
                    Set(del, "@n", _o.PurgeChunkRows);
                    int n = del.ExecuteNonQuery();
                    _txRows += n;
                    if (n < _o.PurgeChunkRows) break;
                    CommitIfFull();
                }
            }
            var df = Q("DELETE FROM failure WHERE flow=@f;");
            Set(df, "@f", name); df.ExecuteNonQuery();
            SaveFlow(name, FlowState.Pending, pass, 0, 0, 0, "", "", "");
            _txRows += 2;
            return new WriteResult { Status = WriteStatus.Applied, Message = "Flow '" + name + "' restarted (pass " + Num(pass) + ")." };
        }

        long PurgeStaleGroups(long pass)
        {
            long removed = 0;
            var sel = Q("SELECT gid FROM grp WHERE pass<@p LIMIT 500;");
            for (;;)
            {
                var batch = new List<long>();
                Set(sel, "@p", pass);
                using (var r = sel.ExecuteReader()) while (r.Read()) batch.Add(r.GetInt64(0));
                if (batch.Count == 0) break;
                foreach (long gid in batch)
                {
                    PurgeEntries(gid, 1); PurgeEntries(gid, 2);
                    Exec("DELETE FROM list_stream WHERE gid=" + Num(gid) + ";");
                    Exec("DELETE FROM failure WHERE gid=" + Num(gid) + ";");
                    Exec("DELETE FROM grp WHERE gid=" + Num(gid) + ";");
                    removed++; _txRows += 4;
                    CommitIfFull();
                }
            }
            return removed;
        }

        // ------------------------------------------------------------------ lists
        long GidOf(string groupId)
        {
            var c = Q("SELECT gid FROM grp WHERE group_id=@g;");
            Set(c, "@g", groupId);
            object o = c.ExecuteScalar();
            return o == null ? -1 : Convert.ToInt64(o, CultureInfo.InvariantCulture);
        }

        StreamRow GetStream(long gid, int kind)
        {
            var c = Q("SELECT state,next_seq,stored_count,dup_count,last_hash FROM list_stream WHERE gid=@g AND kind=@k;");
            Set(c, "@g", gid); Set(c, "@k", kind);
            using (var r = c.ExecuteReader())
            {
                if (!r.Read()) return new StreamRow();
                return new StreamRow { Found = true, State = (int)r.GetInt64(0), NextSeq = r.GetInt64(1), Stored = r.GetInt64(2), Dup = r.GetInt64(3), LastHash = r.GetString(4) };
            }
        }

        void PurgeEntries(long gid, int kind)
        {
            var c = Q("DELETE FROM list_entry WHERE gid=@g AND kind=@k AND entry_id IN (SELECT entry_id FROM list_entry WHERE gid=@g AND kind=@k LIMIT @n);");
            for (;;)
            {
                Set(c, "@g", gid); Set(c, "@k", kind); Set(c, "@n", _o.PurgeChunkRows);
                int n = c.ExecuteNonQuery();
                _txRows += n;
                if (n < _o.PurgeChunkRows) break;
                CommitIfFull();
            }
        }

        WriteResult FailStream(long gid, int kind, int status, string message)
        {
            message = Text.Truncate(message, 400);
            var u = Q("UPDATE list_stream SET state=3,next_seq=0,stored_count=0,dup_count=0,declared_count=NULL,last_hash='',cursor='',http_status=@hs WHERE gid=@g AND kind=@k;");
            Set(u, "@hs", status); Set(u, "@g", gid); Set(u, "@k", kind);
            u.ExecuteNonQuery();
            var d = Q("DELETE FROM failure WHERE gid=@g AND kind=@k;");
            Set(d, "@g", gid); Set(d, "@k", kind); d.ExecuteNonQuery();
            var i = Q("INSERT INTO failure(gid,flow,kind,http_status,message) VALUES(@g,'',@k,@hs,@m);");
            Set(i, "@g", gid); Set(i, "@k", kind); Set(i, "@hs", status); Set(i, "@m", message);
            i.ExecuteNonQuery();
            _txRows += 3;
            PurgeEntries(gid, kind);
            return new WriteResult { Status = WriteStatus.Failed, Message = message };
        }

        public WriteResult ApplyListPage(string groupId, int kind, long seq, string hash, string[] ids, string[] values, string cursor, bool final, long declared)
        {
            RequireCollecting();
            long gid = GidOf(groupId);
            if (gid < 0) throw new ProtocolException("Page for an unregistered group (" + groupId + "): stream cannot be attributed.");
            var s = GetStream(gid, kind);
            if (!s.Found) throw new ProtocolException("Page for an unknown list kind " + Num(kind) + ".");
            if (s.State == (int)FlowState.Skipped) throw new ProtocolException("The list is not collected for this run (SkipMembers).");
            if (s.State == (int)FlowState.Complete)
            {
                if (seq == 0 || (seq == s.NextSeq - 1 && hash == s.LastHash)) return Replayed("The list is already complete (page replayed).");
                return Fail("The list is already complete; the page was ignored.");
            }
            if (s.State == (int)FlowState.Failed)
            {
                if (seq != 0) return Fail("The list has failed; restart it at page 0.");
                var d = Q("DELETE FROM failure WHERE gid=@g AND kind=@k;");
                Set(d, "@g", gid); Set(d, "@k", kind); d.ExecuteNonQuery();
                s = new StreamRow { Found = true, State = (int)FlowState.Pending, LastHash = "" };
            }
            else if (s.State == (int)FlowState.Collecting && seq == s.NextSeq - 1 && hash == s.LastHash) return Replayed("Page " + Num(seq) + " replayed (already committed).");
            else if (s.State == (int)FlowState.Pending && seq != 0) return FailStream(gid, kind, 0, "A list must start at page 0 (received page " + Num(seq) + ").");
            else if (seq != s.NextSeq)
                return FailStream(gid, kind, 0, "Checkpoint conflict: " + (seq == s.NextSeq - 1 ? "same page number with different content" : "expected page " + Num(s.NextSeq) + ", received " + Num(seq)) + ".");

            Exec("SAVEPOINT pg;");
            long inserted = 0, dups = 0;
            var ins = Q("INSERT INTO list_entry(gid,kind,entry_id,display_value) VALUES(@g,@k,@e,@v) ON CONFLICT(gid,kind,entry_id) DO NOTHING;");
            var get = Q("SELECT display_value FROM list_entry WHERE gid=@g AND kind=@k AND entry_id=@e;");
            for (int i = 0; i < ids.Length; i++)
            {
                Set(ins, "@g", gid); Set(ins, "@k", kind); Set(ins, "@e", ids[i]); Set(ins, "@v", values[i]);
                if (ins.ExecuteNonQuery() == 1) { inserted++; continue; }
                Set(get, "@g", gid); Set(get, "@k", kind); Set(get, "@e", ids[i]);
                if (Convert.ToString(get.ExecuteScalar(), CultureInfo.InvariantCulture) == values[i]) { dups++; continue; }
                Exec("ROLLBACK TO pg;");
                Exec("RELEASE pg;");
                return FailStream(gid, kind, 0, "Conflicting values for the same directory object id (" + ids[i] + ") in one list.");
            }
            Exec("RELEASE pg;");
            long stored = s.Stored + inserted, dup = s.Dup + dups;
            if (final && declared != stored + dup)
                return FailStream(gid, kind, 0, "Count mismatch: producer declared " + Num(declared) + " entries, " + Num(stored + dup) + " received.");
            var u = Q("UPDATE list_stream SET state=@st,next_seq=@ns,stored_count=@sc,dup_count=@dc,declared_count=@dl,last_hash=@h,cursor=@c,http_status=@hs WHERE gid=@g AND kind=@k;");
            Set(u, "@g", gid); Set(u, "@k", kind); Set(u, "@ns", seq + 1); Set(u, "@sc", stored); Set(u, "@dc", dup); Set(u, "@h", hash);
            if (final)
            {
                Set(u, "@st", (int)FlowState.Complete); Set(u, "@dl", declared); Set(u, "@hs", 200); Set(u, "@c", "");
            }
            else
            {
                Set(u, "@st", (int)FlowState.Collecting); Set(u, "@dl", null); Set(u, "@hs", 0); Set(u, "@c", Text.Truncate(cursor, 4096));
            }
            u.ExecuteNonQuery();
            _txRows += ids.Length + 1;
            return new WriteResult { Status = WriteStatus.Applied, Rows = inserted, Duplicates = dups };
        }

        public WriteResult FailList(string groupId, int kind, int status, string message)
        {
            RequireCollecting();
            long gid = GidOf(groupId);
            if (gid < 0) throw new ProtocolException("Failure for an unregistered group (" + groupId + "): stream cannot be attributed.");
            var s = GetStream(gid, kind);
            if (!s.Found) throw new ProtocolException("Failure for an unknown list kind " + Num(kind) + ".");
            if (s.State == (int)FlowState.Skipped) throw new ProtocolException("The list is not collected for this run (SkipMembers).");
            if (s.State == (int)FlowState.Complete) return Fail("The list is already complete; the failure was ignored.");
            return FailStream(gid, kind, status, message);
        }

        /// <summary>Marks every unfinished list of the given groups as failed (a worker died or did not answer for them).</summary>
        public WriteResult FailGroups(string[] groupIds, string message)
        {
            RequireCollecting();
            var gids = new List<long>();
            foreach (var id in groupIds)
            {
                long gid = GidOf(id);
                if (gid < 0) throw new ProtocolException("Failure for an unregistered group (" + id + ").");
                gids.Add(gid);
            }
            long n = 0;
            foreach (long gid in gids)
                foreach (int kind in new[] { 1, 2 })
                {
                    var s = GetStream(gid, kind);
                    if (s.Found && (s.State == (int)FlowState.Pending || s.State == (int)FlowState.Collecting)) { FailStream(gid, kind, 0, message); n++; }
                }
            return new WriteResult { Status = WriteStatus.Applied, Rows = n };
        }

        /// <summary>
        /// Removes a group that disappeared between the enumeration and the owners/members reads. Allowed only when one of its lists
        /// failed with HTTP 404 (the caller has re-checked that the group itself is gone); the removal is recorded in removed_group.
        /// </summary>
        public WriteResult RemoveGroup(string groupId, string reason)
        {
            RequireCollecting();
            long gid = GidOf(groupId);
            if (gid < 0) throw new ProtocolException("Cannot remove an unregistered group (" + groupId + ").");
            var chk = Q("SELECT COUNT(*) FROM failure WHERE gid=@g AND http_status=404;");
            Set(chk, "@g", gid);
            if (Convert.ToInt64(chk.ExecuteScalar(), CultureInfo.InvariantCulture) == 0)
                throw new ProtocolException("Group " + groupId + " has no HTTP 404 failure: only a group that disappeared can be removed.");
            var nm = Q("SELECT display_name FROM grp WHERE gid=@g;");
            Set(nm, "@g", gid);
            string name = Convert.ToString(nm.ExecuteScalar(), CultureInfo.InvariantCulture) ?? "";
            var rec = Q("INSERT INTO removed_group(group_id,display_name,reason) VALUES(@i,@n,@r) ON CONFLICT(group_id) DO UPDATE SET display_name=excluded.display_name,reason=excluded.reason;");
            Set(rec, "@i", groupId); Set(rec, "@n", name); Set(rec, "@r", Text.Truncate(reason, 400));
            rec.ExecuteNonQuery();
            PurgeEntries(gid, 1); PurgeEntries(gid, 2);
            Exec("DELETE FROM failure WHERE gid=" + Num(gid) + ";");
            Exec("DELETE FROM list_stream WHERE gid=" + Num(gid) + ";");
            Exec("DELETE FROM grp WHERE gid=" + Num(gid) + ";");
            _txRows += 6;
            return new WriteResult { Status = WriteStatus.Applied, Message = "Group removed from the inventory (disappeared)." };
        }

        public FailureRecord[] RemovedGroups(int max)
        {
            var list = new List<FailureRecord>();
            using (var c = _db.CreateCommand())
            {
                c.CommandText = "SELECT group_id,display_name,reason FROM removed_group ORDER BY group_id LIMIT @n;";
                c.Parameters.AddWithValue("@n", Math.Max(1, max));
                using (var r = c.ExecuteReader())
                    while (r.Read()) list.Add(new FailureRecord { GroupId = r.GetString(0), GroupName = r.GetString(1), Request = "removed", Status = 404, Message = r.GetString(2) });
            }
            return list.ToArray();
        }

        // ------------------------------------------------------------------ reads for the PowerShell host
        public WorkItem[] WorkBatch(long afterGid, int max)
        {
            var list = new List<WorkItem>();
            var c = Q("SELECT g.gid,g.group_id,g.display_name,(SELECT state FROM list_stream WHERE gid=g.gid AND kind=1),(SELECT state FROM list_stream WHERE gid=g.gid AND kind=2) " +
                      "FROM grp g WHERE g.gid>@a AND EXISTS (SELECT 1 FROM list_stream s WHERE s.gid=g.gid AND s.state IN (0,1,3)) ORDER BY g.gid LIMIT @n;");
            Set(c, "@a", afterGid); Set(c, "@n", Math.Max(1, max));
            using (var r = c.ExecuteReader())
                while (r.Read())
                {
                    long so = r.GetInt64(3), sm = r.GetInt64(4);
                    list.Add(new WorkItem
                    {
                        Gid = r.GetInt64(0), GroupId = r.GetString(1), DisplayName = r.GetString(2),
                        NeedOwners = so == 0 || so == 1 || so == 3, NeedMembers = sm == 0 || sm == 1 || sm == 3
                    });
                }
            return list.ToArray();
        }

        public FailureRecord[] Failures(int max)
        {
            var list = new List<FailureRecord>();
            using (var c = _db.CreateCommand())
            {
                c.CommandText = "SELECT COALESCE(g.group_id,''),COALESCE(g.display_name,''),f.flow,f.kind,f.http_status,f.message FROM failure f LEFT JOIN grp g ON g.gid=f.gid ORDER BY f.id LIMIT @n;";
                c.Parameters.AddWithValue("@n", Math.Max(1, max));
                using (var r = c.ExecuteReader())
                    while (r.Read())
                        list.Add(new FailureRecord { GroupId = r.GetString(0), GroupName = r.GetString(1), Request = r.GetInt64(3) == 0 ? r.GetString(2) : KindName((int)r.GetInt64(3)), Status = (int)r.GetInt64(4), Message = r.GetString(5) });
            }
            return list.ToArray();
        }

        static string KindName(int k) { return k == 1 ? "owners" : (k == 2 ? "members" : "flow"); }

        static FlowInfo ToInfo(string name, FlowRow f)
        {
            return new FlowInfo { Name = name, State = f.Found ? ((FlowState)f.State).ToString() : "Unknown", Pass = f.Pass, NextPage = f.NextPage, RowsSeen = f.Rows, Duplicates = f.Dup, Cursor = f.Cursor ?? "", Message = f.Message ?? "" };
        }

        public FlowInfo FlowInfoOf(string name) { return ToInfo(name, GetFlow(name)); }

        public RunInfo Info()
        {
            Commit();
            var i = new RunInfo
            {
                RunId = GetMeta("run_id"), State = _state, DatabasePath = DbPath, SqliteVersion = SqliteVersion, SkipMembers = _skipMembers,
                TenantId = GetMeta("tenant_id"), LegacyTenantHistoryUnverified = GetMeta("legacy_tenant_history_unverified") == "1",
                SitesRequired = GetMeta("sites_required") == "1", SchemaVersion = EngineInfo.SchemaVersion, ProtocolVersion = EngineInfo.ProtocolVersion,
                JournalMode = Convert.ToString(Scalar("PRAGMA journal_mode;"), CultureInfo.InvariantCulture),
                Groups = ScalarLong("SELECT COUNT(*) FROM grp;"), GroupsRemoved = ScalarLong("SELECT COUNT(*) FROM removed_group;"), CreatedUtc = GetMeta("created_utc"), SealedUtc = GetMeta("sealed_utc"),
                Enum = FlowInfoOf(EngineInfo.FlowEnum), Sites = FlowInfoOf(EngineInfo.FlowSites)
            };
            using (var c = _db.CreateCommand())
            {
                c.CommandText = "SELECT state,COUNT(*) FROM list_stream GROUP BY state;";
                using (var r = c.ExecuteReader())
                    while (r.Read())
                    {
                        long st = r.GetInt64(0), n = r.GetInt64(1);
                        if (st == 0) i.ListsPending = n; else if (st == 1) i.ListsCollecting = n; else if (st == 2) i.ListsComplete = n;
                        else if (st == 3) i.ListsFailed = n; else if (st == 4) i.ListsSkipped = n;
                    }
            }
            return i;
        }

        // ------------------------------------------------------------------ reconciliation, integrity, seal
        public ReconcileResult Reconcile()
        {
            Commit();
            var r = new ReconcileResult();
            r.Registered = ScalarLong("SELECT COUNT(*) FROM grp;");
            r.GroupsRemoved = ScalarLong("SELECT COUNT(*) FROM removed_group;");
            long lists = ScalarLong("SELECT COUNT(*) FROM list_stream;");
            var fe = GetFlow(EngineInfo.FlowEnum);
            var fs = GetFlow(EngineInfo.FlowSites);
            r.EnumState = ((FlowState)fe.State).ToString();
            r.SitesState = ((FlowState)fs.State).ToString();
            r.EnumRowsSeen = fe.Rows;
            using (var c = _db.CreateCommand())
            {
                c.CommandText = "SELECT kind,state,COUNT(*),SUM(CASE WHEN state=2 AND stored_count=0 THEN 1 ELSE 0 END),SUM(stored_count),SUM(dup_count) FROM list_stream GROUP BY kind,state;";
                using (var rd = c.ExecuteReader())
                    while (rd.Read())
                    {
                        int kind = (int)rd.GetInt64(0), st = (int)rd.GetInt64(1);
                        long n = rd.GetInt64(2), empty = rd.IsDBNull(3) ? 0 : rd.GetInt64(3), entries = rd.IsDBNull(4) ? 0 : rd.GetInt64(4), dup = rd.IsDBNull(5) ? 0 : rd.GetInt64(5);
                        if (st == 2)
                        {
                            r.ListsComplete += n; r.Duplicates += dup;
                            if (kind == 1) { r.VerifiedEmptyOwners += empty; r.OwnerEntries += entries; } else { r.VerifiedEmptyMembers += empty; r.MemberEntries += entries; }
                        }
                        else if (st == 3) r.ListsFailed += n;
                        else if (st == 4) { r.ListsSkipped += n; if (!(_skipMembers && kind == 2)) r.Mismatches += n; }
                        else r.ListsIncomplete += n;
                    }
            }
            long exact = ScalarLong(
                "SELECT COUNT(*) FROM list_stream ls WHERE ls.state=2 AND (ls.stored_count+ls.dup_count<>ls.declared_count OR " +
                "ls.stored_count<>(SELECT COUNT(*) FROM list_entry e WHERE e.gid=ls.gid AND e.kind=ls.kind));");
            if (exact > 0) { r.Mismatches += exact; r.Problems.Add(Num(exact) + " completed list(s) whose stored rows do not match the declared count."); }
            long stray = ScalarLong("SELECT COUNT(*) FROM list_stream ls WHERE ls.state<>2 AND EXISTS (SELECT 1 FROM list_entry e WHERE e.gid=ls.gid AND e.kind=ls.kind);");
            if (stray > 0) { r.Mismatches += stray; r.Problems.Add(Num(stray) + " incomplete list(s) still hold entries."); }
            if (lists != r.Registered * 2) { r.Mismatches++; r.Problems.Add("Stream count " + Num(lists) + " does not match 2 x " + Num(r.Registered) + " groups."); }
            long staleGroups = ScalarLong("SELECT COUNT(*) FROM grp WHERE pass<" + Num(fe.Pass) + ";");
            if (fe.State == (int)FlowState.Complete && staleGroups > 0) { r.Mismatches += staleGroups; r.Problems.Add(Num(staleGroups) + " group(s) were not confirmed by the final enumeration pass."); }
            r.Ownerless = r.VerifiedEmptyOwners;
            r.SiteRows = ScalarLong("SELECT COUNT(*) FROM site_url;");
            r.SiteOrphans = ScalarLong("SELECT COUNT(*) FROM site_url s WHERE NOT EXISTS (SELECT 1 FROM grp g WHERE g.group_id=s.group_id);");
            if (fe.State != (int)FlowState.Complete) r.Problems.Add("Group enumeration is " + r.EnumState + ".");
            bool sitesOk = fs.State == (int)FlowState.Complete || (fs.State == (int)FlowState.Skipped && GetMeta("sites_required") != "1");
            if (!sitesOk) r.Problems.Add("SharePoint site URL collection is " + r.SitesState + ".");
            if (fs.State == (int)FlowState.Complete && fs.Rows - fs.Dup != r.SiteRows) { r.Mismatches++; r.Problems.Add("Site URL rows (" + Num(r.SiteRows) + ") do not match received - duplicate rows (" + Num(fs.Rows - fs.Dup) + ")."); }
            foreach (var f in Failures(1000)) r.Failures.Add(f);
            using (var c = _db.CreateCommand())
            {
                c.CommandText = "SELECT g.group_id,g.display_name,ls.kind FROM list_stream ls JOIN grp g ON g.gid=ls.gid WHERE ls.state IN (0,1) ORDER BY ls.gid,ls.kind LIMIT 100;";
                using (var rd = c.ExecuteReader())
                    while (rd.Read())
                        r.Failures.Add(new FailureRecord { GroupId = rd.GetString(0), GroupName = rd.GetString(1), Request = KindName((int)rd.GetInt64(2)), Status = 0, Message = "List never completed (incomplete collection)." });
            }
            r.IsComplete = r.Mismatches == 0 && r.ListsFailed == 0 && r.ListsIncomplete == 0 && fe.State == (int)FlowState.Complete && sitesOk && r.Problems.Count == 0;
            r.Summary = string.Format(CultureInfo.InvariantCulture,
                "groups {0}; enumeration {1}; sites {2}; lists complete {3}, failed {4}, incomplete {5}, skipped {6}; verified-empty owners {7}, members {8}; duplicates removed {9}; mismatches {10}; groups removed (disappeared) {11}",
                r.Registered, r.EnumState, r.SitesState, r.ListsComplete, r.ListsFailed, r.ListsIncomplete, r.ListsSkipped, r.VerifiedEmptyOwners, r.VerifiedEmptyMembers, r.Duplicates, r.Mismatches, r.GroupsRemoved);
            return r;
        }

        /// <summary>Integrity gate: quick_check, foreign_key_check, policy and sidecars.</summary>
        public void VerifyIntegrity()
        {
            Commit();
            string qc = Convert.ToString(Scalar("PRAGMA quick_check;"), CultureInfo.InvariantCulture);
            if (qc != "ok") throw new IncompatibleDatabaseException("SQLite integrity check failed: " + Text.Truncate(qc, 200));
            using (var c = _db.CreateCommand())
            {
                c.CommandText = "PRAGMA foreign_key_check;";
                using (var r = c.ExecuteReader()) if (r.Read()) throw new IncompatibleDatabaseException("SQLite foreign key check failed.");
            }
            Expect("journal_mode", "delete", false);
            Expect("foreign_keys", "1", false);
            AssertNoSidecars(false);
        }

        public SealResult Seal()
        {
            RequireCollecting();
            var r = Reconcile();
            var res = new SealResult { Reconcile = r };
            if (!r.IsComplete)
            {
                res.Message = "The run is incomplete and was not sealed: " + r.Summary + (r.Problems.Count > 0 ? " | " + string.Join(" ", r.Problems) : "");
                return res;
            }
            VerifyIntegrity();
            Begin();
            SetMeta("sealed_groups", Num(r.Registered));
            SetMeta("sealed_entries", Num(r.OwnerEntries + r.MemberEntries));
            SetMeta("sealed_utc", DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture));
            SetMeta("state", EngineInfo.StateSealed);
            Commit();
            _state = EngineInfo.StateSealed;
            res.IsSealed = true;
            res.Message = "Sealed: " + r.Summary;
            return res;
        }

        public void Dispose()
        {
            Rollback();
            foreach (var c in _cmds.Values) c.Dispose();
            _cmds.Clear();
            if (_db != null) { _db.Dispose(); _db = null; }
        }

        /// <summary>Test hook: the connection is dropped without commit (SQLite discards the open transaction on close).</summary>
        public void Abandon()
        {
            _inTx = false;
            Dispose();
        }
    }
}
