// SPDX-License-Identifier: GPL-3.0-only
// Source-only fixtures define KNOT_QUICKSETUP_POLICY_ONLY; production uses the same policy.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
#if !KNOT_QUICKSETUP_POLICY_ONLY
using System.Drawing;
using System.Diagnostics;
using System.Net;
using System.Net.Security;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Windows.Forms;
using Microsoft.Win32.SafeHandles;
#endif

internal sealed class SunshineSetupFailure : Exception
{
    internal SunshineSetupFailure(string message) : base(message) { }
}
internal sealed class SunshineApiReply
{
    internal int Status;
    internal string Location, Body;
    internal SunshineApiReply(int status, string body, string location = null) { Status = status; Body = body; Location = location; }
}
internal interface ISunshineRestartWitness : IDisposable
{
    Task WaitForExitAsync(CancellationToken cancellation);
    void VerifyReplacement(CancellationToken cancellation);
}
internal interface ISunshineSetupApi
{
    ISunshineRestartWitness CaptureRestart(CancellationToken cancellation);
    Task<SunshineApiReply> SendAsync(string path, string body, string authorization, CancellationToken cancellation);
}
internal sealed class SunshinePendingPair
{
    internal string ID, Name, Address;
    public override string ToString() { return Name + " — " + Address; }
}

