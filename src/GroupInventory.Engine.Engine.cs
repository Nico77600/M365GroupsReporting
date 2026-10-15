// =============================================================================
//  Group Inventory engine, part 3: public engine API and the single writer thread
// -----------------------------------------------------------------------------
//  Threading model
//    - Any number of PowerShell runspaces/threads may call the public write methods.
//    - Inputs are validated, sanitised and hashed on the calling thread.
//    - Each write becomes an operation in ONE bounded queue (QueueCapacity). A full queue
//      blocks the producer (backpressure) and throws EngineBackpressureException after
//      EnqueueTimeoutMs.
//    - ONE writer thread owns the ONE SQLite write connection. It applies operations in order,
//      groups them into transactions bounded by TxMaxRows / TxMaxMs, commits, and only then
//      acknowledges the callers: a returned write is durable and its checkpoint is committed.
//    - Reads used by exports run on a separate read-only connection after the run is sealed.
//  Fault policy: an unexpected exception on the writer rolls back the open transaction and
//  faults the engine; every pending and later call throws EngineFaultedException. Restart the
//  process and resume the run: committed checkpoints are kept, nothing else is trusted.
// =============================================================================
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Threading;

namespace GroupInventory.Engine
{
    /// <summary>Loads the native SQLite library from the staged runtimes folder and initialises the SQLitePCLRaw provider once.</summary>
    internal static class SqliteRuntime
    {
        static readonly object Gate = new object();
        static bool _done;

        public static void EnsureInitialized()
        {
            lock (Gate)
            {
                if (_done) return;
                string dir = Path.GetDirectoryName(typeof(SqliteRuntime).Assembly.Location) ?? AppContext.BaseDirectory;
                if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) PreloadWindowsNative(dir);
                SQLitePCL.Batteries_V2.Init();
                _done = true;
            }
        }

