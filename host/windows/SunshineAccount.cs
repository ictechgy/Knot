// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
#if !KNOT_QUICKSETUP_POLICY_ONLY || KNOT_ACCOUNT_STORE_FIXTURE
using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
#endif

internal sealed class SunshineLoginRequired : SunshineSetupFailure
{ internal SunshineLoginRequired() : base("기존 Sunshine 계정으로 처음 한 번 로그인하세요. 인증 후 안전하게 기억합니다.") { } }
internal sealed class SunshineAccountRecord
{
    internal string Username, Password;
    internal bool Recovery;
}
internal interface ISunshineAccountStore
{
    SunshineAccountRecord Read();
    void Save(SunshineAccountRecord record);
}

// This controller owns the transaction, including recovery after a lost account
// creation response. It never deletes credentials or changes an existing account.
internal sealed class SunshineAccountController
{
    private readonly ISunshineAccountStore store;
    private readonly Func<SunshineAccountRecord> generate;
    private SunshineAccountRecord account;
    internal bool HasAccount { get { return account != null; } }
    internal SunshineAccountController(ISunshineAccountStore store, Func<SunshineAccountRecord> generate = null)
    { this.store = store; this.generate = generate ?? Generate; account = store.Read(); }
    private static SunshineAccountRecord Generate()
    {
        var bytes = new byte[32];
        try { using (var random = RandomNumberGenerator.Create()) random.GetBytes(bytes);
            return new SunshineAccountRecord { Username = "knot", Password = Convert.ToBase64String(bytes), Recovery = true }; }
        finally { Array.Clear(bytes, 0, bytes.Length); }
    }
    internal async Task PrepareAsync(SunshineSetupSession session, bool manual, string username, string password,
        bool verifiedVersion, CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        if (!manual && account == null)
        {
            SunshineApiReply probe = await session.ProbeAsync(cancellation).ConfigureAwait(false);
            if (!SunshineSetupPolicy.IsWelcome(probe)) { SunshineSetupPolicy.Require(probe.Status == 401); throw new SunshineLoginRequired(); }
            SunshineSetupPolicy.Require(verifiedVersion);
            var created = generate(); SunshineSetupPolicy.ValidateCredentials(created.Username, created.Password, true);
            created.Recovery = true;
            cancellation.ThrowIfCancellationRequested(); store.Save(created); // Durable encrypted journal MUST precede /api/password.
            account = created;
        }
        SunshineAccountRecord candidate = manual ? new SunshineAccountRecord { Username = username, Password = password, Recovery = account != null && account.Recovery } : account;
        SunshineSetupPolicy.Require(candidate != null);
        session.RestoreRecovery(candidate.Recovery);
        await session.PrepareAsync(candidate.Username, candidate.Password, verifiedVersion, cancellation, delegate {
            // Never retain an unverified manually supplied password.
            cancellation.ThrowIfCancellationRequested(); store.Save(candidate); account = candidate;
        }, delegate(bool pending) {
            // Write-ahead: if storage fails, no config/restart request may follow.
            var next = new SunshineAccountRecord { Username = candidate.Username, Password = candidate.Password, Recovery = pending };
            cancellation.ThrowIfCancellationRequested(); store.Save(next); candidate = next; account = next;
        }).ConfigureAwait(false);
    }
    internal void Clear() { account = null; }
}

internal static class SunshineAccountCodec
{
    internal static byte[] Encode(SunshineAccountRecord account, string certificate)
    {
        SunshineSetupPolicy.ValidateCredentials(account.Username, account.Password, false);
        return Encoding.UTF8.GetBytes(SunshineSetupJson.Write(new Dictionary<string, object> {
            { "schema", "1" }, { "username", account.Username }, { "password", account.Password },
            { "certificate", certificate }, { "recovery", account.Recovery ? "true" : "false" } }));
    }
    internal static SunshineAccountRecord Decode(byte[] bytes, string certificate)
    {
        SunshineSetupPolicy.Require(bytes != null && bytes.Length > 0 && bytes.Length <= 16384);
        var body = SunshineSetupJson.Object(new UTF8Encoding(false, true).GetString(bytes));
        object schema, user, password, cert, recovery;
        SunshineSetupPolicy.Require(body.Count == 5 && body.TryGetValue("schema", out schema) && (schema as string) == "1" &&
            body.TryGetValue("certificate", out cert) && (cert as string) == certificate &&
            body.TryGetValue("username", out user) && user is string && body.TryGetValue("password", out password) && password is string &&
            body.TryGetValue("recovery", out recovery) && ((recovery as string) == "true" || (recovery as string) == "false"));
        var result = new SunshineAccountRecord { Username = (string)body["username"], Password = (string)body["password"], Recovery = (string)body["recovery"] == "true" };
        SunshineSetupPolicy.ValidateCredentials(result.Username, result.Password, false); return result;
    }
}