internal static class SunshineSetupPolicy
{
    internal const string Version = "2026.914.233613";
    internal const int MaximumBody = 262144;
    internal const string Manual = "빠른 설정을 안전하게 완료하지 못했습니다. 기존 설정과 연결 인증서는 자동으로 교체하지 않습니다. 고급 설정에서 Sunshine을 확인하세요.";
    internal static void Require(bool condition) { if (!condition) throw new SunshineSetupFailure(Manual); }
    internal static bool Matches(byte[] expected, byte[] actual)
    {
        if (expected == null || actual == null || expected.Length != actual.Length || expected.Length == 0) return false;
        int difference = 0; for (int i = 0; i < expected.Length; i++) difference |= expected[i] ^ actual[i]; return difference == 0;
    }
    // Decode only a fresh native table/synthetic bytes. One listener that can
    // receive the literal IPv4 loopback destination must exist, without ambiguity.
    internal static int ListenerPid(byte[] table, bool allowMissing = false)
    {
        Require(table != null && table.Length >= 4 && table.Length <= 4194304);
        uint count = BitConverter.ToUInt32(table, 0);
        Require(count <= 65536 && 4L + count * 24L <= table.Length);
        int result = 0, matched = 0;
        for (int i = 0; i < count; i++)
        {
            int row = 4 + i * 24;
            uint state = BitConverter.ToUInt32(table, row), address = BitConverter.ToUInt32(table, row + 4);
            int port = table[row + 8] * 256 + table[row + 9];
            if (state == 2 && (address == 0 || address == 0x0100007f) && port == 47990)
            {
                uint pid = BitConverter.ToUInt32(table, row + 20);
                Require(pid > 0 && pid <= Int32.MaxValue); result = (int)pid; matched++;
            }
        }
        if (allowMissing && matched == 0) return 0;
        Require(matched == 1); return result;
    }
    internal static bool TrustedSid(string sid)
    { return sid == "S-1-5-18" || sid == "S-1-5-32-544" || sid == "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"; }
    internal static bool SafeAclRule(string sid, int rights, bool allow, bool inheritOnly)
    {
        // WRITE, DELETE_CHILD, DELETE, WRITE_DAC, WRITE_OWNER, GENERIC_WRITE/ALL.
        // An inherit-only template does not grant rights on the current object.
        return !allow || inheritOnly || TrustedSid(sid) || (rights & 0x500d0156) == 0;
    }
    internal static bool TrustedProcessSid(string sid) { return sid == "S-1-5-18"; }
    internal static bool SafeKeyAclRule(string sid, int rights, bool allow, bool inheritOnly)
    {
        // Private key bytes must not be readable or mutable by another identity.
        // READ_CONTROL/READ_ATTRIBUTES alone reveal metadata, not key contents.
        return !allow || inheritOnly || TrustedSid(sid) || (rights & unchecked((int)0xd00d0157)) == 0;
    }
    internal static bool IsWelcome(SunshineApiReply reply) { return reply.Status == 307 && reply.Location == "/welcome"; }
    internal static void ValidateCredentials(string username, string password, bool create)
    {
        Require(!String.IsNullOrEmpty(username) && username.Length <= 128 && username.IndexOf(':') < 0 && SafeText(username));
        Require(!String.IsNullOrEmpty(password) && Encoding.UTF8.GetByteCount(password) <= 1024 && SafeText(password));
        if (create && Encoding.UTF8.GetByteCount(password) < 16)
            throw new SunshineSetupFailure("새 Sunshine 비밀번호는 UTF-8 기준 16바이트 이상으로 정하세요. 기존 계정은 기존 비밀번호를 입력하세요.");
    }
    internal static bool SafeText(string value)
    {
        foreach (char c in value)
        {
            UnicodeCategory category = Char.GetUnicodeCategory(c);
            if (Char.IsControl(c) || Char.IsSurrogate(c) || category == UnicodeCategory.Format ||
                category == UnicodeCategory.LineSeparator || category == UnicodeCategory.ParagraphSeparator) return false;
        }
        return true;
    }
    internal static string Authorization(string username, string password)
    { return "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes(username + ":" + password)); }
    internal static Dictionary<string, object> Config(SunshineApiReply reply)
    {
        Require(reply.Status == 200);
        Dictionary<string, object> all = SunshineSetupJson.Object(reply.Body);
        Require(all.ContainsKey("status") && all["status"] is bool && (bool)all["status"] &&
            all.ContainsKey("version") && (all["version"] as string) == Version &&
            all.ContainsKey("platform") && (all["platform"] as string) == "windows");
        all.Remove("status"); all.Remove("version"); all.Remove("platform");
        foreach (var item in all)
            Require(Regex.IsMatch(item.Key, @"\A[a-z][a-z0-9_]{0,79}\z") && item.Value is string &&
                ((string)item.Value).Length <= 65536 && SafeText((string)item.Value));
        return all;
    }
    internal static bool Equal(Dictionary<string, object> a, Dictionary<string, object> b)
    {
        if (a.Count != b.Count) return false;
        foreach (var item in a) { object v; if (!b.TryGetValue(item.Key, out v) || !Object.Equals(item.Value, v)) return false; }
        return true;
    }
    internal static Dictionary<string, object> Secure(Dictionary<string, object> original)
    {
        var result = new Dictionary<string, object>(original, StringComparer.Ordinal);
        result["lan_encryption_mode"] = "2"; result["wan_encryption_mode"] = "2";
        result["upnp"] = "disabled"; result["origin_web_ui_allowed"] = "pc";
        return result;
    }
    internal static void Success(SunshineApiReply reply)
    {
        Require(reply.Status == 200);
        Dictionary<string, object> body = SunshineSetupJson.Object(reply.Body);
        Require(body.ContainsKey("status") && body["status"] is bool && (bool)body["status"]);
    }
    internal static List<SunshinePendingPair> Pairings(SunshineApiReply reply)
    {
        Require(reply.Status == 200);
        var body = SunshineSetupJson.Object(reply.Body);
        object list; Require(body.TryGetValue("pairings", out list) && list is List<object>);
        var result = new List<SunshinePendingPair>(); var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        Require(((List<object>)list).Count <= 32);
        foreach (object value in (List<object>)list)
        {
            var item = value as Dictionary<string, object>; Require(item != null && item.Count == 3);
            object id = null, name = null, address = null;
            Require(item.TryGetValue("id", out id) && item.TryGetValue("name", out name) && item.TryGetValue("address", out address));
            var pair = new SunshinePendingPair { ID = id as string, Name = name as string, Address = address as string };
            Require(pair.ID != null && Regex.IsMatch(pair.ID, @"\A[0-9a-fA-F]{32}\z") && seen.Add(pair.ID));
            Require(pair.Name != null && Encoding.UTF8.GetByteCount(pair.Name) >= 1 && Encoding.UTF8.GetByteCount(pair.Name) <= 128 && SafeText(pair.Name));
            System.Net.IPAddress ip;
            Require(pair.Address != null && pair.Address.Length <= 64 && System.Net.IPAddress.TryParse(pair.Address, out ip) && SafeText(pair.Address));
            result.Add(pair);
        }
        return result;
    }
    internal static string PairBody(SunshinePendingPair selected, string pin)
    {
        Require(selected != null && selected.ID != null && Regex.IsMatch(selected.ID, @"\A[0-9a-fA-F]{32}\z") &&
            selected.Name != null && Encoding.UTF8.GetByteCount(selected.Name) >= 1 && Encoding.UTF8.GetByteCount(selected.Name) <= 128 && SafeText(selected.Name));
        if (pin == null || !Regex.IsMatch(pin, @"\A[0-9]{4}\z")) throw new SunshineSetupFailure("Mac의 Knot에 표시된 4자리 PIN을 입력하세요.");
        return SunshineSetupJson.Write(new Dictionary<string, object> { { "pairing_id", selected.ID }, { "pin", pin }, { "name", selected.Name } });
    }
}

// A deliberately small strict parser. Duplicate keys, arbitrary numeric values,
// deep objects and malformed Unicode fail closed instead of being normalized.
internal sealed class SunshineSetupJson
{
    private readonly string text; private int at, count;
    private SunshineSetupJson(string value) { text = value; }
    internal static Dictionary<string, object> Object(string text)
    {
        SunshineSetupPolicy.Require(text != null && Encoding.UTF8.GetByteCount(text) <= SunshineSetupPolicy.MaximumBody);
        var parser = new SunshineSetupJson(text); object value = parser.Read(0); parser.Space();
        SunshineSetupPolicy.Require(parser.at == text.Length && value is Dictionary<string, object>);
        return (Dictionary<string, object>)value;
    }
    private void Space() { while (at < text.Length && (text[at] == ' ' || text[at] == '\t' || text[at] == '\r' || text[at] == '\n')) at++; }
    private bool Take(char c) { Space(); if (at < text.Length && text[at] == c) { at++; return true; } return false; }
    private object Read(int depth)
    {
        SunshineSetupPolicy.Require(depth <= 8 && ++count <= 2048); Space(); SunshineSetupPolicy.Require(at < text.Length);
        if (text[at] == '"') return ReadString();
        if (Take('{'))
        {
            var result = new Dictionary<string, object>(StringComparer.Ordinal); if (Take('}')) return result;
            do { Space(); SunshineSetupPolicy.Require(at < text.Length && text[at] == '"'); string key = ReadString();
                SunshineSetupPolicy.Require(!result.ContainsKey(key) && Take(':')); result.Add(key, Read(depth + 1)); if (Take('}')) return result;
            } while (Take(','));
            throw new SunshineSetupFailure(SunshineSetupPolicy.Manual);
        }
        if (Take('['))
        {
            var result = new List<object>(); if (Take(']')) return result;
            do { result.Add(Read(depth + 1)); if (Take(']')) return result; } while (Take(','));
            throw new SunshineSetupFailure(SunshineSetupPolicy.Manual);
        }
        foreach (string literal in new string[] { "true", "false", "null" })
            if (text.Length - at >= literal.Length && String.CompareOrdinal(text, at, literal, 0, literal.Length) == 0)
            { at += literal.Length; return literal == "null" ? null : (object)(literal == "true"); }
        throw new SunshineSetupFailure(SunshineSetupPolicy.Manual);
    }
    private string ReadString()
    {
        SunshineSetupPolicy.Require(Take('"')); var result = new StringBuilder();
        while (at < text.Length)
        {
            char c = text[at++]; if (c == '"') return result.ToString();
            SunshineSetupPolicy.Require(c >= 32 && !Char.IsSurrogate(c));
            if (c == '\\')
            {
                SunshineSetupPolicy.Require(at < text.Length); c = text[at++];
                switch (c)
                {
                    case '"': case '\\': case '/': break;
                    case 'b': c = '\b'; break; case 'f': c = '\f'; break; case 'n': c = '\n'; break;
                    case 'r': c = '\r'; break; case 't': c = '\t'; break;
                    case 'u':
                        SunshineSetupPolicy.Require(at + 4 <= text.Length); int code;
                        SunshineSetupPolicy.Require(Int32.TryParse(text.Substring(at, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out code));
                        c = (char)code; SunshineSetupPolicy.Require(!Char.IsSurrogate(c)); at += 4; break;
                    default: throw new SunshineSetupFailure(SunshineSetupPolicy.Manual);
                }
            }
            result.Append(c);
        }
        throw new SunshineSetupFailure(SunshineSetupPolicy.Manual);
    }
    internal static string Write(Dictionary<string, object> values)
    {
        var keys = new List<string>(values.Keys); keys.Sort(StringComparer.Ordinal); var result = new StringBuilder("{"); bool first = true;
        foreach (string key in keys)
        {
            SunshineSetupPolicy.Require(values[key] is string); if (!first) result.Append(','); first = false;
            Quoted(result, key); result.Append(':'); Quoted(result, (string)values[key]);
        }
        result.Append('}'); SunshineSetupPolicy.Require(Encoding.UTF8.GetByteCount(result.ToString()) <= SunshineSetupPolicy.MaximumBody); return result.ToString();
    }
    private static void Quoted(StringBuilder result, string value)
    {
        result.Append('"'); foreach (char c in value)
        { if (c == '"' || c == '\\') result.Append('\\').Append(c); else if (c < 32) result.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture)); else result.Append(c); }
        result.Append('"');
    }
}