        static void PreloadWindowsNative(string dir)
        {
            string rid;
            switch (RuntimeInformation.ProcessArchitecture)
            {
                case Architecture.X64: rid = "win-x64"; break;
                case Architecture.Arm64: rid = "win-arm64"; break;
                default: throw new EngineException("Unsupported process architecture for the bundled SQLite library: " + RuntimeInformation.ProcessArchitecture);
            }
            string[] candidates =
            {
                Path.Combine(dir, "runtimes", rid, "native", "e_sqlite3.dll"),
                Path.Combine(dir, "runtimes", rid, "e_sqlite3.dll"),
                Path.Combine(dir, "e_sqlite3.dll")
            };
            foreach (var c in candidates)
            {
                if (!File.Exists(c)) continue;
                NativeLibrary.Load(c);
                return;
            }
            throw new EngineException("The native SQLite library (e_sqlite3.dll for " + rid + ") was not found next to the engine. Run Build-Engine.ps1.");
        }
    }

    internal sealed class WriteOp
    {
        public Func<Store, object> Fn;
        public object Result;
        public Exception Error;
        public readonly ManualResetEventSlim Done = new ManualResetEventSlim(false);
    }

    public sealed partial class InventoryEngine : IDisposable
    {
        readonly EngineOptions _o;
        readonly bool _readOnly;
        readonly string _dbPath;
        readonly BlockingCollection<WriteOp> _q;
        readonly ManualResetEventSlim _ready = new ManualResetEventSlim(false);
        readonly bool _create;
        Thread _writer;
        Store _store;
        FileStream _lock;
        Exception _initError;
        volatile Exception _fault;
        volatile bool _disposed;
        volatile bool _abort;
        long _applied, _sanitized, _maxDepth, _transactions;

        InventoryEngine(EngineOptions o, bool create, bool readOnly)
        {
            if (o == null) throw new ArgumentNullException("o");
            if (string.IsNullOrWhiteSpace(o.DatabasePath)) throw new EngineException("DatabasePath is required.");
            if (o.QueueCapacity < 1 || o.EnqueueTimeoutMs < 1 || o.OperationTimeoutMs < 1 || o.MaxEntriesPerFrame < 1 || o.MaxFieldChars < 16 ||
                o.MaxFrameChars < 1024 || o.TxMaxRows < 1 || o.TxMaxMs < 1 || o.PurgeChunkRows < 1 || o.PageSize < 512)
                throw new EngineException("Invalid engine option (a bound is out of range).");
            _o = o;
            _create = create;
            _readOnly = readOnly;
            _dbPath = Path.GetFullPath(o.DatabasePath);
            if (readOnly) return;
            _q = new BlockingCollection<WriteOp>(new ConcurrentQueue<WriteOp>(), o.QueueCapacity);
            string dir = Path.GetDirectoryName(_dbPath);
            if (!Directory.Exists(dir)) throw new EngineException("The run directory does not exist.");
            try
            {
                _lock = new FileStream(_dbPath + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 1, FileOptions.DeleteOnClose);
            }
            catch (IOException e) { throw new EngineException("The inventory database is in use by another engine instance.", e); }
            _writer = new Thread(WriterMain) { IsBackground = true, Name = "GroupInventory.Writer" };
            _writer.Start();
            _ready.Wait();
            if (_initError != null)
            {
                var err = _initError;
                _writer.Join();
                ReleaseLock();
                ExceptionDispatchInfo.Capture(err).Throw();
            }
        }

        /// <summary>Starts a new run: the database file must not exist.</summary>
        public static InventoryEngine Create(EngineOptions o) { return new InventoryEngine(o, true, false); }

        /// <summary>Continues an existing run after verifying it; incomplete lists are reset to pending, completed work is kept.</summary>
        public static InventoryEngine Resume(EngineOptions o) { return new InventoryEngine(o, false, false); }

        /// <summary>Opens a run for reading only (exports of a sealed run). Writes throw RunStateException.</summary>
        public static InventoryEngine OpenSealed(EngineOptions o) { return new InventoryEngine(o, false, true); }

        public static RunInfo InspectSealedSnapshot(string databasePath)
        {
            using (var db = ReadOnlyDb.Open(databasePath, true)) return db.Info();
        }

        public WriteResult BindAuthenticatedTenant(string tenantId)
        {
            Guid id;
            if (!Guid.TryParse(tenantId, out id) || id == Guid.Empty) throw new ProtocolException("TenantId must be a nonempty GUID.");
            string canonical = id.ToString("D");
            return Submit<WriteResult>(s => s.BindAuthenticatedTenant(canonical), true);
        }

        public string DatabasePath { get { return _dbPath; } }

        void ReleaseLock()
        {
            var l = _lock;
            _lock = null;
            if (l != null) l.Dispose();
        }

        // ------------------------------------------------------------------ writer thread
        void WriterMain()
        {
            var pending = new List<WriteOp>();
            try
            {
                try { _store = _create ? Store.Create(_o) : Store.Open(_o); }
                catch (Exception e) { _initError = e; return; }
                finally { _ready.Set(); }
                if (_o.WriterGate != null) _o.WriterGate.Wait();
                for (;;)
                {
                    WriteOp op = null;
                    bool got;
                    try { got = _q.TryTake(out op, pending.Count > 0 ? 0 : Timeout.Infinite); }
                    catch (InvalidOperationException) { got = false; }
                    if (_abort)
                    {
                        if (got) pending.Add(op);
                        _store.Abandon(); _store = null;
                        FailAll(pending, new EngineFaultedException("The engine was aborted.", null));
                        return;
                    }
                    if (!got)
                    {
                        if (pending.Count > 0) { CommitPending(pending); continue; }
                        if (_q.IsCompleted) break;
                        continue;
                    }
                    try
                    {
                        _store.Begin();
                        object res = op.Fn(_store);
                        long n = Interlocked.Increment(ref _applied);
                        var wr = res as WriteResult;
                        if (wr != null) wr.Ack = n;
                        op.Result = res;
                        if (_o.TestCrashAtOp > 0 && n == _o.TestCrashAtOp)
                        {
                            if (!string.IsNullOrEmpty(_o.TestCrashImagePath)) _store.CopyCrashImage(_o.TestCrashImagePath);
                            throw new SimulatedCrashException("Simulated crash after operation " + n.ToString(System.Globalization.CultureInfo.InvariantCulture) + " (uncommitted).");
                        }
                        pending.Add(op);
                    }
                    catch (SimulatedCrashException e)
                    {
                        pending.Add(op);
                        _store.Abandon(); _store = null;
                        Fault(new EngineFaultedException(e.Message, e), pending);
                        return;
                    }
                    catch (EngineException e) when (!(e is EngineFaultedException))
                    {
                        // Contract violation detected before any write: only this operation fails.
                        op.Error = e;
                        op.Done.Set();
                        continue;
                    }
                    catch (Exception e)
                    {
                        pending.Add(op);
                        try { _store.Rollback(); } catch (Exception) { }
                        Fault(new EngineFaultedException("The inventory writer stopped: " + e.GetType().Name + ": " + e.Message, e), pending);
                        return;
                    }
                    if (_store.TxIsFull || _store.TxIsAged) CommitPending(pending);
                }
                CommitPending(pending);
            }
            catch (Exception e)
            {
                if (_store != null) { try { _store.Rollback(); } catch (Exception) { } }
                Fault(new EngineFaultedException("The inventory writer stopped: " + e.GetType().Name + ": " + e.Message, e), pending);
            }
            finally
            {
                if (_store != null) { Interlocked.Exchange(ref _transactions, _store.Transactions); _store.Dispose(); _store = null; }
                _ready.Set();
            }
        }

        void CommitPending(List<WriteOp> pending)
        {
            try { _store.Commit(); }
            catch (Exception e)
            {
                try { _store.Rollback(); } catch (Exception) { }
                Fault(new EngineFaultedException("Commit failed: " + e.GetType().Name + ": " + e.Message, e), pending);
                throw;
            }
            Interlocked.Exchange(ref _transactions, _store.Transactions);
            foreach (var p in pending) p.Done.Set();
            pending.Clear();
        }

        void Fault(Exception fault, List<WriteOp> pending)
        {
            _fault = fault;
            try { _q.CompleteAdding(); } catch (ObjectDisposedException) { }
            FailAll(pending, fault);
        }

        void FailAll(List<WriteOp> pending, Exception fault)
        {
            foreach (var p in pending) { p.Error = fault; p.Done.Set(); }
            pending.Clear();
            try { _q.CompleteAdding(); } catch (ObjectDisposedException) { }
            WriteOp rest;
            while (_q.TryTake(out rest)) { rest.Error = fault; rest.Done.Set(); }
        }

        T Submit<T>(Func<Store, object> fn, bool longRunning) where T : class
        {
            if (_readOnly) throw new RunStateException("This engine instance was opened read-only (sealed run).");
            if (_disposed) throw new ObjectDisposedException("InventoryEngine");
            var f = _fault;
            if (f != null) throw new EngineFaultedException(f.Message, f);
            var op = new WriteOp { Fn = fn };
            bool added;
            try { added = _q.TryAdd(op, _o.EnqueueTimeoutMs); }
            catch (InvalidOperationException)
            {
                f = _fault;
                if (f != null) throw new EngineFaultedException(f.Message, f);
                throw new ObjectDisposedException("InventoryEngine");
            }
            if (!added) throw new EngineBackpressureException("The bounded write queue stayed full for " + _o.EnqueueTimeoutMs.ToString(System.Globalization.CultureInfo.InvariantCulture) + " ms (backpressure).");
            long depth = _q.Count;
            long seen;
            while ((seen = Interlocked.Read(ref _maxDepth)) < depth && Interlocked.CompareExchange(ref _maxDepth, depth, seen) != seen) { }
            if (!op.Done.Wait(longRunning ? Timeout.Infinite : _o.OperationTimeoutMs))
                throw new EngineTimeoutException("The writer did not acknowledge within " + _o.OperationTimeoutMs.ToString(System.Globalization.CultureInfo.InvariantCulture) + " ms; the operation may still be applied (writes are idempotent, replay it).");
            if (op.Error != null) ExceptionDispatchInfo.Capture(op.Error).Throw();
            return (T)op.Result;
        }

        // ------------------------------------------------------------------ validation helpers (calling thread)
        string CleanField(string s, string field) { return Text.Clean(s, _o.MaxFieldChars, field, ref _sanitized); }

        static string RequireGuid(string id, string field)
        {
            string g = Text.CanonicalGuid(id);
            if (g == null) throw new ProtocolException("'" + field + "' is not a valid GUID.");
            return g;
        }

        static string CleanCursor(string cursor)
        {
            if (cursor == null) return "";
            if (cursor.Length > 4096) throw new ProtocolException("The cursor exceeds 4096 characters.");
            return cursor;
        }

        void CheckFrameSize(long chars)
        {
            if (chars > _o.MaxFrameChars) throw new ProtocolException("The frame exceeds " + _o.MaxFrameChars.ToString(System.Globalization.CultureInfo.InvariantCulture) + " characters.");
        }

        static string CleanFlowName(string name)
        {
            if (name == EngineInfo.FlowEnum || name == EngineInfo.FlowSites) return name;
            throw new ProtocolException("Unknown flow '" + name + "' (expected 'enum' or 'sites').");
        }

        static void CheckSeq(long seq) { if (seq < 0) throw new ProtocolException("The page sequence number must not be negative."); }

        // ------------------------------------------------------------------ public write API
        /// <summary>Records one page of the group enumeration with its checkpoint (page number + cursor). Duplicates by group id are idempotent.</summary>
        public WriteResult AddGroupPage(long pageSeq, GroupRecord[] groups, string cursor)
        {
            CheckSeq(pageSeq);
            if (groups == null) throw new ProtocolException("groups is required.");
            if (groups.Length > _o.MaxEntriesPerFrame) throw new ProtocolException("A group page holds at most " + _o.MaxEntriesPerFrame.ToString(System.Globalization.CultureInfo.InvariantCulture) + " entries.");
            cursor = CleanCursor(cursor);
            var clean = new GroupRecord[groups.Length];
            long chars = cursor.Length;
            string hash;
            using (var h = new Text.PageHasher())
            {
                for (int i = 0; i < groups.Length; i++)
                {
                    var g = groups[i];
                    if (g == null) throw new ProtocolException("A group record is null.");
                    var c = new GroupRecord
                    {
                        Id = RequireGuid(g.Id, "group id"),
                        DisplayName = CleanField(g.DisplayName, "displayName"),
                        Alias = CleanField(g.Alias, "alias"),
                        Mail = CleanField(g.Mail, "mail"),
                        Visibility = CleanField(g.Visibility, "visibility"),
                        IsTeam = g.IsTeam
                    };
                    chars += c.Id.Length + c.DisplayName.Length + c.Alias.Length + c.Mail.Length + c.Visibility.Length;
                    h.Add(c.Id); h.Add(c.DisplayName); h.Add(c.Alias); h.Add(c.Mail); h.Add(c.Visibility); h.Add(c.IsTeam ? "1" : "0"); h.EndRecord();
                    clean[i] = c;
                }
                hash = h.Finish();
            }
            CheckFrameSize(chars);
            return Submit<WriteResult>(s => s.ApplyGroupPage(pageSeq, hash, clean, cursor), false);
        }

        /// <summary>Records one page of SharePoint site URLs (group id, https URL). Same URL twice is a duplicate; two different URLs for one group fail the flow.</summary>
        public WriteResult AddSitePage(long pageSeq, string[] groupIds, string[] urls, string cursor)
        {
            CheckSeq(pageSeq);
            if (groupIds == null || urls == null || groupIds.Length != urls.Length) throw new ProtocolException("groupIds and urls must have the same length.");
            if (groupIds.Length > _o.MaxEntriesPerFrame) throw new ProtocolException("A site page holds at most " + _o.MaxEntriesPerFrame.ToString(System.Globalization.CultureInfo.InvariantCulture) + " entries.");
            cursor = CleanCursor(cursor);
            var ids = new string[groupIds.Length];
            var us = new string[groupIds.Length];
            long chars = cursor.Length;
            string hash;
            using (var h = new Text.PageHasher())
            {
                for (int i = 0; i < ids.Length; i++)
                {
                    ids[i] = RequireGuid(groupIds[i], "site group id");
                    string u = CleanField(urls[i], "url");
                    if (u.Length == 0 || !u.StartsWith("https://", StringComparison.OrdinalIgnoreCase) || u.IndexOf(' ') >= 0)
                        throw new ProtocolException("A site URL must be an absolute https URL without spaces.");
                    us[i] = u;
                    chars += ids[i].Length + u.Length;
                    h.Add(ids[i]); h.Add(u); h.EndRecord();
                }
                hash = h.Finish();
            }
            CheckFrameSize(chars);
            return Submit<WriteResult>(s => s.ApplySitePage(pageSeq, hash, ids, us, cursor), false);
        }

        /// <summary>
        /// Appends one page of a group's owners (kind 1) or members (kind 2). Page 0 starts the list; the page flagged
        /// final closes it and must carry the total number of entries the producer read (duplicates included).
        /// </summary>
        public WriteResult AppendListPage(string groupId, int kind, long pageSeq, string[] ids, string[] values, string cursor, bool isFinal, long declaredTotal)
        {
            CheckSeq(pageSeq);
            string gid = RequireGuid(groupId, "group id");
            if (kind != (int)ListKind.Owners && kind != (int)ListKind.Members) throw new ProtocolException("kind must be 1 (owners) or 2 (members).");
            if (kind == (int)ListKind.Members && _o.SkipMembers) throw new ProtocolException("Members are not collected for this run (SkipMembers).");
            if (ids == null || values == null || ids.Length != values.Length) throw new ProtocolException("ids and values must have the same length.");
            if (ids.Length > _o.MaxEntriesPerFrame) throw new ProtocolException("A list page holds at most " + _o.MaxEntriesPerFrame.ToString(System.Globalization.CultureInfo.InvariantCulture) + " entries.");
            if (declaredTotal < 0) throw new ProtocolException("declaredTotal must not be negative.");
            cursor = CleanCursor(cursor);
            var cid = new string[ids.Length];
            var cv = new string[ids.Length];
            long chars = cursor.Length;
            string hash;
            using (var h = new Text.PageHasher())
            {
                for (int i = 0; i < ids.Length; i++)
                {
                    cid[i] = RequireGuid(ids[i], "entry id");
                    string v = CleanField(values[i], "value");
                    cv[i] = string.IsNullOrWhiteSpace(v) ? cid[i] : v;
                    chars += cid[i].Length + cv[i].Length;
                    h.Add(cid[i]); h.Add(cv[i]); h.EndRecord();
                }
                hash = h.Finish();
            }
            CheckFrameSize(chars);
            return Submit<WriteResult>(s => s.ApplyListPage(gid, kind, pageSeq, hash, cid, cv, cursor, isFinal, declaredTotal), false);
        }

        /// <summary>Marks one list failed (the producer could not read it completely). Partial entries are discarded.</summary>
        public WriteResult FailList(string groupId, int kind, int status, string message)
        {
            string gid = RequireGuid(groupId, "group id");
            if (kind != (int)ListKind.Owners && kind != (int)ListKind.Members) throw new ProtocolException("kind must be 1 (owners) or 2 (members).");
            string m = CleanField(Text.Truncate(message, _o.MaxFieldChars), "message");
            return Submit<WriteResult>(s => s.FailList(gid, kind, status, m), false);
        }

        /// <summary>Marks every unfinished list of these groups failed (worker crash, missing batch answer...).</summary>
        public WriteResult FailGroups(string[] groupIds, string message)
        {
            if (groupIds == null) throw new ProtocolException("groupIds is required.");
            var ids = new string[groupIds.Length];
            for (int i = 0; i < ids.Length; i++) ids[i] = RequireGuid(groupIds[i], "group id");
            string m = CleanField(Text.Truncate(message, _o.MaxFieldChars), "message");
            return Submit<WriteResult>(s => s.FailGroups(ids, m), false);
        }

        /// <summary>Closes the 'enum' or 'sites' flow. declaredTotal must equal the number of rows received; stale groups of earlier passes are removed.</summary>
        public WriteResult CompleteFlow(string flow, long declaredTotal)
        {
            string f = CleanFlowName(flow);
            if (declaredTotal < 0) throw new ProtocolException("declaredTotal must not be negative.");
            return Submit<WriteResult>(s => s.CompleteFlow(f, declaredTotal), true);
        }

        public WriteResult MarkFlowFailed(string flow, string message)
        {
            string f = CleanFlowName(flow);
            string m = CleanField(Text.Truncate(message, _o.MaxFieldChars), "message");
            return Submit<WriteResult>(s => s.MarkFlowFailed(f, m), false);
        }

        /// <summary>Restarts a flow at page 0 (enum keeps its groups; sites clears its URLs).</summary>
        public WriteResult ResetFlow(string flow)
        {
            string f = CleanFlowName(flow);
            return Submit<WriteResult>(s => s.ResetFlow(f), true);
        }

        /// <summary>Removes a group whose lists failed with HTTP 404 after the caller verified that the group no longer exists (refused otherwise).</summary>
        public WriteResult RemoveGroup(string groupId, string reason)
        {
            string gid = RequireGuid(groupId, "group id");
            string m = CleanField(Text.Truncate(reason, _o.MaxFieldChars), "reason");
            return Submit<WriteResult>(s => s.RemoveGroup(gid, m), false);
        }

        public FailureRecord[] GetRemovedGroups(int max)
        {
            if (max < 1 || max > 100000) throw new ProtocolException("max must be between 1 and 100000.");
            if (_readOnly) throw new RunStateException("This engine instance was opened read-only.");
            return Submit<FailureRecord[]>(s => s.RemovedGroups(max), true);
        }

        // ------------------------------------------------------------------ public read API
        public FlowInfo GetFlow(string flow)
        {
            string f = CleanFlowName(flow);
            if (_readOnly) using (var r = ReadOnlyDb.Open(_dbPath, false)) return r.GetFlow(f);
            return Submit<FlowInfo>(s => s.FlowInfoOf(f), false);
        }

        public RunInfo Info()
        {
            if (_readOnly) using (var r = ReadOnlyDb.Open(_dbPath, false)) return r.Info();
            return Submit<RunInfo>(s => s.Info(), true);
        }

        /// <summary>Groups (ordered by internal id, after afterGid) that still have a pending, interrupted or failed list.</summary>
        public WorkItem[] GetWorkBatch(long afterGid, int max)
        {
            if (max < 1 || max > 10000) throw new ProtocolException("max must be between 1 and 10000.");
            return Submit<WorkItem[]>(s => s.WorkBatch(afterGid, max), false);
        }

        public FailureRecord[] GetFailures(int max)
        {
            if (max < 1 || max > 100000) throw new ProtocolException("max must be between 1 and 100000.");
            return Submit<FailureRecord[]>(s => s.Failures(max), true);
        }

        /// <summary>Exact reconciliation of the run; changes nothing.</summary>
        public ReconcileResult Reconcile() { return Submit<ReconcileResult>(s => s.Reconcile(), true); }

        /// <summary>Reconciles, runs the integrity gate and seals the run only when everything is complete. A sealed run is immutable.</summary>
        public SealResult Seal() { return Submit<SealResult>(s => s.Seal(), true); }

        public EngineSummary Summary()
        {
            var info = Info();
            return new EngineSummary
            {
                SqliteVersion = info.SqliteVersion, JournalMode = info.JournalMode, State = info.State, SchemaVersion = info.SchemaVersion,
                ProtocolVersion = info.ProtocolVersion, Groups = info.Groups, Operations = Interlocked.Read(ref _applied),
                Transactions = Interlocked.Read(ref _transactions), SanitizedFields = Interlocked.Read(ref _sanitized), MaxQueueDepth = Interlocked.Read(ref _maxDepth)
            };
        }

        public long OperationsApplied { get { return Interlocked.Read(ref _applied); } }
        public long MaxQueueDepth { get { return Interlocked.Read(ref _maxDepth); } }
        public bool IsFaulted { get { return _fault != null; } }

        // ------------------------------------------------------------------ lifecycle
        /// <summary>Drains the queue, commits, and closes the single write connection.</summary>
        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            if (_writer != null)
            {
                try { _q.CompleteAdding(); } catch (ObjectDisposedException) { }
                if (_o.WriterGate != null) _o.WriterGate.Set();
                _writer.Join();
                _q.Dispose();
            }
            ReleaseLock();
        }

        /// <summary>Tests only: stops the writer without committing the open transaction, like a killed process.</summary>
        public void AbortForTest()
        {
            if (_disposed) return;
            _abort = true;
            _disposed = true;
            if (_writer != null)
            {
                try { _q.CompleteAdding(); } catch (ObjectDisposedException) { }
                if (_o.WriterGate != null) _o.WriterGate.Set();
                _writer.Join();
                _q.Dispose();
            }
            ReleaseLock();
        }
    }
}
