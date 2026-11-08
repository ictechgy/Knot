// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Knot.NativePreview
{
    internal sealed class NativeUpdateConfiguration
    {
        internal readonly string Version, MacFeed, WindowsFeed;
        internal readonly byte[] Modulus, Exponent;
        internal bool Configured { get { return MacFeed.Length > 0 && WindowsFeed.Length > 0 && Modulus.Length == 256 && Exponent.Length == 3; } }
        internal NativeUpdateConfiguration(string text)
        {
            string[] a = text.Split('\n');
            if (a.Length != 6 || a[5] != "") throw new InvalidDataException();
            NativeUpdateManifest.VersionBuild(a[0]); Version = a[0]; MacFeed = a[1]; WindowsFeed = a[2];
            if (a[1] == "" && a[2] == "" && a[3] == "" && a[4] == "") { Modulus = new byte[0]; Exponent = new byte[0]; return; }
            NativeUpdateManifest.Https(MacFeed); NativeUpdateManifest.Https(WindowsFeed);
            Modulus = NativeUpdateManifest.CanonicalBase64(a[3]); Exponent = NativeUpdateManifest.CanonicalBase64(a[4]);
            if (Modulus.Length != 256 || Modulus[0] < 128 || Modulus[255] % 2 != 1 || Exponent.Length != 3 ||
                Exponent[0] != 1 || Exponent[1] != 0 || Exponent[2] != 1) throw new InvalidDataException();
        }
        internal static NativeUpdateConfiguration Load()
        {
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("KnotNativeUpdateConfig"))
            { if (s == null || s.Length > 16384) return null; using (var r = new StreamReader(s, Encoding.UTF8, false)) return new NativeUpdateConfiguration(r.ReadToEnd()); }
        }
    }
    internal sealed class NativeUpdateManifest
    {
        internal const long MaximumBytes = 512L * 1024 * 1024;
        internal readonly string Version, Platform, Hash;
        internal readonly ulong Build;
        internal readonly long Bytes, Expires;
        internal readonly Uri Url;
        private NativeUpdateManifest(string version, ulong build, string platform, Uri url, long bytes, string hash, long expires)
        { Version = version; Build = build; Platform = platform; Url = url; Bytes = bytes; Hash = hash; Expires = expires; }
        internal static byte[] CanonicalBase64(string text)
        { byte[] raw = Convert.FromBase64String(text); if (Convert.ToBase64String(raw) != text) throw new InvalidDataException(); return raw; }
        internal static ulong VersionBuild(string text)
        {
            if (!System.Text.RegularExpressions.Regex.IsMatch(text, @"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-native\.([1-9][0-9]*)\z")) throw new InvalidDataException();
            string[] a = text.Replace("-native.", ".").Split('.'); ulong build = 0;
            foreach (string s in a) { uint n; if (!UInt32.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out n) || n > 65535) throw new InvalidDataException(); build = (build << 16) | n; }
            return build;
        }
        internal static Uri Https(string text)
        {
            if (String.IsNullOrEmpty(text)) throw new InvalidDataException();
            foreach (char c in text) if (c <= 32 || c >= 127) throw new InvalidDataException();
            Uri u;
            if (!Uri.TryCreate(text, UriKind.Absolute, out u) || u.Scheme != "https" || u.Port != 443 || u.UserInfo != "" ||
                u.Query != "" || u.Fragment != "" || u.IsLoopback || u.Host == "") throw new InvalidDataException();
            return u;
        }
        internal static NativeUpdateManifest Verify(byte[] envelope, NativeUpdateConfiguration c, string platform, long now)
        {
            if (c == null || !c.Configured || envelope.Length > 16384) throw new InvalidDataException();
            foreach (byte b in envelope) if (b > 127) throw new InvalidDataException();
            string[] outer = Encoding.ASCII.GetString(envelope).Split('\n');
            if (outer.Length != 3 || outer[2] != "") throw new InvalidDataException();
            byte[] body = CanonicalBase64(outer[0]), signature = CanonicalBase64(outer[1]);
            if (signature.Length != 256) throw new InvalidDataException();
            using (var rsa = new RSACryptoServiceProvider())
            { rsa.PersistKeyInCsp = false; rsa.ImportParameters(new RSAParameters { Modulus = c.Modulus, Exponent = c.Exponent }); if (!rsa.VerifyData(body, CryptoConfig.MapNameToOID("SHA256"), signature)) throw new InvalidDataException(); }
            foreach (byte b in body) if (b > 127) throw new InvalidDataException();
            string[] a = Encoding.ASCII.GetString(body).Split('\n'); ulong build; long size, expiry;
            if (a.Length != 9 || a[8] != "" || a[0] != "KNOT-NATIVE-UPDATE-1" || a[3] != platform ||
                (platform != "windows-x64" && platform != "macos-arm64") ||
                !UInt64.TryParse(a[2], NumberStyles.None, CultureInfo.InvariantCulture, out build) || build.ToString(CultureInfo.InvariantCulture) != a[2] || build != VersionBuild(a[1]) ||
                !Int64.TryParse(a[5], NumberStyles.None, CultureInfo.InvariantCulture, out size) || size.ToString(CultureInfo.InvariantCulture) != a[5] || size < 1 || size > MaximumBytes ||
                !System.Text.RegularExpressions.Regex.IsMatch(a[6], @"\A[0-9a-f]{64}\z") ||
                !Int64.TryParse(a[7], NumberStyles.None, CultureInfo.InvariantCulture, out expiry) || expiry.ToString(CultureInfo.InvariantCulture) != a[7]) throw new InvalidDataException();
            Uri url = Https(a[4]); string suffix = platform == "windows-x64" ? "-windows-x64-setup.exe" : "-macos-arm64.zip";
            if (a[4].Substring(a[4].LastIndexOf('/') + 1) != "Knot-Native-" + a[1] + suffix || expiry <= now || expiry - now > 30 * 86400) throw new InvalidDataException();
            if (build <= VersionBuild(c.Version)) throw new NativeUpdateCurrentException();
            return new NativeUpdateManifest(a[1], build, platform, url, size, a[6], expiry);
        }
        internal void VerifyFile(string path)
        {
            NativeUpdatePaths.Ordinary(path);
            using (var s = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var hash = SHA256.Create())
            { if (s.Length != Bytes || BitConverter.ToString(hash.ComputeHash(s)).Replace("-", "").ToLowerInvariant() != Hash) throw new InvalidDataException(); }
        }
        internal static long Now { get { return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalSeconds; } }
    }
    internal sealed class NativeUpdateCurrentException : Exception { }
    internal static class NativeUpdatePaths
    {
        internal static string CreateStage()
        {
            string path = Path.Combine(Path.GetTempPath(), "knot-native-update-" + Guid.NewGuid().ToString("N"));
            SecurityIdentifier user; using (var identity = WindowsIdentity.GetCurrent()) user = identity.User;
            var acl = new DirectorySecurity(); acl.SetOwner(user); acl.SetAccessRuleProtection(true, false);
            acl.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            Directory.CreateDirectory(path, acl); ValidateStage(path); return path;
        }
        internal static void Ordinary(string path)
        {
            string full = Path.GetFullPath(path);
            if (full.StartsWith("\\\\", StringComparison.Ordinal)) throw new InvalidDataException();
            for (string at = full; at != null; at = Path.GetDirectoryName(at))
                if ((File.GetAttributes(at) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException();
        }
        internal static void ValidateStage(string path)
        {
            Ordinary(path);
            if (Path.GetDirectoryName(Path.GetFullPath(path)).TrimEnd('\\') != Path.GetFullPath(Path.GetTempPath()).TrimEnd('\\') ||
                !Path.GetFileName(path).StartsWith("knot-native-update-", StringComparison.Ordinal)) throw new InvalidDataException();
            SecurityIdentifier user; using (var identity = WindowsIdentity.GetCurrent()) user = identity.User;
            var acl = Directory.GetAccessControl(path);
            if (!acl.AreAccessRulesProtected || !user.Equals(acl.GetOwner(typeof(SecurityIdentifier)))) throw new InvalidDataException();
            foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
                if (rule.AccessControlType == AccessControlType.Allow && !user.Equals(rule.IdentityReference)) throw new InvalidDataException();
        }
        internal static string Quote(string text)
        {
            if (text.IndexOf('"') >= 0 || text.IndexOf('\0') >= 0 || text.EndsWith("\\", StringComparison.Ordinal)) throw new InvalidDataException();
            return "\"" + text + "\"";
        }
    }
    // One launched child owns one nonce. Revocation is published before waiting
    // for that exact child; an unconfirmed exit never licenses stage deletion.
    internal sealed class NativeUpdateAttempt : IDisposable
    {
        private readonly Action revoke, cleanup;
        private readonly Func<bool> exited;
        private readonly Action kill;
        private readonly Func<int, bool> wait;
        private readonly IDisposable child;
        internal NativeUpdateAttempt(Action revoke, Action cleanup, Func<bool> exited, Action kill, Func<int, bool> wait, IDisposable child)
        { this.revoke = revoke; this.cleanup = cleanup; this.exited = exited; this.kill = kill; this.wait = wait; this.child = child; }
        internal bool RevokeAuthority() { try { revoke(); return true; } catch (Exception) { return false; } }
        internal void RequestTermination() { try { if (!exited()) kill(); } catch (Exception) { } }
        internal bool RevokeAndStop()
        {
            RevokeAuthority();
            bool stopped = false;
            try { if (!exited()) kill(); stopped = wait(5000) && exited(); } catch (Exception) { }
            if (stopped) { cleanup(); Dispose(); }
            // A cancellation marker also removes publication authority if child
            // termination fails. Keep its stage because it may still be reading.
            return stopped;
        }
        public void Dispose() { if (child != null) child.Dispose(); }
    }
    internal sealed class NativeUpdates : IDisposable
    {
        private readonly NativeUpdateConfiguration configuration;
        private readonly object gate = new object();
        private readonly CancellationTokenSource lifetime = new CancellationTokenSource();
        private Timer timer;
        private string stage;
        private NativeUpdateManifest pending;
        private bool busy, installing, transferred, unconfirmedHelper, retainedCleanupScheduled;
        private NativeUpdateAttempt retainedAttempt;
        private readonly Func<string, NativeUpdateManifest, string, CancellationToken, NativeUpdateAttempt> prepare;
        internal event Action Changed;
        internal bool Configured { get { return configuration != null && configuration.Configured; } }
        internal bool Available { get { lock (gate) return pending != null && !installing; } }
        internal bool Busy { get { lock (gate) return busy || installing || unconfirmedHelper; } }
        internal string Status { get; private set; }
        private static NativeUpdateConfiguration LoadConfiguration()
        { try { return NativeUpdateConfiguration.Load(); } catch (Exception) { return null; } }
        internal NativeUpdates() : this(LoadConfiguration()) { }
        // Pure fake adapters/explicit in-memory fixtures exercise install state
        // without starting a helper, reading a live store or downloading a feed.
        internal NativeUpdates(NativeUpdateConfiguration configuration,
            Func<string, NativeUpdateManifest, string, CancellationToken, NativeUpdateAttempt> prepare = null,
            NativeUpdateManifest prepared = null, string preparedStage = null)
        {
            this.configuration = configuration; pending = prepared; stage = preparedStage;
            this.prepare = prepare ?? new Func<string, NativeUpdateManifest, string, CancellationToken, NativeUpdateAttempt>(Prepare);
            Status = Configured ? "새 버전을 자동으로 확인합니다." : "자동 업데이트 배포가 아직 구성되지 않았습니다.";
        }
        internal void StartAutomaticChecks()
        { lock (gate) if (Configured && timer == null && !lifetime.IsCancellationRequested) timer = new Timer(delegate { CheckAsync(); }, null, 0, 86400000); }
        internal Task CheckAsync()
        {
            string stale = null;
            lock (gate) {
                if (!Configured || busy || installing || unconfirmedHelper || lifetime.IsCancellationRequested) return Task.FromResult(false);
                if (pending != null && pending.Expires <= NativeUpdateManifest.Now) { stale = stage; stage = null; pending = null; }
                if (pending != null) return Task.FromResult(false);
                busy = true;
            }
            return Task.Run(delegate {
                DeleteOwnedStage(stale);
                string holding = null;
                try {
                    SetStatus("업데이트를 확인하고 있습니다."); holding = NativeUpdatePaths.CreateStage();
                    string feed = Path.Combine(holding, "manifest.feed"); Download(NativeUpdateManifest.Https(configuration.WindowsFeed), feed, 16384, lifetime.Token);
                    NativeUpdateManifest m = NativeUpdateManifest.Verify(File.ReadAllBytes(feed), configuration, "windows-x64", NativeUpdateManifest.Now);
                    string package = Path.Combine(holding, "payload.exe"); Download(m.Url, package, m.Bytes, lifetime.Token); m.VerifyFile(package);
                    lifetime.Token.ThrowIfCancellationRequested();
                    lock (gate) { lifetime.Token.ThrowIfCancellationRequested(); pending = m; stage = holding; holding = null; }
                    SetStatus(m.Version + " 준비 완료 · 설치 후 자동으로 다시 엽니다.");
                } catch (NativeUpdateCurrentException) { SetStatus("현재 최신 버전을 사용하고 있습니다."); }
                catch (OperationCanceledException) { }
                catch (Exception) { SetStatus("업데이트를 확인하지 못했습니다. 현재 버전은 계속 사용할 수 있습니다."); }
                finally { DeleteOwnedStage(holding); lock (gate) busy = false; CleanupIfStopped(); Notify(); }
            });
        }
        // Await from the WinForms event handler. Only the small state/exit action
        // resumes on its context; file hashes, copies and READY waits run off UI.
        internal async Task<bool> InstallAsync(Action beforeExit)
        {
            string holding; NativeUpdateManifest m;
            lock (gate) { if (pending == null || busy || installing || unconfirmedHelper || lifetime.IsCancellationRequested) return false; installing = true; holding = stage; m = pending; }
            SetStatus("업데이트를 설치할 준비를 하고 있습니다.");
            NativeUpdateAttempt attempt = null;
            string nonce = Guid.NewGuid().ToString("N");
            try {
                Exception failure = null;
                try {
                    attempt = await Task.Run(delegate { return prepare(holding, m, nonce, lifetime.Token); });
                    lifetime.Token.ThrowIfCancellationRequested();
                    NativeUpdateHandoff.WriteSignal(holding, nonce, "commit");
                    // Close() disposes this model. Ownership transfers before that
                    // callback so Dispose cannot remove a committed helper's files.
                    lock (gate) transferred = true;
                    beforeExit();
                    lock (gate) { pending = null; stage = null; }
                    attempt.Dispose(); return true;
                } catch (Exception error) { failure = error; }
                // This await is outside catch, preserving the shipped C#5
                // compiler contract while keeping child waits off the UI.
                var uncertain = failure as NativeUpdateUnconfirmedCancellation;
                if (uncertain != null) attempt = uncertain.Attempt;
                // Publish cancellation synchronously before yielding the UI exit
                // callback's stack. A late READY/COMMIT cannot outlive failure.
                bool exitConfirmed = true;
                if (attempt != null) {
                    NativeUpdateAttempt owned = attempt;
                    if (!owned.RevokeAuthority()) owned.RequestTermination();
                    exitConfirmed = await Task.Run(delegate { return owned.RevokeAndStop(); });
                }
                lock (gate) {
                    transferred = false; unconfirmedHelper = !exitConfirmed;
                    if (!exitConfirmed) retainedAttempt = attempt;
                    if (exitConfirmed) { pending = null; stage = null; }
                }
                if (exitConfirmed) await Task.Run(delegate { DeleteOwnedStage(holding); });
                SetStatus(exitConfirmed ? "업데이트 준비를 취소했습니다. 새 버전을 다시 확인해 주세요." : "업데이트 작업의 취소를 확인하지 못해 추가 업데이트를 중단했습니다. 현재 앱은 계속 사용할 수 있습니다.");
                return false;
            } finally { lock (gate) installing = false; CleanupIfStopped(); Notify(); }
        }
        private NativeUpdateAttempt Prepare(string holding, NativeUpdateManifest m, string nonce, CancellationToken cancellation)
        {
            Process process = null; NativeUpdateAttempt attempt = null;
            string helper = Path.Combine(holding, "KnotNativeUpdateHandoff-" + nonce + ".exe");
            try {
                cancellation.ThrowIfCancellationRequested(); NativeUpdatePaths.ValidateStage(holding);
                NativeUpdateManifest fresh = NativeUpdateManifest.Verify(File.ReadAllBytes(Path.Combine(holding, "manifest.feed")), configuration, "windows-x64", NativeUpdateManifest.Now);
                if (fresh.Build != m.Build) throw new InvalidDataException(); fresh.VerifyFile(Path.Combine(holding, "payload.exe"));
                string executable = Assembly.GetExecutingAssembly().Location;
                NativeUpdatePaths.Ordinary(executable); File.Copy(executable, helper, false);
                cancellation.ThrowIfCancellationRequested();
                using (Process current = Process.GetCurrentProcess()) {
                    string args = "--knot-native-update-v2 " + current.Id.ToString(CultureInfo.InvariantCulture) + " " + current.StartTime.ToUniversalTime().Ticks.ToString(CultureInfo.InvariantCulture) + " " + NativeUpdatePaths.Quote(executable) + " " + NativeUpdatePaths.Quote(holding) + " " + nonce;
                    process = Process.Start(new ProcessStartInfo(helper, args) { UseShellExecute = false, WorkingDirectory = holding, CreateNoWindow = true });
                }
                if (process == null) throw new IOException();
                Process owned = process;
                attempt = new NativeUpdateAttempt(
                    delegate { NativeUpdateHandoff.WriteSignal(holding, nonce, "cancel"); },
                    delegate { /* Whole stage is deleted only by its model owner. */ },
                    delegate { return owned.HasExited; }, delegate { owned.Kill(); },
                    delegate(int timeout) { return owned.WaitForExit(timeout); }, owned);
                long deadline = Stopwatch.GetTimestamp() + 45L * Stopwatch.Frequency;
                while (!NativeUpdateHandoff.HasSignal(holding, nonce, "ready")) {
                    cancellation.ThrowIfCancellationRequested();
                    if (process.HasExited || Stopwatch.GetTimestamp() >= deadline) throw new IOException();
                    Thread.Sleep(25);
                }
                cancellation.ThrowIfCancellationRequested(); return attempt;
            } catch {
                if (attempt != null) { if (!attempt.RevokeAndStop()) throw new NativeUpdateUnconfirmedCancellation(attempt); }
                else if (process != null) process.Dispose();
                throw;
            }
        }
        private void SetStatus(string value) { lock (gate) Status = value; Notify(); }
        private void Notify() { Action handler = Changed; if (handler != null) try { handler(); } catch (Exception) { } }
        private static void DeleteOwnedStage(string owned)
        { if (owned == null) return; try { NativeUpdatePaths.ValidateStage(owned); Directory.Delete(owned, true); } catch (Exception) { } }
        private void CleanupIfStopped()
        {
            string owned = null;
            lock (gate) {
                if (lifetime.IsCancellationRequested && !busy && !installing && !transferred && !unconfirmedHelper) { owned = stage; stage = null; pending = null; }
            }
            if (owned != null) DeleteOwnedStage(owned);
        }
        private static void Download(Uri url, string target, long maximum, CancellationToken cancellation)
        {
            var request = (HttpWebRequest)WebRequest.Create(url); request.AllowAutoRedirect = false; request.Timeout = 60000; request.ReadWriteTimeout = 60000; request.CookieContainer = null;
            using (cancellation.Register(request.Abort))
            using (var response = (HttpWebResponse)request.GetResponse())
            {
                if (response.StatusCode != HttpStatusCode.OK || response.ContentLength > maximum) throw new InvalidDataException();
                using (var input = response.GetResponseStream())
                using (var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    byte[] buffer = new byte[65536]; long count = 0; int n;
                    while ((n = input.Read(buffer, 0, buffer.Length)) > 0) { cancellation.ThrowIfCancellationRequested(); count += n; if (count > maximum) throw new InvalidDataException(); output.Write(buffer, 0, n); }
                    output.Flush(true);
                }
            }
        }
        public void Dispose()
        {
            NativeUpdateAttempt retained;
            lock (gate) {
                lifetime.Cancel(); if (timer != null) { timer.Dispose(); timer = null; }
                retained = retainedCleanupScheduled ? null : retainedAttempt;
                if (retained != null) retainedCleanupScheduled = true;
            }
            if (retained != null) {
                if (!retained.RevokeAuthority()) retained.RequestTermination();
                Task.Run(delegate {
                    try {
                        if (retained.RevokeAndStop()) {
                            lock (gate) { if (retainedAttempt == retained) { retainedAttempt = null; unconfirmedHelper = false; } }
                            CleanupIfStopped(); Notify();
                        }
                    } finally { lock (gate) retainedCleanupScheduled = false; }
                });
            }
            CleanupIfStopped();
        }
    }
    internal sealed class NativeUpdateUnconfirmedCancellation : Exception
    { internal readonly NativeUpdateAttempt Attempt; internal NativeUpdateUnconfirmedCancellation(NativeUpdateAttempt attempt) { Attempt = attempt; } }
    internal static class NativeUpdateRecovery
    {
        internal static bool InstallerStopped(bool started, bool terminal) { return !started || terminal; }
        internal static bool MayReopenOriginal(bool started, bool terminal, bool succeeded, bool unchanged)
        { return !succeeded && InstallerStopped(started, terminal) && unchanged; }
    }
    internal static class NativeUpdateHandoff
    {
        internal static bool ValidNonce(string nonce)
        { Guid parsed; return nonce != null && nonce.Length == 32 && Guid.TryParseExact(nonce, "N", out parsed) && parsed.ToString("N") == nonce; }
        private static string Signal(string stage, string nonce, string kind)
        { if (!ValidNonce(nonce) || (kind != "ready" && kind != "commit" && kind != "cancel")) throw new InvalidDataException(); return Path.Combine(stage, "handoff-" + nonce + "." + kind); }
        internal static void WriteSignal(string stage, string nonce, string kind)
        {
            if (kind == "cancel" && HasSignal(stage, nonce, kind)) return;
            string target = Signal(stage, nonce, kind), temporary = target + "." + Guid.NewGuid().ToString("N") + ".writing";
            try {
                byte[] bytes = Encoding.ASCII.GetBytes(nonce);
                using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                    output.Write(bytes, 0, bytes.Length); output.Flush(true);
                }
                // A reader sees absent or the complete receipt, never a newly
                // created zero/partial-length record while another thread writes.
                File.Move(temporary, target);
            } catch (IOException) {
                if (kind != "cancel" || !HasSignal(stage, nonce, kind)) throw;
            } finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        internal static bool HasSignal(string stage, string nonce, string kind)
        {
            string path = Signal(stage, nonce, kind); if (!File.Exists(path)) return false; NativeUpdatePaths.Ordinary(path);
            using (var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                if (input.Length != 32) throw new InvalidDataException();
                byte[] bytes = new byte[32]; int offset = 0, count;
                while (offset < bytes.Length && (count = input.Read(bytes, offset, bytes.Length - offset)) > 0) offset += count;
                return offset == bytes.Length && Encoding.ASCII.GetString(bytes) == nonce;
            }
        }
        internal static bool MayInstall(string stage, string nonce)
        { return HasSignal(stage, nonce, "commit") && !HasSignal(stage, nonce, "cancel"); }
        // Called before WinForms/capture initialization. No v1 helper is accepted:
        // the parent and child must both implement explicit commit/revocation.
        internal static bool TryRun(string[] a)
        {
            if (a == null || a.Length == 0 || a[0] != "--knot-native-update-v2") return false;
            try { Run(a); Environment.ExitCode = 0; } catch (Exception) { Environment.ExitCode = 1; }
            return true;
        }
        private static string Digest(string path)
        { NativeUpdatePaths.Ordinary(path); using (var input = File.OpenRead(path)) using (var hash = SHA256.Create()) return Convert.ToBase64String(hash.ComputeHash(input)); }
        private static void Relaunch(string executable)
        {
            NativeUpdatePaths.Ordinary(executable);
            if (AssemblyName.GetAssemblyName(executable).Name != Assembly.GetExecutingAssembly().GetName().Name) throw new InvalidDataException();
            using (var process = Process.Start(new ProcessStartInfo(executable, "--knot-native-update-resume") { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(executable) }))
            { if (process == null) throw new IOException(); }
        }
        private static void Run(string[] a)
        {
            int pid; long start;
            if (a.Length != 6 || !Int32.TryParse(a[1], NumberStyles.None, CultureInfo.InvariantCulture, out pid) || pid < 1 ||
                !Int64.TryParse(a[2], NumberStyles.None, CultureInfo.InvariantCulture, out start) || !ValidNonce(a[5])) throw new InvalidDataException();
            string executable = Path.GetFullPath(a[3]), stage = Path.GetFullPath(a[4]), nonce = a[5]; NativeUpdatePaths.ValidateStage(stage); NativeUpdatePaths.Ordinary(executable);
            string allowed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Knot Native Preview", "Knot-Native-Preview.exe");
            if (!String.Equals(executable, allowed, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException();
            NativeUpdateConfiguration c = NativeUpdateConfiguration.Load();
            NativeUpdateManifest m = NativeUpdateManifest.Verify(File.ReadAllBytes(Path.Combine(stage, "manifest.feed")), c, "windows-x64", NativeUpdateManifest.Now);
            string package = Path.Combine(stage, "payload.exe"); m.VerifyFile(package);
            string originalDigest = Digest(executable);
            using (var original = Process.GetProcessById(pid))
            {
                if (original.StartTime.ToUniversalTime().Ticks != start || !String.Equals(original.MainModule.FileName, executable, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException();
                WriteSignal(stage, nonce, "ready");
                long deadline = Stopwatch.GetTimestamp() + 180L * Stopwatch.Frequency;
                while (!HasSignal(stage, nonce, "commit")) {
                    if (HasSignal(stage, nonce, "cancel") || original.HasExited || Stopwatch.GetTimestamp() >= deadline) throw new IOException();
                    Thread.Sleep(25);
                }
                if (HasSignal(stage, nonce, "cancel") || !original.WaitForExit(180000)) throw new IOException();
            }
            bool installerStarted = false, installerTerminal = false, succeeded = false;
            try {
                if (!MayInstall(stage, nonce)) throw new IOException();
                using (var locked = new FileStream(package, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    m.VerifyFile(package);
                    if (!MayInstall(stage, nonce)) throw new IOException();
                    string args = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /NORESTARTAPPLICATIONS /KNOTNATIVEUPDATE=1 /DIR=" + NativeUpdatePaths.Quote(Path.GetDirectoryName(executable));
                    using (var installer = Process.Start(new ProcessStartInfo(package, args) { UseShellExecute = false, WorkingDirectory = stage }))
                    {
                        if (installer == null) throw new IOException(); installerStarted = true;
                        installerTerminal = installer.WaitForExit(300000);
                        if (!installerTerminal || installer.ExitCode != 0) throw new IOException();
                        succeeded = true;
                    }
                }
                Relaunch(executable);
                try { File.Delete(package); File.Delete(Path.Combine(stage, "manifest.feed")); } catch (Exception) { }
            } catch {
                // A timed-out installer can still be changing files. Never open
                // the app then. On a terminal failure, only reopen byte-identical
                // original code; do not assume installer rollback succeeded.
                if (!succeeded && NativeUpdateRecovery.InstallerStopped(installerStarted, installerTerminal)) {
                    try { if (NativeUpdateRecovery.MayReopenOriginal(installerStarted, installerTerminal, succeeded, Digest(executable) == originalDigest)) Relaunch(executable); } catch (Exception) { }
                    try { File.Delete(package); File.Delete(Path.Combine(stage, "manifest.feed")); } catch (Exception) { }
                }
                throw;
            }
        }
    }
}