// The verified listener must be alive before dispatch. A POST can legitimately
// terminate that process while its body is being consumed (notably restart), so
// response collection must not re-check old-process liveness after dispatch.
internal static class SunshineSetupDispatch
{
    internal static async Task<T> SendAsync<T>(byte[] body, Action verifyBeforeSend,
        Func<Task<Stream>> openOutput, Func<Task<T>> receiveResponse, CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested(); verifyBeforeSend();
        if (body != null)
            using (Stream output = await openOutput().ConfigureAwait(false))
                await output.WriteAsync(body, 0, body.Length, cancellation).ConfigureAwait(false);
        return await receiveResponse().ConfigureAwait(false);
    }
}

internal sealed class SunshineSetupSession
{
    private readonly ISunshineSetupApi api; private readonly Func<int, CancellationToken, Task> delay; private readonly int restartTimeoutMilliseconds; private string authorization; internal bool Configured { get; private set; }
    internal SunshineSetupSession(ISunshineSetupApi api, Func<int, CancellationToken, Task> delay = null, int restartTimeoutMilliseconds = 45000)
    {
        SunshineSetupPolicy.Require(restartTimeoutMilliseconds > 0 && restartTimeoutMilliseconds <= 45000);
        this.api = api; this.delay = delay ?? new Func<int, CancellationToken, Task>(Task.Delay); this.restartTimeoutMilliseconds = restartTimeoutMilliseconds;
    }
    internal Task<SunshineApiReply> ProbeAsync(CancellationToken cancel) { return api.SendAsync("/api/config", null, null, cancel); }
    internal async Task PrepareAsync(string username, string password, bool allowFirstAccount, CancellationToken cancel)
    {
        Configured = false;
        authorization = null;
        SunshineApiReply probe = await ProbeAsync(cancel).ConfigureAwait(false);
        bool first = SunshineSetupPolicy.IsWelcome(probe);
        SunshineSetupPolicy.Require(first || probe.Status == 401);
        SunshineSetupPolicy.ValidateCredentials(username, password, first);
        if (first)
        {
            SunshineSetupPolicy.Require(allowFirstAccount);
            string body = SunshineSetupJson.Write(new Dictionary<string, object> { { "currentUsername", "" }, { "currentPassword", "" },
                { "newUsername", username }, { "newPassword", password }, { "confirmNewPassword", password } });
            SunshineSetupPolicy.Success(await api.SendAsync("/api/password", body, null, cancel).ConfigureAwait(false));
        }
        authorization = SunshineSetupPolicy.Authorization(username, password);
        var original = SunshineSetupPolicy.Config(await api.SendAsync("/api/config", null, authorization, cancel).ConfigureAwait(false));
        var desired = SunshineSetupPolicy.Secure(original);
        Dictionary<string, object> saved;
        if (!SunshineSetupPolicy.Equal(original, desired))
        {
            // Upstream has no compare-and-swap. Refuse observed concurrent edits;
            // the UI also requires other editors closed. A final readback is mandatory.
            var latest = SunshineSetupPolicy.Config(await api.SendAsync("/api/config", null, authorization, cancel).ConfigureAwait(false));
            SunshineSetupPolicy.Require(SunshineSetupPolicy.Equal(original, latest));
            SunshineSetupPolicy.Success(await api.SendAsync("/api/config", SunshineSetupJson.Write(desired), authorization, cancel).ConfigureAwait(false));
            saved = SunshineSetupPolicy.Config(await api.SendAsync("/api/config", null, authorization, cancel).ConfigureAwait(false));
            SunshineSetupPolicy.Require(SunshineSetupPolicy.Equal(desired, saved));
        }
        // GET config reads the saved file, not live settings. Success therefore
        // requires the exact pre-request process to exit, plus an authenticated
        // readback and a distinct, verified replacement listener after restart.
        try
        {
        using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancel))
        {
            deadline.CancelAfter(restartTimeoutMilliseconds);
            using (ISunshineRestartWitness witness = api.CaptureRestart(deadline.Token))
            {
                SunshineSetupPolicy.Require(witness != null);
                try
                {
                    SunshineApiReply restarted = await api.SendAsync("/api/restart", "{}", authorization, deadline.Token).ConfigureAwait(false);
                    SunshineSetupPolicy.Require(restarted.Status == 200);
                }
                catch (IOException) { /* Expected upstream socket close still needs the held-process witness. */ }
                await witness.WaitForExitAsync(deadline.Token).ConfigureAwait(false);
                for (int i = 0; i < 20; i++)
                {
                    deadline.Token.ThrowIfCancellationRequested(); await delay(1000, deadline.Token).ConfigureAwait(false);
                    try
                    {
                        saved = SunshineSetupPolicy.Config(await api.SendAsync("/api/config", null, authorization, deadline.Token).ConfigureAwait(false));
                        SunshineSetupPolicy.Require(SunshineSetupPolicy.Equal(desired, saved));
                        witness.VerifyReplacement(deadline.Token);
                        deadline.Token.ThrowIfCancellationRequested(); Configured = true; return;
                    }
                    catch (IOException) { }
                }
            }
        }
        }
        catch (OperationCanceledException)
        { cancel.ThrowIfCancellationRequested(); throw new SunshineSetupFailure("Sunshine 재시작 확인 시간이 지났습니다. 빠른 설정을 다시 여세요. 인증서는 교체하지 않습니다."); }
        throw new SunshineSetupFailure("Sunshine 재시작을 아직 확인하지 못했습니다. 잠시 뒤 빠른 설정을 다시 여세요. 인증서는 교체하지 않습니다.");
    }
    internal async Task<List<SunshinePendingPair>> PendingAsync(CancellationToken cancel)
    {
        SunshineSetupPolicy.Require(Configured && authorization != null);
        return SunshineSetupPolicy.Pairings(await api.SendAsync("/api/pin", null, authorization, cancel).ConfigureAwait(false));
    }
    internal async Task PairAsync(SunshinePendingPair selected, string pin, CancellationToken cancel)
    {
        SunshineSetupPolicy.Require(Configured && authorization != null);
        string body = SunshineSetupPolicy.PairBody(selected, pin);
        List<SunshinePendingPair> current = await PendingAsync(cancel).ConfigureAwait(false); bool found = false;
        foreach (var item in current) if (item.ID == selected.ID && item.Name == selected.Name && item.Address == selected.Address) found = true;
        SunshineSetupPolicy.Require(found);
        SunshineSetupPolicy.Success(await api.SendAsync("/api/pin", body, authorization, cancel).ConfigureAwait(false));
    }
    internal void Clear() { authorization = null; Configured = false; }
}

