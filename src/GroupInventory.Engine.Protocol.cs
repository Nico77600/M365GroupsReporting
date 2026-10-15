// =============================================================================
//  Group Inventory engine, part 1: public contract (types, options, results, exceptions)
// -----------------------------------------------------------------------------
//  The engine is a passive, offline component hosted in the PowerShell process.
//  PowerShell owns configuration, authentication and every Graph/SharePoint call; this
//  assembly never receives a credential or a token and has no network code.
//  Only non-secret typed records cross the boundary.
//
//  Streams ("flows"):
//    enum   : the group enumeration (page checkpoints: page sequence, content hash, cursor)
//    sites  : the SharePoint site URL source (page checkpoints)
//    lists  : one owners and one members stream per group (page sequence, hash, cursor)
//  A write is acknowledged only after the transaction that contains it (and its checkpoint) is
//  committed. A page replayed with the same sequence and content is idempotent; a page with the
//  same sequence and different content, or with a gap, is a conflict and fails the stream.
//  A run is sealed only when every flow and every list is complete and reconciled; exports are
//  refused for any run that is not sealed.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace GroupInventory.Engine
{
    public static class EngineInfo
    {
        public const int ProtocolVersion = 1;
        public const int SchemaVersion = 1;
        public const int ApplicationId = 0x47494E56; // 'GINV'
        public const string ToolName = "GroupInventory.Engine";
        public const string FlowEnum = "enum";
        public const string FlowSites = "sites";
        public const string StateCollecting = "collecting";
        public const string StateSealed = "sealed";
    }

    /// <summary>Collection state of a flow or of one list (owners or members) of one group.</summary>
    public enum FlowState { Pending = 0, Collecting = 1, Complete = 2, Failed = 3, Skipped = 4 }

    public enum ListKind { Owners = 1, Members = 2 }

    public enum WriteStatus { Applied = 0, Replayed = 1, Failed = 2 }

    public class EngineException : Exception
    {
        public EngineException(string message) : base(message) { }
        public EngineException(string message, Exception inner) : base(message, inner) { }
    }

    /// <summary>A call that breaks the contract (bounds, identity, unregistered stream); nothing was stored.</summary>
    public sealed class ProtocolException : EngineException
    {
        public ProtocolException(string message) : base(message) { }
    }

    /// <summary>The engine stopped after an unrecoverable fault; every later call throws this.</summary>
    public sealed class EngineFaultedException : EngineException
    {
        public EngineFaultedException(string message, Exception inner) : base(message, inner) { }
    }

    /// <summary>The bounded write queue stayed full for longer than EnqueueTimeoutMs (backpressure).</summary>
    public sealed class EngineBackpressureException : EngineException
    {
        public EngineBackpressureException(string message) : base(message) { }
    }

    /// <summary>The writer did not acknowledge within OperationTimeoutMs; the operation may still be applied later (writes are idempotent).</summary>
    public sealed class EngineTimeoutException : EngineException
    {
        public EngineTimeoutException(string message) : base(message) { }
    }

    /// <summary>The run is sealed (immutable) or not sealed when a sealed run is required.</summary>
    public sealed class RunStateException : EngineException
    {
        public RunStateException(string message) : base(message) { }
    }

    /// <summary>The database is not a Group Inventory run, is corrupt, or has an unsupported schema/protocol version.</summary>
    public sealed class IncompatibleDatabaseException : EngineException
    {
        public IncompatibleDatabaseException(string message) : base(message) { }
        public IncompatibleDatabaseException(string message, Exception inner) : base(message, inner) { }
    }

    /// <summary>Tests only: raised by the crash simulation hook.</summary>
    public sealed class SimulatedCrashException : Exception
    {
        public SimulatedCrashException(string message) : base(message) { }
    }

    public sealed class EngineOptions
    {
        public string DatabasePath;
        public string RunId;
        public bool SkipMembers;
        public bool SitesRequired = true;
        /// <summary>Resume only: take SkipMembers from the database instead of requiring the caller to repeat it.</summary>
        public bool AdoptRunSettings;
        public int QueueCapacity = 64;
        public int EnqueueTimeoutMs = 60000;
        public int OperationTimeoutMs = 300000;
        public int MaxEntriesPerFrame = 1000;
        public int MaxFieldChars = 2048;
        public int MaxFrameChars = 1048576;
        public int TxMaxRows = 5000;
        public int TxMaxMs = 250;
        public int PurgeChunkRows = 5000;
        public int PageSize = 8192;
        public int CacheKb = 16384;
        /// <summary>Tests only: the writer thread waits for this gate before applying the first operation.</summary>
        public ManualResetEventSlim WriterGate;
        /// <summary>Tests only: after applying this operation (1-based, uncommitted) a crash image of the database is copied to TestCrashImagePath and the engine dies without committing.</summary>
        public long TestCrashAtOp;
        public string TestCrashImagePath;
    }

    public sealed class GroupRecord
    {
        public string Id = "";
        public string DisplayName = "";
        public string Alias = "";
        public string Mail = "";
        public string Visibility = "";
        public bool IsTeam;
    }

    public sealed class WriteResult
    {
        public WriteStatus Status;
        public string Message = "";
        public long Ack;
        public long Rows;
        public long Duplicates;
        public bool IsFailed { get { return Status == WriteStatus.Failed; } }
    }

    public sealed class FlowInfo
    {
        public string Name = "";
        public string State = "";
        public long Pass, NextPage, RowsSeen, Duplicates;
        public string Cursor = "";
        public string Message = "";
    }

    public sealed class RunInfo
    {
        public string RunId = "", State = "", DatabasePath = "", SqliteVersion = "", JournalMode = "";
        public bool SkipMembers, SitesRequired;
        public int SchemaVersion, ProtocolVersion;
        public long Groups, GroupsRemoved, ListsPending, ListsCollecting, ListsComplete, ListsFailed, ListsSkipped;
        public string CreatedUtc = "", SealedUtc = "";
        public string TenantId = "";
        public bool LegacyTenantHistoryUnverified;
        public FlowInfo Enum, Sites;
    }

    public sealed class WorkItem
    {
        public long Gid;
        public string GroupId = "", DisplayName = "";
        public bool NeedOwners, NeedMembers;
    }

    public sealed class FailureRecord
    {
        public string GroupId = "", GroupName = "", Request = "", Message = "";
        public int Status;
    }

    public sealed class ReconcileResult
    {
        public bool IsComplete;
        public string EnumState = "", SitesState = "";
        public long Registered, EnumRowsSeen, GroupsRemoved;
        public long ListsComplete, ListsFailed, ListsIncomplete, ListsSkipped;
        public long VerifiedEmptyOwners, VerifiedEmptyMembers;
        public long OwnerEntries, MemberEntries, Duplicates;
        public long Ownerless;
        public long Mismatches;
        public long SiteRows, SiteOrphans;
        public List<string> Problems = new List<string>();
        public List<FailureRecord> Failures = new List<FailureRecord>();
        public string Summary = "";
    }

    public sealed class SealResult
    {
        public bool IsSealed;
        public string Message = "";
        public ReconcileResult Reconcile;
    }

    public sealed class ExportOptions
    {
        public string Path = "";
        public bool Overwrite;
        public bool NeutralizeFormulas = true;
        public string CsvDelimiter = ",";
        public string Title = "M365 groups inventory";
        public string CompanyName = "";
        public string TimeZone = "Europe/Paris";
        public bool ShowTenantInformation;
        public string TenantId = "", Organization = "", EnvironmentName = "";
        public string TenantIdentitySource = "Configuration only (unverified snapshot)";
        public bool LegacyTenantHistoryUnverified;
        public int HtmlRowsPerPart = 10000;
        /// <summary>HTML only: write one self-contained report file instead of a static index plus part files.</summary>
        public bool HtmlSingleFile;
        public int HtmlMaxRelationsPerCell = 25;
        /// <summary>HTML only: number of complete group records per compressed browser chunk.</summary>
        public int HtmlChunkRows = 250;
        /// <summary>HTML only: template path. Empty uses the template copied beside the engine assembly.</summary>
        public string HtmlTemplatePath = "";
        /// <summary>Legacy HTML option: companion CSV file name, retained for protocol compatibility.</summary>
        public string CompanionCsv = "";
        /// <summary>Tests only: injects an I/O failure at this promotion step of an HTML export (1 = old export set aside, 2 = parts published) to prove the rollback.</summary>
        public int TestFailPromotionAt;
    }

    public sealed class ExportResult
    {
        public string Path = "", Format = "", Sha256 = "";
        public long RowsWritten, RowsTotal, Bytes, FormulaNeutralized, Parts, RelationsTruncated;
    }

    public sealed class EngineSummary
    {
        public string SqliteVersion = "", JournalMode = "", State = "";
        public int SchemaVersion, ProtocolVersion;
        public long Groups, Operations, Transactions, SanitizedFields, MaxQueueDepth;
    }

    internal static class Text
    {
        /// <summary>Canonical identity: lowercase hyphenated GUID. Null when the value is not a GUID.</summary>
        public static string CanonicalGuid(string s)
        {
            if (string.IsNullOrEmpty(s)) return null;
            Guid g;
            if (!Guid.TryParseExact(s.Trim(), "D", out g)) return null;
            return g.ToString("D", CultureInfo.InvariantCulture);
        }

        /// <summary>
        /// Bounds and normalises a text field: C0/C1 controls and line/paragraph separators become a space,
        /// an unpaired surrogate becomes U+FFFD. Longer than max is a protocol error (never silently truncated).
        /// </summary>
        public static string Clean(string s, int max, string field, ref long sanitized)
        {
            if (string.IsNullOrEmpty(s)) return "";
            if (s.Length > max) throw new ProtocolException("Field '" + field + "' exceeds " + max.ToString(CultureInfo.InvariantCulture) + " characters.");
            StringBuilder sb = null;
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                char r = c;
                if (c < 0x20 || (c >= 0x7F && c <= 0x9F) || c == '\u2028' || c == '\u2029') r = ' ';
                else if (char.IsHighSurrogate(c))
                {
                    if (i + 1 < s.Length && char.IsLowSurrogate(s[i + 1]))
                    {
                        if (sb != null) { sb.Append(c); sb.Append(s[i + 1]); }
                        i++;
                        continue;
                    }
                    r = '\uFFFD';
                }
                else if (char.IsLowSurrogate(c)) r = '\uFFFD';
                if (r != c)
                {
                    if (sb == null) { sb = new StringBuilder(s.Length); sb.Append(s, 0, i); }
                    Interlocked.Increment(ref sanitized);
                }
                if (sb != null) sb.Append(r);
            }
            return sb == null ? s : sb.ToString();
        }

        public static string Truncate(string s, int max)
        {
            if (s == null) return "";
            return s.Length <= max ? s : s.Substring(0, max);
        }

        /// <summary>Incremental SHA-256 over text fields (content hash of a page, used for replay/conflict detection).</summary>
        public sealed class PageHasher : IDisposable
        {
            readonly IncrementalHash _h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            public void Add(string s)
            {
                _h.AppendData(Encoding.UTF8.GetBytes(s ?? ""));
                _h.AppendData(new byte[] { 0x1F });
            }
            public void EndRecord() { _h.AppendData(new byte[] { 0x1E }); }
            public string Finish()
            {
                byte[] d = _h.GetHashAndReset();
                var sb = new StringBuilder(d.Length * 2);
                foreach (byte b in d) sb.Append(b.ToString("x2", CultureInfo.InvariantCulture));
                return sb.ToString();
            }
            public void Dispose() { _h.Dispose(); }
        }
    }
}
