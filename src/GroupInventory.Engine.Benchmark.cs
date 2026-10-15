// =============================================================================
//  Group Inventory engine, part 5: synthetic load (benchmark and multi-thread test support)
// -----------------------------------------------------------------------------
//  Generates deterministic fake groups, owners, members and site URLs (example.test only), pushes
//  them through the public engine API from several threads, seals the run and exports it. Used
//  by the offline tests and by Test-EngineBenchmark; it never touches a network or a tenant.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Threading;

namespace GroupInventory.Engine
{
    public sealed class BenchmarkResult
    {
        public long Groups, ListEntries, TotalObjects, Operations, Transactions, MaxQueueDepth, CsvBytes, HtmlParts, DatabaseBytes;
        public double WriteSeconds, SealSeconds, CsvSeconds, HtmlSeconds, PeakManagedMb; // managed heap growth during the run (MB)
        public bool Sealed;
        public string CsvPath = "", HtmlPath = "", DatabasePath = "";
    }

    public static class SyntheticBenchmark
    {
        public static Guid Id(long n, int salt)
        {
            return new Guid((int)(n & 0x7FFFFFFF), (short)((n >> 31) & 0x7FFF), (short)salt, 0x47, 0x49, 0x4E, 0x56, 0, 0, 0, 1);
        }

        public static string GroupName(long i)
        {
            if (i % 11 == 0) return "\u00C9quipe \"\u00DCn\u00EFc\u00F6de\", \u65E5\u672C\u8A9E \uD83D\uDE00 #" + i.ToString(CultureInfo.InvariantCulture);
            if (i % 13 == 0) return "=HYPERLINK(\"https://example.test\") " + i.ToString(CultureInfo.InvariantCulture);
            return "Group " + i.ToString(CultureInfo.InvariantCulture);
        }

        static string UserName(long n)
        {
            if (n % 97 == 0) return "zo\u00EB.m\u00FCller" + n.ToString(CultureInfo.InvariantCulture) + "@example.test";
            return "user" + n.ToString(CultureInfo.InvariantCulture) + "@example.test";
        }