#if !KNOT_QUICKSETUP_POLICY_ONLY
internal sealed class SunshinePinnedApi : ISunshineSetupApi, IDisposable
{
    private readonly List<IDisposable> locks = new List<IDisposable>(); private byte[] expected; private string protectedExecutable;
    internal bool VerifiedInstalledVersion { get; private set; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    internal SunshinePinnedApi()
    {
        try
        {
            string parent = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string install = Path.Combine(parent, "Sunshine");
            string certificate = Path.Combine(install, @"config\credentials\cacert.pem");
            if (!Directory.Exists(Path.GetDirectoryName(certificate))) throw new IOException();
            // Lock each directory against rename/delete before validating the path.
            for (var current = new DirectoryInfo(Path.GetDirectoryName(certificate)); current != null; current = current.Parent)
            {
                SafeFileHandle handle = CreateFile(current.FullName, 0, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
                SunshineSetupPolicy.Require(!handle.IsInvalid); locks.Add(handle);
            }
            Launcher.AssertProtectedAncestors(Path.GetDirectoryName(certificate));
            for (var current = new DirectoryInfo(Path.GetDirectoryName(certificate)); current != null && current.FullName.Length >= install.Length; current = current.Parent)
                AssertProtectedAcl(current.GetAccessControl());
            string executable = Path.Combine(install, "sunshine.exe"); protectedExecutable = executable;
            SunshineSetupPolicy.Require((File.GetAttributes(executable) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) == 0);
            var image = new FileStream(executable, FileMode.Open, FileAccess.Read, FileShare.Read); locks.Add(image);
            AssertProtectedFile(executable);
            // Upstream windows.rc embeds unmodified PROJECT_VERSION in ProductVersion;
            // the numeric FILEVERSION is deliberately split into four smaller fields.
            VerifiedInstalledVersion = FileVersionInfo.GetVersionInfo(executable).ProductVersion == SunshineSetupPolicy.Version;
            SunshineSetupPolicy.Require(VerifiedInstalledVersion);
            if ((File.GetAttributes(certificate) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0) throw new SunshineSetupFailure(SunshineSetupPolicy.Manual);
            var file = new FileStream(certificate, FileMode.Open, FileAccess.Read, FileShare.Read); locks.Add(file);
            AssertProtectedFile(certificate); SunshineSetupPolicy.Require(file.Length >= 100 && file.Length <= 16384);
            var bytes = new byte[(int)file.Length]; int total = 0;
            while (total < bytes.Length) { int read = file.Read(bytes, total, bytes.Length - total); SunshineSetupPolicy.Require(read > 0); total += read; }
            string pem = new UTF8Encoding(false, true).GetString(bytes);
            Match match = Regex.Match(pem, @"\A\s*-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\r\n]+)\s*-----END CERTIFICATE-----\s*\z");
            SunshineSetupPolicy.Require(match.Success);
            using (var parsed = new X509Certificate2(Convert.FromBase64String(match.Groups[1].Value))) expected = parsed.RawData;
            // Metadata only: never open a stream or read private key contents.
            AssertConfidentialKeyMetadata(Path.Combine(install, @"config\credentials\cakey.pem"));
        }
        catch (IOException) { Dispose(); throw new IOException(); }
        catch { Dispose(); throw new SunshineSetupFailure(SunshineSetupPolicy.Manual); }
    }
    private void AssertConfidentialKeyMetadata(string path)
    {
        SunshineSetupPolicy.Require((File.GetAttributes(path) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) == 0);
        // READ_CONTROL only. OPEN_REPARSE_POINT plus no write/delete sharing
        // retains this exact ordinary object and never asks for FILE_READ_DATA.
        SafeFileHandle metadata = CreateFile(path, 0x00020000, 1, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
        SunshineSetupPolicy.Require(!metadata.IsInvalid); locks.Add(metadata);
        var acl = File.GetAccessControl(path, AccessControlSections.Access | AccessControlSections.Owner);
        SunshineSetupPolicy.Require(SunshineSetupPolicy.TrustedSid(acl.GetOwner(typeof(SecurityIdentifier)).Value));
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            SunshineSetupPolicy.Require(SunshineSetupPolicy.SafeKeyAclRule(rule.IdentityReference.Value, (int)rule.FileSystemRights,
                rule.AccessControlType == AccessControlType.Allow, (rule.PropagationFlags & PropagationFlags.InheritOnly) != 0));
    }
    private static void AssertProtectedFile(string path)
    {
        AssertProtectedAcl(File.GetAccessControl(path, AccessControlSections.Access | AccessControlSections.Owner));
    }
    private static void AssertProtectedAcl(FileSystemSecurity acl)
    {
        SunshineSetupPolicy.Require(SunshineSetupPolicy.TrustedSid(acl.GetOwner(typeof(SecurityIdentifier)).Value));
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            SunshineSetupPolicy.Require(SunshineSetupPolicy.SafeAclRule(rule.IdentityReference.Value, (int)rule.FileSystemRights,
                rule.AccessControlType == AccessControlType.Allow, (rule.PropagationFlags & PropagationFlags.InheritOnly) != 0));
    }
    public ISunshineRestartWitness CaptureRestart(CancellationToken cancellation)
    { cancellation.ThrowIfCancellationRequested(); return SunshineProcessWitness.Capture(protectedExecutable); }
    public async Task<SunshineApiReply> SendAsync(string path, string body, string authorization, CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        using (var listener = SunshineProcessWitness.Capture(protectedExecutable))
        {
        SunshineSetupPolicy.Require(path == "/api/config" || path == "/api/password" || path == "/api/pin" || path == "/api/restart");
        SunshineSetupPolicy.Require((path != "/api/password" && path != "/api/restart") || body != null);
        var request = (HttpWebRequest)WebRequest.Create("https://127.0.0.1:47990" + path);
        request.Method = body == null ? "GET" : "POST"; request.Proxy = null; request.AllowAutoRedirect = false;
        request.UseDefaultCredentials = false; request.Credentials = null; request.CookieContainer = null;
        request.KeepAlive = false; request.PreAuthenticate = false; request.MaximumResponseHeadersLength = 16;
        request.Timeout = 10000; request.ReadWriteTimeout = 10000;
        request.ServerCertificateValidationCallback = delegate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors)
        { return certificate != null && SunshineSetupPolicy.Matches(expected, certificate.GetRawCertData()); };
        if (authorization != null) request.Headers[HttpRequestHeader.Authorization] = authorization;
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation))
        {
            timeout.CancelAfter(path == "/api/pin" && body != null ? 60000 : 10000);
            using (timeout.Token.Register(delegate { request.Abort(); }))
            {
                try
                {
                    byte[] bytes = body == null ? null : new UTF8Encoding(false, true).GetBytes(body);
                    HttpWebResponse response;
                    try
                    {
                        if (bytes != null)
                        {
                            SunshineSetupPolicy.Require(bytes.Length <= SunshineSetupPolicy.MaximumBody);
                            request.ContentType = "application/json"; request.ContentLength = bytes.Length;
                        }
                        try
                        {
                            response = (HttpWebResponse)await SunshineSetupDispatch.SendAsync(bytes, listener.VerifyCurrent,
                                request.GetRequestStreamAsync, request.GetResponseAsync, timeout.Token).ConfigureAwait(false);
                        }
                        catch (WebException error)
                        {
                            if (error.Status == WebExceptionStatus.TrustFailure || error.Status == WebExceptionStatus.SecureChannelFailure) throw new SunshineSetupFailure(SunshineSetupPolicy.Manual);
                            response = error.Response as HttpWebResponse; if (response == null) throw new IOException();
                        }
                    }
                    finally { if (bytes != null) Array.Clear(bytes, 0, bytes.Length); }
                    using (response)
                    {
                        SunshineSetupPolicy.Require(response.ResponseUri == request.RequestUri && response.ContentLength <= SunshineSetupPolicy.MaximumBody);
                        if ((int)response.StatusCode == 200) SunshineSetupPolicy.Require(response.ContentType != null && response.ContentType.Split(';')[0].Trim().Equals("application/json", StringComparison.OrdinalIgnoreCase));
                        using (Stream input = response.GetResponseStream())
                        using (var data = new MemoryStream())
                        {
                            byte[] buffer = new byte[8192]; int read;
                            while ((read = await input.ReadAsync(buffer, 0, buffer.Length, timeout.Token).ConfigureAwait(false)) > 0)
                            { SunshineSetupPolicy.Require(data.Length + read <= SunshineSetupPolicy.MaximumBody); data.Write(buffer, 0, read); }
                            return new SunshineApiReply((int)response.StatusCode, new UTF8Encoding(false, true).GetString(data.ToArray()), response.Headers["Location"]);
                        }
                    }
                }
                catch (WebException) { cancellation.ThrowIfCancellationRequested(); throw new IOException(); }
                catch (OperationCanceledException) { cancellation.ThrowIfCancellationRequested(); throw new IOException(); }
                finally { request.Abort(); }
            }
        }
    }
    }
    public void Dispose() { expected = null; for (int i = locks.Count - 1; i >= 0; i--) locks[i].Dispose(); locks.Clear(); }
}

// Native observations only: no process termination, SCM changes, PID reopening
// during wait, or trust inferred from an HTTP response or certificate alone.
internal sealed class SunshineProcessWitness : ISunshineRestartWitness
{
    private readonly SafeProcessHandle process; private readonly string executable;
    private readonly int pid; private readonly long creationTime;
    [DllImport("iphlpapi.dll")]
    private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, [MarshalAs(UnmanagedType.Bool)] bool ordered, uint family, int kind, uint reserved);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeProcessHandle OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageName(SafeProcessHandle process, uint flags, StringBuilder path, ref int size);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetProcessTimes(SafeProcessHandle process, out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(SafeProcessHandle process, uint milliseconds);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(SafeProcessHandle process, uint desired, out SafeFileHandle token);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(SafeFileHandle token, int kind, IntPtr information, int capacity, out int returned);
    private SunshineProcessWitness(SafeProcessHandle process, string executable, int pid, long creationTime)
    { this.process = process; this.executable = executable; this.pid = pid; this.creationTime = creationTime; }
    internal static SunshineProcessWitness Capture(string executable)
    {
        int pid = CurrentListener(); if (pid == 0) throw new IOException();
        SafeProcessHandle handle = OpenProcess(0x00101000, false, (uint)pid); // SYNCHRONIZE | QUERY_LIMITED_INFORMATION
        try
        {
            SunshineSetupPolicy.Require(handle != null && !handle.IsInvalid && WaitForSingleObject(handle, 0) == 258);
            var image = new StringBuilder(32768); int length = image.Capacity;
            SunshineSetupPolicy.Require(QueryFullProcessImageName(handle, 0, image, ref length) && length > 0 && length < image.Capacity);
            SunshineSetupPolicy.Require(String.Equals(image.ToString(), executable, StringComparison.OrdinalIgnoreCase));
            RequireSystemToken(handle);
            long created, exited, kernel, user;
            SunshineSetupPolicy.Require(GetProcessTimes(handle, out created, out exited, out kernel, out user) && created > 0);
            // A PID can be recycled. Retain the exact kernel handle and ensure the
            // listener still names its live process after image/creation checks.
            SunshineSetupPolicy.Require(CurrentListener() == pid && WaitForSingleObject(handle, 0) == 258);
            return new SunshineProcessWitness(handle, executable, pid, created);
        }
        catch { if (handle != null) handle.Dispose(); throw new SunshineSetupFailure(SunshineSetupPolicy.Manual); }
    }
    private static void RequireSystemToken(SafeProcessHandle process)
    {
        SafeFileHandle token;
        bool opened = OpenProcessToken(process, 0x0008, out token); // TOKEN_QUERY, no impersonation or duplication.
        using (token)
        {
            SunshineSetupPolicy.Require(opened && token != null && !token.IsInvalid);
            int size;
            bool probe = GetTokenInformation(token, 1, IntPtr.Zero, 0, out size); // TOKEN_USER
            SunshineSetupPolicy.Require(!probe && Marshal.GetLastWin32Error() == 122 && size >= IntPtr.Size + 8 && size <= 4096);
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                int returned; SunshineSetupPolicy.Require(GetTokenInformation(token, 1, buffer, size, out returned) && returned >= IntPtr.Size + 8 && returned <= size);
                IntPtr sid = Marshal.ReadIntPtr(buffer);
                SunshineSetupPolicy.Require(sid.ToInt64() >= buffer.ToInt64() + IntPtr.Size && sid.ToInt64() <= buffer.ToInt64() + returned - 8);
                SunshineSetupPolicy.Require(SunshineSetupPolicy.TrustedProcessSid(new SecurityIdentifier(sid).Value));
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
    }
    private static int CurrentListener()
    {
        int size = 0;
        SunshineSetupPolicy.Require(GetExtendedTcpTable(IntPtr.Zero, ref size, false, 2, 3, 0) == 122);
        for (int attempt = 0; attempt < 3; attempt++)
        {
            SunshineSetupPolicy.Require(size >= 4 && size <= 4194304); int allocated = size;
            IntPtr buffer = Marshal.AllocHGlobal(allocated);
            try
            {
                uint result = GetExtendedTcpTable(buffer, ref size, false, 2, 3, 0); // AF_INET, OWNER_PID_LISTENER
                if (result == 122) continue;
                SunshineSetupPolicy.Require(result == 0 && size >= 4 && size <= allocated);
                var table = new byte[size]; Marshal.Copy(buffer, table, 0, table.Length);
                return SunshineSetupPolicy.ListenerPid(table, true);
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        throw new SunshineSetupFailure(SunshineSetupPolicy.Manual);
    }
    internal void VerifyCurrent()
    { SunshineSetupPolicy.Require(WaitForSingleObject(process, 0) == 258 && CurrentListener() == pid && WaitForSingleObject(process, 0) == 258); }
    public async Task WaitForExitAsync(CancellationToken cancellation)
    {
        for (;;)
        {
            cancellation.ThrowIfCancellationRequested(); uint result = WaitForSingleObject(process, 0);
            if (result == 0) return;
            SunshineSetupPolicy.Require(result == 258);
            await Task.Delay(100, cancellation).ConfigureAwait(false);
        }
    }
    public void VerifyReplacement(CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested(); SunshineSetupPolicy.Require(WaitForSingleObject(process, 0) == 0);
        using (var replacement = Capture(executable))
            SunshineSetupPolicy.Require(replacement.pid != pid || replacement.creationTime != creationTime);
        cancellation.ThrowIfCancellationRequested();
    }
    public void Dispose() { process.Dispose(); }
}

internal sealed class SunshineQuickSetupForm : Form
{
    private readonly TextBox username = new TextBox(), password = new TextBox(), pin = new TextBox();
    private readonly Button prepare = new Button(), refresh = new Button(), pair = new Button();
    private readonly ComboBox pending = new ComboBox(); private readonly Label status = new Label();
    private readonly CancellationTokenSource lifetime = new CancellationTokenSource();
    private SunshinePinnedApi api; private SunshineSetupSession session; private bool closing, busy;
    internal bool Completed { get; private set; }
    internal bool HadFailure { get; private set; }
    internal SunshineQuickSetupForm()
    {
        Text = "Knot · 이 PC 연결 준비"; StartPosition = FormStartPosition.CenterScreen; MinimumSize = new Size(620, 650); Size = MinimumSize;
        Font = new Font("Segoe UI", 10); AutoScaleDimensions = new SizeF(96F, 96F); AutoScaleMode = AutoScaleMode.Dpi;
        username.AccessibleName = "Sunshine 사용자 이름"; password.AccessibleName = "Sunshine 비밀번호";
        pin.AccessibleName = "Mac에 표시된 4자리 PIN"; pending.AccessibleName = "연결을 요청한 Mac 이름과 주소";
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(24), ColumnCount = 1, RowCount = 13, AutoScroll = true };
        Controls.Add(layout);
        layout.Controls.Add(new Label { Text = "이 PC를 Mac에서 열기", AutoSize = true, Font = new Font(Font.FontFamily, 18, FontStyle.Bold) });
        layout.Controls.Add(new Label { Text = "Sunshine 계정으로 보안 설정을 준비하고 이 창에서 PIN을 입력합니다.\n계정 정보는 이 창에서만 사용하며 Knot에 저장하지 않습니다.", AutoSize = true, Margin = new Padding(0, 10, 0, 12) });
        layout.Controls.Add(new Label { Text = "Sunshine 사용자 이름 (Windows 로그인 계정 아님)", AutoSize = true }); username.Width = 510; username.MaxLength = 128; username.Text = "knot"; layout.Controls.Add(username);
        layout.Controls.Add(new Label { Text = "Sunshine 비밀번호 · 처음 만드는 계정은 16바이트 이상", AutoSize = true }); password.Width = 510; password.MaxLength = 1024; password.UseSystemPasswordChar = true; layout.Controls.Add(password);
        layout.Controls.Add(new Label { Text = "다른 Sunshine 설정 창을 닫고 진행하세요. 준비를 누르면 화면 암호화를 필수로 설정하고, 공유기 자동 포트 열기를 끄고, 관리 화면을 이 PC로 제한합니다. Sunshine을 재시작하여 진행 중인 화면 연결이 잠시 끊길 수 있습니다.", AutoSize = true, MaximumSize = new Size(530, 0), Margin = new Padding(0, 10, 0, 10) });
        prepare.Text = "안전하게 연결 준비"; prepare.AutoSize = true; prepare.Enabled = false; layout.Controls.Add(prepare);
        status.AutoSize = true; status.MaximumSize = new Size(530, 0); status.Text = "이 PC의 Sunshine 인증서를 확인하는 중…"; status.Margin = new Padding(0, 12, 0, 12); layout.Controls.Add(status);
        layout.Controls.Add(new Label { Text = "연결할 Mac에서 Knot의 이 PC를 선택하세요. 요청한 Mac의 이름과 주소를 직접 확인한 뒤 PIN을 입력하세요.", AutoSize = true, MaximumSize = new Size(530, 0) });
        var requests = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top }; pending.DropDownStyle = ComboBoxStyle.DropDownList; pending.Width = 380; refresh.Text = "요청 새로고침"; refresh.AutoSize = true; refresh.Enabled = false; requests.Controls.Add(pending); requests.Controls.Add(refresh); layout.Controls.Add(requests);
        var pairing = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top }; pin.Width = 100; pin.MaxLength = 4; pin.UseSystemPasswordChar = true; pair.Text = "선택한 Mac 연결"; pair.AutoSize = true; pair.Enabled = false; pairing.Controls.Add(new Label { Text = "Mac의 PIN", AutoSize = true }); pairing.Controls.Add(pin); pairing.Controls.Add(pair); layout.Controls.Add(pairing);
        var close = new Button { Text = "닫기", AutoSize = true }; close.Click += delegate { Close(); }; layout.Controls.Add(close);
        Shown += async delegate { ClampToWorkingArea(); await WorkAsync(InitializeAsync); };
        prepare.Click += async delegate { await WorkAsync(async delegate {
            string user = username.Text, secret = password.Text; pending.Items.Clear(); pending.SelectedIndex = -1; pin.Clear(); prepare.Enabled = false; status.Text = "보안 설정을 저장하고 확인하는 중…";
            try { await session.PrepareAsync(user, secret, api.VerifiedInstalledVersion, lifetime.Token); } finally { password.Clear(); secret = null; }
            pending.Items.Clear(); foreach (var item in await session.PendingAsync(lifetime.Token)) pending.Items.Add(item); pending.SelectedIndex = -1;
            refresh.Enabled = true; pair.Enabled = true; Completed = true;
            status.Text = "보안 설정 저장과 재시작 후 확인을 마쳤습니다. 화면 연결 성공을 뜻하지는 않습니다. 이제 아래에서 요청한 Mac과 PIN을 확인하세요.";
        }); };
        refresh.Click += async delegate { await WorkAsync(async delegate { pending.Items.Clear(); pending.SelectedIndex = -1; foreach (var item in await session.PendingAsync(lifetime.Token)) pending.Items.Add(item); pending.SelectedIndex = -1; status.Text = pending.Items.Count == 0 ? "아직 연결 요청이 없습니다. Mac에서 먼저 이 PC에 연결하세요." : "요청한 Mac을 직접 선택하고 Mac에 표시된 PIN을 입력하세요."; }); };
        pair.Click += async delegate { await WorkAsync(async delegate { var selected = pending.SelectedItem as SunshinePendingPair;
            string selectedPin = pin.Text;
            try { await session.PairAsync(selected, selectedPin, lifetime.Token); pending.Items.Clear(); status.Text = "선택한 Mac의 PIN 연결이 완료되었습니다. Mac에서 화면을 열 수 있습니다."; }
            finally { pin.Clear(); selectedPin = null; } }); };
        FormClosing += delegate { closing = true; lifetime.Cancel(); password.Clear(); pin.Clear(); if (session != null) session.Clear(); };
    }
    private void ClampToWorkingArea()
    {
        Rectangle area = Screen.FromControl(this).WorkingArea;
        MinimumSize = new Size(Math.Min(MinimumSize.Width, area.Width), Math.Min(MinimumSize.Height, area.Height));
        Size = new Size(Math.Min(Width, area.Width), Math.Min(Height, area.Height));
        Location = new Point(Math.Max(area.Left, Math.Min(Left, area.Right - Width)), Math.Max(area.Top, Math.Min(Top, area.Bottom - Height)));
    }
    private async Task InitializeAsync()
    {
        using (var startup = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token))
        {
            startup.CancelAfter(20000);
            try
            {
                for (int attempt = 0; attempt < 20; attempt++)
                {
                    startup.Token.ThrowIfCancellationRequested();
                    try
                    {
                        api = new SunshinePinnedApi(); session = new SunshineSetupSession(api);
                        SunshineApiReply probe = await session.ProbeAsync(startup.Token);
                        SunshineSetupPolicy.Require(probe.Status == 401 || SunshineSetupPolicy.IsWelcome(probe));
                        status.Text = SunshineSetupPolicy.IsWelcome(probe) ? "Sunshine 계정을 처음 만듭니다. 기억할 사용자 이름과 긴 비밀번호를 입력하세요." : "기존 Sunshine 계정으로 로그인하세요. 기존 비밀번호를 바꾸지 않습니다.";
                        prepare.Enabled = true; return;
                    }
                    catch (IOException)
                    {
                        if (api != null) api.Dispose(); api = null; session = null;
                    }
                    await Task.Delay(500, startup.Token);
                }
            }
            catch (OperationCanceledException) { lifetime.Token.ThrowIfCancellationRequested(); }
        }
        throw new SunshineSetupFailure("Sunshine이 아직 시작되지 않았습니다. 잠시 뒤 빠른 설정을 다시 여세요. 다른 경로나 포트를 쓰는 설치는 고급 설정으로 확인하세요.");
    }
    private async Task WorkAsync(Func<Task> action)
    {
        if (busy || closing) return; busy = true;
        prepare.Enabled = false; refresh.Enabled = false; pair.Enabled = false;
        username.Enabled = false; password.Enabled = false; pending.Enabled = false; pin.Enabled = false;
        try { await action(); }
        catch (OperationCanceledException) { }
        catch (SunshineSetupFailure error) { HadFailure = true; if (!closing) status.Text = error.Message; }
        catch (Exception) { HadFailure = true; if (!closing) status.Text = SunshineSetupPolicy.Manual; }
        finally {
            busy = false;
            if (!closing) {
                username.Enabled = session == null || !session.Configured; password.Enabled = username.Enabled;
                pending.Enabled = true; pin.Enabled = true;
                if (session != null) { prepare.Enabled = !session.Configured; refresh.Enabled = session.Configured; pair.Enabled = session.Configured; }
            }
        }
    }
    protected override void Dispose(bool disposing)
    { if (disposing) { lifetime.Cancel(); if (session != null) session.Clear(); if (api != null) api.Dispose(); lifetime.Dispose(); } base.Dispose(disposing); }
}
internal static class SunshineQuickSetup
{
    internal static int Run()
    {
        // This helper runs in its own elevated broker process. Framework 4.8
        // offers no per-request protocol selector; certificate pinning remains
        // strictly per request and no global trust callback is installed.
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        using (var form = new SunshineQuickSetupForm()) { Application.Run(form); return form.Completed ? 0 : (form.HadFailure ? 2 : 1602); }
    }
}
#endif