#if !KNOT_QUICKSETUP_POLICY_ONLY || KNOT_ACCOUNT_STORE_FIXTURE
// The owning pinned API holds every ancestor against rename. Only this elevated
// broker can access the store. Machine DPAPI supports UAC with a different admin;
// confidentiality therefore ALSO requires the explicit non-inherited DACL.
internal sealed class SunshineProtectedAccountStore : ISunshineAccountStore, IDisposable
{
    private readonly object gate = new object(); private bool disposed;
    private readonly string path, certificate;
    private readonly FileStream mutex;
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Knot/SunshineAccount/v1");
    internal SunshineProtectedAccountStore(string directory, byte[] pinnedCertificate)
    {
        path = Path.Combine(directory, "knot-account.dpapi");
        using (var hash = SHA256.Create()) certificate = Convert.ToBase64String(hash.ComputeHash(pinnedCertificate));
        string lockPath = Path.Combine(directory, "knot-account.lock");
        try {
            mutex = Open(lockPath, FileMode.OpenOrCreate);
            Validate(mutex);
        } catch { if (mutex != null) mutex.Dispose(); throw new SunshineSetupFailure("다른 Knot 준비 창이 열려 있거나 계정 보관함을 안전하게 열 수 없습니다. 다른 준비 창을 닫은 뒤 다시 시도하세요. 기존 계정은 변경하지 않습니다."); }
    }
    private static FileSecurity Security()
    {
        var security = new FileSecurity(); security.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
        security.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null), FileSystemRights.FullControl, AccessControlType.Allow));
        return security;
    }
    private static FileStream Open(string file, FileMode mode)
    {
        if (File.Exists(file)) SunshineSetupPolicy.Require((File.GetAttributes(file) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0);
        return new FileStream(file, mode, FileSystemRights.Read | FileSystemRights.Write | FileSystemRights.ReadPermissions,
            FileShare.None, 4096, FileOptions.None, Security());
    }
    [StructLayout(LayoutKind.Sequential)] private struct FileInformation {
        internal uint Attributes, CreatedLow, CreatedHigh, AccessLow, AccessHigh, WriteLow, WriteHigh,
            Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation info);
    private static void Validate(FileStream stream)
    {
        FileInformation info; SunshineSetupPolicy.Require(GetFileInformationByHandle(stream.SafeFileHandle, out info) && info.Links == 1 && (info.Attributes & 0x410) == 0);
        var acl = stream.GetAccessControl();
        SunshineSetupPolicy.Require(acl.AreAccessRulesProtected && SunshineSetupPolicy.TrustedSid(acl.GetOwner(typeof(SecurityIdentifier)).Value));
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            SunshineSetupPolicy.Require(SunshineSetupPolicy.SafeKeyAclRule(rule.IdentityReference.Value, (int)rule.FileSystemRights,
                rule.AccessControlType == AccessControlType.Allow, (rule.PropagationFlags & PropagationFlags.InheritOnly) != 0));
    }
    public SunshineAccountRecord Read()
    { lock (gate) { if (disposed) throw new ObjectDisposedException("Knot account store"); return ReadCore(); } }
    private SunshineAccountRecord ReadCore()
    {
        if (!File.Exists(path)) return null;
        byte[] encrypted = null, clear = null;
        try {
            using (var input = Open(path, FileMode.Open)) {
                Validate(input); SunshineSetupPolicy.Require(input.Length > 0 && input.Length <= 32768);
                encrypted = new byte[(int)input.Length]; int at = 0;
                while (at < encrypted.Length) { int got = input.Read(encrypted, at, encrypted.Length - at); SunshineSetupPolicy.Require(got > 0); at += got; }
            }
            clear = ProtectedData.Unprotect(encrypted, Entropy, DataProtectionScope.LocalMachine);
            return SunshineAccountCodec.Decode(clear, certificate);
        } catch { throw new SunshineSetupFailure("보관한 Sunshine 계정을 확인하지 못했습니다. 인증서나 계정 보관함이 변경되었을 수 있습니다. 계정 또는 인증서를 자동으로 덮어쓰지 않습니다. 고급·수동 설정을 확인하세요."); }
        finally { if (clear != null) Array.Clear(clear, 0, clear.Length); if (encrypted != null) Array.Clear(encrypted, 0, encrypted.Length); }
    }
    public void Save(SunshineAccountRecord account)
    { lock (gate) { if (disposed) throw new ObjectDisposedException("Knot account store"); SaveCore(account); } }
    private void SaveCore(SunshineAccountRecord account)
    {
        byte[] clear = null, encrypted = null; string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        bool created = false;
        try {
            clear = SunshineAccountCodec.Encode(account, certificate); encrypted = ProtectedData.Protect(clear, Entropy, DataProtectionScope.LocalMachine);
            using (var output = Open(temporary, FileMode.CreateNew)) { created = true; Validate(output); output.Write(encrypted, 0, encrypted.Length); output.Flush(true); }
            if (File.Exists(path)) { using (var previous = Open(path, FileMode.Open)) Validate(previous); File.Replace(temporary, path, null); }
            else File.Move(temporary, path);
            created = false;
            using (var committed = Open(path, FileMode.Open)) Validate(committed);
        } finally {
            if (clear != null) Array.Clear(clear, 0, clear.Length); if (encrypted != null) Array.Clear(encrypted, 0, encrypted.Length);
            if (created) try { File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
    public void Dispose() { lock (gate) { if (!disposed) { disposed = true; mutex.Dispose(); } } }
}
#endif