        public static BenchmarkResult Run(string directory, int groups, int ownersPerGroup, int membersPerGroup, int threads, int queueCapacity)
        {
            if (groups < 1 || ownersPerGroup < 0 || membersPerGroup < 0 || threads < 1) throw new ArgumentException("Invalid benchmark size.");
            Directory.CreateDirectory(directory);
            var res = new BenchmarkResult { DatabasePath = Path.Combine(directory, "bench.sqlite"), CsvPath = Path.Combine(directory, "bench.csv"), HtmlPath = Path.Combine(directory, "bench.html") };
            var o = new EngineOptions { DatabasePath = res.DatabasePath, RunId = "bench", QueueCapacity = queueCapacity };
            long pool = Math.Max(2000, (long)membersPerGroup * 4);
            double baseline = GC.GetTotalMemory(true) / 1048576.0;
            double peak = baseline;
            bool stop = false;
            var sampler = new Thread(() =>
            {
                while (!stop)
                {
                    double mb = GC.GetTotalMemory(false) / 1048576.0;
                    if (mb > peak) peak = mb;
                    Thread.Sleep(40);
                }
            }) { IsBackground = true };
            sampler.Start();
            var sw = Stopwatch.StartNew();
            using (var e = InventoryEngine.Create(o))
            {
                // enumeration
                var page = new List<GroupRecord>();
                long seq = 0;
                for (long i = 0; i < groups; i++)
                {
                    page.Add(new GroupRecord { Id = Id(i, 1).ToString("D"), DisplayName = GroupName(i), Alias = "g" + i.ToString(CultureInfo.InvariantCulture), Mail = "g" + i.ToString(CultureInfo.InvariantCulture) + "@example.test", Visibility = (i % 2 == 0) ? "Private" : "Public", IsTeam = i % 5 == 0 });
                    if (page.Count == 1000 || i == groups - 1)
                    {
                        Require(e.AddGroupPage(seq++, page.ToArray(), ""), "group page");
                        page.Clear();
                    }
                }
                Require(e.CompleteFlow(EngineInfo.FlowEnum, groups), "complete enum");
                // sites: one in three groups
                var ids = new List<string>(); var urls = new List<string>();
                long sseq = 0, sites = 0;
                for (long i = 0; i < groups; i += 3)
                {
                    ids.Add(Id(i, 1).ToString("D")); urls.Add("https://example.test/sites/g" + i.ToString(CultureInfo.InvariantCulture)); sites++;
                    if (ids.Count == 1000) { Require(e.AddSitePage(sseq++, ids.ToArray(), urls.ToArray(), ""), "site page"); ids.Clear(); urls.Clear(); }
                }
                if (ids.Count > 0) Require(e.AddSitePage(sseq++, ids.ToArray(), urls.ToArray(), ""), "site page");
                Require(e.CompleteFlow(EngineInfo.FlowSites, sites), "complete sites");
                // lists, from several threads
                Exception error = null;
                var ts = new List<Thread>();
                for (int t = 0; t < threads; t++)
                {
                    int ti = t;
                    var th = new Thread(() =>
                    {
                        try
                        {
                            for (long g = ti; g < groups; g += threads)
                            {
                                WriteList(e, Id(g, 1).ToString("D"), 1, g, ownersPerGroup, pool, 500);
                                WriteList(e, Id(g, 1).ToString("D"), 2, g, membersPerGroup, pool, 500);
                            }
                        }
                        catch (Exception ex) { error = ex; }
                    }) { IsBackground = true };
                    ts.Add(th); th.Start();
                }
                foreach (var th in ts) th.Join();
                if (error != null) throw new EngineException("Benchmark worker failed: " + error.Message, error);
                res.WriteSeconds = sw.Elapsed.TotalSeconds;
                sw.Restart();
                var seal = e.Seal();
                res.SealSeconds = sw.Elapsed.TotalSeconds;
                res.Sealed = seal.IsSealed;
                if (!seal.IsSealed) throw new EngineException("Benchmark run did not seal: " + seal.Message);
                res.Groups = groups;
                res.ListEntries = seal.Reconcile.OwnerEntries + seal.Reconcile.MemberEntries;
                res.TotalObjects = res.Groups + res.ListEntries;
                sw.Restart();
                var csv = e.ExportCsv(new ExportOptions { Path = res.CsvPath, Overwrite = true });
                res.CsvSeconds = sw.Elapsed.TotalSeconds; res.CsvBytes = csv.Bytes;
                sw.Restart();
                var html = e.ExportHtml(new ExportOptions { Path = res.HtmlPath, Overwrite = true, HtmlRowsPerPart = 1000 });
                res.HtmlSeconds = sw.Elapsed.TotalSeconds; res.HtmlParts = html.Parts;
                res.Operations = e.OperationsApplied;
                res.MaxQueueDepth = e.MaxQueueDepth;
                res.Transactions = e.Summary().Transactions;
            }
            stop = true;
            sampler.Join();
            res.PeakManagedMb = Math.Max(0, peak - baseline);
            res.DatabaseBytes = new FileInfo(res.DatabasePath).Length;
            return res;
        }

        static void WriteList(InventoryEngine e, string gid, int kind, long g, int count, long pool, int pageSize)
        {
            long seq = 0; int done = 0;
            do
            {
                int n = Math.Min(pageSize, count - done);
                var ids = new string[n]; var vals = new string[n];
                for (int i = 0; i < n; i++)
                {
                    long u = (g * 7 + done + i) % pool;
                    ids[i] = Id(u, kind + 1).ToString("D"); vals[i] = UserName(u);
                }
                done += n;
                bool final = done >= count;
                Require(e.AppendListPage(gid, kind, seq++, ids, vals, final ? "" : "https://graph.example.test/next", final, count), "list page");
            } while (done < count);
        }

        static void Require(WriteResult r, string what)
        {
            if (r.Status == WriteStatus.Failed) throw new EngineException("Benchmark " + what + " failed: " + r.Message);
        }
    }
}
