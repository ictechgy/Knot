// SPDX-License-Identifier: GPL-3.0-only
// Fresh inert protocol fixtures only. No HTTP implementation, Forms, files or host APIs.
public static class SunshineQuickSetupChecks
{
    private static int count, windowsAclChecks;
    private static void Check(bool value) { if (!value) throw new System.Exception("Quick setup fixture failed."); count++; }
    private static void Reject(System.Action action)
    { bool rejected = false; try { action(); } catch (SunshineSetupFailure) { rejected = true; } Check(rejected); }
    private static SunshineApiReply Reply(string body) { return new SunshineApiReply(200, body); }
    private const string Success = "{\"status\":true}";
    private const string BasicConfig = "{\"status\":true,\"platform\":\"windows\",\"version\":\"2026.914.233613\",\"encoder\":\"nvenc\",\"bitrate\":\"80000\"}";
    private const string SecureConfig = "{\"status\":true,\"platform\":\"windows\",\"version\":\"2026.914.233613\",\"encoder\":\"nvenc\",\"bitrate\":\"80000\",\"lan_encryption_mode\":\"2\",\"wan_encryption_mode\":\"2\",\"upnp\":\"disabled\",\"origin_web_ui_allowed\":\"pc\"}";
    private const string Pairs = "{\"pairings\":[{\"id\":\"0123456789abcdef0123456789abcdef\",\"name\":\"Synthetic Mac\",\"address\":\"192.168.1.4\"}]}";
    private static void CheckAncestorTrustBoundary()
    {
        int calls = 0;
        SunshineSetupPolicy.ValidateProtectedAncestors(delegate { calls++; }); Check(calls == 1);
        calls = 0; bool trustFailure = false;
        try { SunshineSetupPolicy.ValidateProtectedAncestors(delegate { calls++; throw new System.IO.IOException("Synthetic ancestor policy rejection."); }); }
        catch (SunshineSetupFailure error) { trustFailure = error.Message == SunshineSetupPolicy.Manual; }
        Check(trustFailure && calls == 1);
        calls = 0; var original = new SunshineSetupFailure("Synthetic authored trust failure."); SunshineSetupFailure caught = null;
        try { SunshineSetupPolicy.ValidateProtectedAncestors(delegate { calls++; throw original; }); }
        catch (SunshineSetupFailure error) { caught = error; }
        Check(calls == 1 && System.Object.ReferenceEquals(original, caught));
    }
    private static void CheckWindowsAclProjection()
    {
        // Managed security-descriptor values only. No path, file/key handle,
        // GetSecurityInfo or OS ACL read/write participates in these fixtures.
        if (System.Environment.OSVersion.Platform != System.PlatformID.Win32NT) return;
        int before = count;
        var system = new System.Security.Principal.SecurityIdentifier(new byte[] { 1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0 }, 0);
        var everyone = new System.Security.Principal.SecurityIdentifier(new byte[] { 1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 }, 0);
        // 0 absent DACL, 1 present NULL DACL, 2 empty deny-all DACL,
        // 3 explicit Everyone FullControl, 4 explicit SYSTEM FullControl.
        for (int mode = 0; mode < 5; mode++)
        {
            System.Security.AccessControl.RawAcl dacl = mode < 2 ? null : new System.Security.AccessControl.RawAcl(2, 1);
            if (mode >= 3) dacl.InsertAce(0, new System.Security.AccessControl.CommonAce(System.Security.AccessControl.AceFlags.None,
                System.Security.AccessControl.AceQualifier.AccessAllowed, 0x1f01ff, mode == 3 ? everyone : system, false, null));
            var flags = mode == 0 ? System.Security.AccessControl.ControlFlags.None : System.Security.AccessControl.ControlFlags.DiscretionaryAclPresent;
            var raw = new System.Security.AccessControl.RawSecurityDescriptor(flags, system, null, null, dacl);
            var bytes = new byte[raw.BinaryLength]; raw.GetBinaryForm(bytes, 0);
            var common = new System.Security.AccessControl.CommonSecurityDescriptor(false, false, bytes, 0);
            Check(common.DiscretionaryAcl != null && (common.ControlFlags & System.Security.AccessControl.ControlFlags.DiscretionaryAclPresent) != 0);
            Check(common.DiscretionaryAcl.Count == (mode == 2 ? 0 : 1));
            if (mode < 2)
            {
                var ace = common.DiscretionaryAcl[0] as System.Security.AccessControl.CommonAce;
                Check(ace != null && ace.SecurityIdentifier.Equals(everyone) && ace.AccessMask == -1);
            }
            foreach (var projected in new System.Security.AccessControl.FileSystemSecurity[] {
                new System.Security.AccessControl.FileSecurity(), new System.Security.AccessControl.DirectorySecurity() })
            {
                projected.SetSecurityDescriptorBinaryForm(bytes, System.Security.AccessControl.AccessControlSections.Access | System.Security.AccessControl.AccessControlSections.Owner);
                Check(SunshineSetupPolicy.TrustedSid(projected.GetOwner(typeof(System.Security.Principal.SecurityIdentifier)).Value));
                var rules = projected.GetAccessRules(true, true, typeof(System.Security.Principal.SecurityIdentifier));
                Check(rules.Count == (mode == 2 ? 0 : 1)); bool safe = true, confidential = true;
                foreach (System.Security.AccessControl.FileSystemAccessRule rule in rules)
                {
                    bool allow = rule.AccessControlType == System.Security.AccessControl.AccessControlType.Allow;
                    bool inheritOnly = (rule.PropagationFlags & System.Security.AccessControl.PropagationFlags.InheritOnly) != 0;
                    safe &= SunshineSetupPolicy.SafeAclRule(rule.IdentityReference.Value, (int)rule.FileSystemRights, allow, inheritOnly);
                    confidential &= SunshineSetupPolicy.SafeKeyAclRule(rule.IdentityReference.Value, (int)rule.FileSystemRights, allow, inheritOnly);
                    if (mode < 2) Check(rule.IdentityReference.Equals(everyone) && (int)rule.FileSystemRights == -1);
                }
                Check(safe == (mode == 2 || mode == 4) && confidential == (mode == 2 || mode == 4));
            }
        }
        windowsAclChecks = count - before;
    }
    private sealed class Resource : System.IDisposable
    {
        internal int Disposals;
        public void Dispose() { System.Threading.Interlocked.Increment(ref Disposals); }
    }
    private static void CheckIdempotentCleanup()
    {
        foreach (bool formClosing in new bool[] { true, false })
        {
            int started = 0, cleanupCalls = 0, cancellations = 0;
            var cancellation = new System.Threading.CancellationTokenSource(); var resource = new Resource();
            cancellation.Token.Register(delegate { System.Threading.Interlocked.Increment(ref cancellations); });
            // Ordinary FormClosing cancels early; direct disposal has no such event.
            if (formClosing) cancellation.Cancel();
            System.Action cleanup = delegate { cleanupCalls++; cancellation.Cancel(); resource.Dispose(); cancellation.Dispose(); };
            SunshineSetupCleanup.Once(ref started, cleanup); // WinForms Close/Dispose
            SunshineSetupCleanup.Once(ref started, cleanup); // enclosing using/Dispose
            Check(cleanupCalls == 1 && cancellations == 1 && resource.Disposals == 1);
        }
    }
    private static void CheckOwnedFactory()
    {
        using (var cancel = new System.Threading.CancellationTokenSource())
        {
            cancel.Cancel(); int created = 0; bool canceled = false;
            try { SunshineSetupResourceFactory.CreateAsync(delegate { created++; return new Resource(); }, cancel.Token).GetAwaiter().GetResult(); }
            catch (System.OperationCanceledException) { canceled = true; }
            Check(canceled && created == 0);
        }
        using (var cancel = new System.Threading.CancellationTokenSource())
        {
            var resource = new Resource(); bool canceled = false;
            try { SunshineSetupResourceFactory.CreateAsync(delegate { cancel.Cancel(); return resource; }, cancel.Token).GetAwaiter().GetResult(); }
            catch (System.OperationCanceledException) { canceled = true; }
            Check(canceled && resource.Disposals == 1);
        }
        using (var cancel = new System.Threading.CancellationTokenSource())
        {
            var resource = new Resource();
            using (var owned = SunshineSetupResourceFactory.CreateAsync(delegate { return resource; }, cancel.Token).GetAwaiter().GetResult())
            {
                // The UI continuation has not accepted the completed result yet.
                cancel.Cancel(); Check(resource.Disposals == 1); bool canceled = false;
                try { owned.Take(cancel.Token, true); } catch (System.OperationCanceledException) { canceled = true; }
                Check(canceled && resource.Disposals == 1);
            }
            Check(resource.Disposals == 1);
        }
        {
            var resource = new Resource();
            using (var owned = SunshineSetupResourceFactory.CreateAsync(delegate { return resource; }, System.Threading.CancellationToken.None).GetAwaiter().GetResult())
            {
                bool closed = false; try { owned.Take(System.Threading.CancellationToken.None, false); } catch (System.OperationCanceledException) { closed = true; }
                Check(closed && resource.Disposals == 1);
            }
            Check(resource.Disposals == 1);
        }
        using (var cancel = new System.Threading.CancellationTokenSource())
        {
            var resource = new Resource(); int caller = System.Threading.Thread.CurrentThread.ManagedThreadId, worker = caller;
            using (var owned = SunshineSetupResourceFactory.CreateAsync(delegate { worker = System.Threading.Thread.CurrentThread.ManagedThreadId; return resource; }, cancel.Token).GetAwaiter().GetResult())
            {
                Check(worker != caller);
                Resource accepted = owned.Take(cancel.Token, true); Check(System.Object.ReferenceEquals(accepted, resource) && resource.Disposals == 0);
                cancel.Cancel(); Check(resource.Disposals == 0); accepted.Dispose();
            }
            Check(resource.Disposals == 1);
        }
        foreach (bool busy in new bool[] { false, true })
            foreach (bool ready in new bool[] { false, true })
                foreach (bool selected in new bool[] { false, true })
                    Check(SunshineSetupPolicy.CanPair(busy, ready, selected) == (!busy && ready && selected));
        string guidance = null; try { SunshineSetupPolicy.PairBody(null, "1234"); } catch (SunshineSetupFailure error) { guidance = error.Message; }
        Check(guidance == "연결할 Mac 요청을 먼저 선택하세요.");
    }
    private sealed class DispatchStream : System.IO.MemoryStream
    {
        internal System.Action OnWrite; internal bool Closed;
        public override System.Threading.Tasks.Task WriteAsync(byte[] buffer, int offset, int count, System.Threading.CancellationToken cancellation)
        { cancellation.ThrowIfCancellationRequested(); Write(buffer, offset, count); if (OnWrite != null) OnWrite(); return System.Threading.Tasks.Task.FromResult(0); }
        protected override void Dispose(bool disposing) { Closed = true; base.Dispose(disposing); }
    }
    private static void CheckDispatch()
    {
        bool oldAlive = true; int verifications = 0, opens = 0, responses = 0;
        var stream = new DispatchStream { OnWrite = delegate { oldAlive = false; } };
        string result = SunshineSetupDispatch.SendAsync(new byte[] { 1, 2 },
            delegate { verifications++; SunshineSetupPolicy.Require(oldAlive); },
            delegate { opens++; Check(verifications == 1 && oldAlive); return System.Threading.Tasks.Task.FromResult<System.IO.Stream>(stream); },
            delegate { responses++; Check(!oldAlive && verifications == 1 && stream.Closed); return System.Threading.Tasks.Task.FromResult("restart response collected"); },
            System.Threading.CancellationToken.None).GetAwaiter().GetResult();
        Check(result == "restart response collected" && verifications == 1 && opens == 1 && responses == 1);
        // GET still verifies immediately before sending headers, without opening a body stream.
        oldAlive = true; verifications = opens = responses = 0;
        result = SunshineSetupDispatch.SendAsync<string>(null,
            delegate { verifications++; SunshineSetupPolicy.Require(oldAlive); },
            delegate { opens++; throw new System.Exception("GET must not write a request body."); },
            delegate { responses++; Check(verifications == 1 && opens == 0); return System.Threading.Tasks.Task.FromResult("GET"); },
            System.Threading.CancellationToken.None).GetAwaiter().GetResult();
        Check(result == "GET" && responses == 1);
        // Losing trust before dispatch still fails immediately; no body or headers are sent.
        oldAlive = false; opens = responses = 0;
        Reject(delegate { SunshineSetupDispatch.SendAsync<string>(new byte[] { 1 },
            delegate { SunshineSetupPolicy.Require(oldAlive); },
            delegate { opens++; return System.Threading.Tasks.Task.FromResult<System.IO.Stream>(new DispatchStream()); },
            delegate { responses++; return System.Threading.Tasks.Task.FromResult("unexpected"); },
            System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
        Check(opens == 0 && responses == 0);
        // A certificate/trust failure while collecting a response is never converted into socket-close success.
        Reject(delegate { SunshineSetupDispatch.SendAsync<string>(new byte[] { 1 }, delegate { },
            delegate { return System.Threading.Tasks.Task.FromResult<System.IO.Stream>(new DispatchStream()); },
            delegate { throw new SunshineSetupFailure("Synthetic trust failure."); },
            System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
        using (var cancel = new System.Threading.CancellationTokenSource())
        {
            cancel.Cancel(); int checkedTrust = 0; bool canceled = false;
            try { SunshineSetupDispatch.SendAsync<string>(null, delegate { checkedTrust++; }, null, null, cancel.Token).GetAwaiter().GetResult(); }
            catch (System.OperationCanceledException) { canceled = true; }
            Check(canceled && checkedTrust == 0);
        }
    }
    private sealed class Witness : ISunshineRestartWitness
    {
        internal bool Exited = true, Replacement = true, Waited, Verified, Disposed, Block;
        internal System.Threading.CancellationTokenSource CancelOnWait;
        public async System.Threading.Tasks.Task WaitForExitAsync(System.Threading.CancellationToken cancel)
        {
            Waited = true;
            if (CancelOnWait != null) CancelOnWait.Cancel();
            cancel.ThrowIfCancellationRequested();
            if (Block) await System.Threading.Tasks.Task.Delay(System.Threading.Timeout.Infinite, cancel);
            SunshineSetupPolicy.Require(Exited);
        }
        public void VerifyReplacement(System.Threading.CancellationToken cancel)
        { cancel.ThrowIfCancellationRequested(); Verified = true; SunshineSetupPolicy.Require(Waited && Exited && Replacement); }
        public void Dispose() { Disposed = true; }
    }
    private static byte[] Row(uint address, int port, uint pid, uint state = 2)
    {
        var row = new byte[24]; System.Buffer.BlockCopy(System.BitConverter.GetBytes(state), 0, row, 0, 4);
        System.Buffer.BlockCopy(System.BitConverter.GetBytes(address), 0, row, 4, 4);
        row[8] = (byte)(port >> 8); row[9] = (byte)port;
        System.Buffer.BlockCopy(System.BitConverter.GetBytes(pid), 0, row, 20, 4); return row;
    }
    private static byte[] Table(params byte[][] rows)
    {
        var result = new byte[4 + rows.Length * 24]; System.Buffer.BlockCopy(System.BitConverter.GetBytes((uint)rows.Length), 0, result, 0, 4);
        for (int i = 0; i < rows.Length; i++) System.Buffer.BlockCopy(rows[i], 0, result, 4 + i * 24, 24); return result;
    }
    private sealed class Fake : ISunshineSetupApi
    {
        internal readonly System.Collections.Generic.Queue<SunshineApiReply> Replies = new System.Collections.Generic.Queue<SunshineApiReply>();
        internal readonly System.Collections.Generic.List<string> Paths = new System.Collections.Generic.List<string>();
        internal readonly System.Collections.Generic.List<string> Bodies = new System.Collections.Generic.List<string>();
        internal readonly System.Collections.Generic.List<string> Auth = new System.Collections.Generic.List<string>();
        internal System.Action<string> OnSend;
        internal Witness Witness = new Witness(); internal bool Captured, BlockReadback;
        private async System.Threading.Tasks.Task<SunshineApiReply> BlockAsync(System.Threading.CancellationToken cancel)
        { await System.Threading.Tasks.Task.Delay(System.Threading.Timeout.Infinite, cancel); throw new System.Exception("Unreachable fixture path."); }
        internal Fake(params SunshineApiReply[] replies) { foreach (var reply in replies) Replies.Enqueue(reply); }
        public ISunshineRestartWitness CaptureRestart(System.Threading.CancellationToken cancel)
        { cancel.ThrowIfCancellationRequested(); Captured = true; return Witness; }
        public System.Threading.Tasks.Task<SunshineApiReply> SendAsync(string path, string body, string auth, System.Threading.CancellationToken cancel)
        { cancel.ThrowIfCancellationRequested(); if (OnSend != null) OnSend(path); Paths.Add(path); Bodies.Add(body); Auth.Add(auth); if (Captured && Witness.Waited && path == "/api/config" && BlockReadback) return BlockAsync(cancel); if (path == "/api/restart") Check(Captured && !Witness.Waited); var reply = Replies.Dequeue(); if (reply == null) throw new System.IO.IOException(); return System.Threading.Tasks.Task.FromResult(reply); }
    }
    private static SunshineSetupSession Session(Fake fake)
    { return new SunshineSetupSession(fake, delegate(int ignored, System.Threading.CancellationToken cancel) { cancel.ThrowIfCancellationRequested(); return System.Threading.Tasks.Task.FromResult(0); }); }
    private static void Prepare(SunshineSetupSession session, bool first = false)
    { session.PrepareAsync("fixture", "synthetic-password-1234", first, System.Threading.CancellationToken.None).GetAwaiter().GetResult(); }
    private static void PrepareForced(SunshineSetupSession session)
    { Prepare(session); if (!session.Configured) session.ReapplySecurityAsync(System.Threading.CancellationToken.None).GetAwaiter().GetResult(); }
    private sealed class AccountStore : ISunshineAccountStore
    {
        internal SunshineAccountRecord Value; internal int Saves, FailAt;
        public SunshineAccountRecord Read() { return Value == null ? null : SunshineAccountCodec.Decode(SunshineAccountCodec.Encode(Value, "synthetic-cert"), "synthetic-cert"); }
        public void Save(SunshineAccountRecord value) {
            Saves++; if (FailAt == Saves) throw new SunshineSetupFailure("Synthetic storage failure");
            Value = SunshineAccountCodec.Decode(SunshineAccountCodec.Encode(value, "synthetic-cert"), "synthetic-cert");
        }
    }
    private static SunshineAccountRecord Generated() { return new SunshineAccountRecord { Username = "knot", Password = "synthetic-generated-password-1234567890", Recovery = true }; }
    private static void AccountPrepare(SunshineAccountController controller, SunshineSetupSession session, bool manual = false, bool verified = true)
    { controller.PrepareAsync(session, manual, "old-user", "old-synthetic-password", verified, System.Threading.CancellationToken.None).GetAwaiter().GetResult(); }
    private static void CheckAccountAutomation()
    {
        Check(!SunshineSetupPolicy.ExistingPath(delegate { throw new System.IO.FileNotFoundException(); }, false));
        Check(!SunshineSetupPolicy.ExistingPath(delegate { throw new System.IO.DirectoryNotFoundException(); }, true));
        Check(SunshineSetupPolicy.ExistingPath(delegate { return System.IO.FileAttributes.Directory; }, true));
        Check(SunshineSetupPolicy.ExistingPath(delegate { return System.IO.FileAttributes.Normal; }, false));
        Reject(delegate { SunshineSetupPolicy.ExistingPath(delegate { return System.IO.FileAttributes.ReparsePoint; }, false); });
        Reject(delegate { SunshineSetupPolicy.ExistingPath(delegate { return System.IO.FileAttributes.Normal; }, true); });
        bool accessRefused = false; try { SunshineSetupPolicy.ExistingPath(delegate { throw new System.UnauthorizedAccessException(); }, true); } catch (System.UnauthorizedAccessException) { accessRefused = true; } Check(accessRefused);
        bool ioRefused = false; try { SunshineSetupPolicy.ExistingPath(delegate { throw new System.IO.IOException(); }, false); } catch (System.IO.IOException) { ioRefused = true; } Check(ioRefused);
        var selected = new SunshinePendingPair { ID = "same", Name = "Mac", Address = "192.168.1.2" };
        Check(SunshineSetupPolicy.SamePending(selected, new SunshinePendingPair { ID = "same", Name = "Mac", Address = "192.168.1.2" }));
        Check(!SunshineSetupPolicy.SamePending(selected, new SunshinePendingPair { ID = "same", Name = "Other", Address = "192.168.1.2" }));
        Check(!SunshineSetupPolicy.SamePending(selected, null));
        string service = @"C:\Program Files\Sunshine\tools\sunshinesvc.exe";
        Check(SunshineServicePolicy.Trusted(16, 3, "\"" + service + "\"", "LocalSystem", service));
        Check(!SunshineServicePolicy.Trusted(16, 3, service, "LocalSystem", service));
        Check(!SunshineServicePolicy.Trusted(16, 3, "\"" + service + "\" --extra", "LocalSystem", service));
        Check(!SunshineServicePolicy.Trusted(16, 4, "\"" + service + "\"", "LocalSystem", service));
        Check(!SunshineServicePolicy.Trusted(272, 3, "\"" + service + "\"", "LocalSystem", service));
        Check(!SunshineServicePolicy.Trusted(16, 3, "\"" + service + "\"", "untrusted-user", service));
        var welcome = new SunshineApiReply(307, "", "/welcome"); var denied = new SunshineApiReply(401, "");
        var store = new AccountStore(); int generated = 0;
        var controller = new SunshineAccountController(store, delegate { generated++; return Generated(); });
        var api = new Fake(welcome, welcome, Reply(Success), Reply(SecureConfig), Reply("{}"), Reply(SecureConfig));
        api.OnSend = delegate(string path) { if (path == "/api/password") Check(store.Value != null && store.Value.Recovery && store.Saves >= 1); };
        var session = Session(api); AccountPrepare(controller, session);
        Check(session.PairingReady && session.Configured && !store.Value.Recovery && generated == 1);
        Check(api.Paths.Count == 6 && api.Paths[2] == "/api/password");
        Check((string)SunshineSetupJson.Object(api.Bodies[2])["newPassword"] == Generated().Password);
        // First write failure must happen before the account creation request.
        store = new AccountStore { FailAt = 1 }; api = new Fake(welcome);
        Reject(delegate { AccountPrepare(new SunshineAccountController(store, Generated), Session(api)); }); Check(api.Paths.Count == 1 && store.Value == null);
        // Lost POST response keeps the original random credential and recovery flag.
        store = new AccountStore(); controller = new SunshineAccountController(store, Generated); api = new Fake(welcome, welcome, null);
        bool lost = false; try { AccountPrepare(controller, Session(api)); } catch (System.IO.IOException) { lost = true; }
        Check(lost && store.Value != null && store.Value.Recovery);
        string retained = store.Value.Password;
        api = new Fake(denied, Reply(SecureConfig), Reply("{}"), Reply(SecureConfig)); session = Session(api);
        AccountPrepare(new SunshineAccountController(store, delegate { throw new System.Exception("Must reuse journal"); }), session);
        Check(session.Configured && !store.Value.Recovery && store.Value.Password == retained && !api.Paths.Contains("/api/password"));
        // A request that never committed retries creation using that same journal.
        store.Value.Recovery = true; api = new Fake(welcome, Reply(Success), Reply(SecureConfig), Reply("{}"), Reply(SecureConfig));
        AccountPrepare(new SunshineAccountController(store, delegate { throw new System.Exception("Must not regenerate"); }), Session(api));
        Check((string)SunshineSetupJson.Object(api.Bodies[1])["newPassword"] == retained);
        // Existing unknown account is never reset and incorrect input is never saved.
        store = new AccountStore(); api = new Fake(denied);
        bool login = false; try { AccountPrepare(new SunshineAccountController(store, Generated), Session(api)); } catch (SunshineLoginRequired) { login = true; }
        Check(login && store.Saves == 0 && api.Paths.Count == 1);
        api = new Fake(denied, denied); Reject(delegate { AccountPrepare(new SunshineAccountController(store, Generated), Session(api), true); });
        Check(store.Saves == 0 && !api.Paths.Contains("/api/password"));
        api = new Fake(denied, Reply(SecureConfig)); session = Session(api);
        AccountPrepare(new SunshineAccountController(store, Generated), session, true);
        Check(store.Saves == 1 && store.Value.Username == "old-user" && !store.Value.Recovery && session.PairingReady && !session.Configured);
        api = new Fake(denied, Reply(SecureConfig)); AccountPrepare(new SunshineAccountController(store), Session(api));
        Check(api.Auth[1] == SunshineSetupPolicy.Authorization("old-user", "old-synthetic-password") && !api.Paths.Contains("/api/restart"));
        // Persisted incomplete security application requires an observed restart after reopening.
        store.Value.Recovery = true; store.FailAt = store.Saves + 3;
        api = new Fake(denied, Reply(SecureConfig), Reply("{}"), Reply(SecureConfig)); session = Session(api);
        Reject(delegate { AccountPrepare(new SunshineAccountController(store), session); });
        Check(store.Value.Recovery && !session.PairingReady && !session.Configured && session.NeedsSecurityReapply);
        store.FailAt = 0; api = new Fake(denied, Reply(SecureConfig), Reply("{}"), Reply(SecureConfig)); session = Session(api);
        AccountPrepare(new SunshineAccountController(store), session); Check(session.Configured && !store.Value.Recovery);
        store = new AccountStore(); api = new Fake(welcome);
        Reject(delegate { AccountPrepare(new SunshineAccountController(store, Generated), Session(api), false, false); }); Check(store.Saves == 0);
        byte[] encoded = SunshineAccountCodec.Encode(Generated(), "synthetic-cert");
        Check(SunshineAccountCodec.Decode(encoded, "synthetic-cert").Password == Generated().Password);
        Reject(delegate { SunshineAccountCodec.Decode(encoded, "changed-cert"); });
        Reject(delegate { SunshineAccountCodec.Decode(System.Text.Encoding.UTF8.GetBytes("{}"), "synthetic-cert"); });
        Reject(delegate { SunshineAccountCodec.Decode(System.Text.Encoding.UTF8.GetBytes(System.Text.Encoding.UTF8.GetString(encoded).Replace("\"schema\":\"1\"", "\"schema\":\"2\"")), "synthetic-cert"); });
        using (var cancellation = new System.Threading.CancellationTokenSource()) {
            cancellation.Cancel(); bool canceled = false; controller = new SunshineAccountController(store, Generated);
            try { controller.PrepareAsync(Session(new Fake()), false, null, null, true, cancellation.Token).GetAwaiter().GetResult(); } catch (System.OperationCanceledException) { canceled = true; }
            Check(canceled && store.Saves == 0);
        }
    }
    public static void Main() { System.Console.WriteLine(Run()); }
    public static string Run()
    {
        count = 0; windowsAclChecks = 0; CheckAncestorTrustBoundary(); CheckWindowsAclProjection(); CheckDispatch(); CheckOwnedFactory(); CheckIdempotentCleanup(); CheckAccountAutomation();
        Check(SunshineSetupPolicy.TrustedProcessSid("S-1-5-18"));
        Check(!SunshineSetupPolicy.TrustedProcessSid("S-1-5-32-544"));
        Check(!SunshineSetupPolicy.TrustedProcessSid("S-1-5-21-1-2-3-1001"));
        Check(!SunshineSetupPolicy.SafeKeyAclRule("S-1-5-32-545", 0x1, true, false));
        Check(!SunshineSetupPolicy.SafeKeyAclRule("S-1-5-32-545", unchecked((int)0x80000000), true, false));
        Check(SunshineSetupPolicy.SafeKeyAclRule("S-1-5-32-545", 0x20080, true, false));
        Check(SunshineSetupPolicy.SafeKeyAclRule("S-1-3-0", 0x1f01ff, true, true));
        Check(!SunshineSetupPolicy.SafeKeyAclRule("S-1-3-0", 0x1f01ff, true, false));
        Check(SunshineSetupPolicy.SafeKeyAclRule("S-1-5-18", 0x1f01ff, true, false));
        Check(SunshineSetupPolicy.TrustedSid("S-1-5-18"));
        Check(!SunshineSetupPolicy.TrustedSid("S-1-3-0"));
        Check(SunshineSetupPolicy.SafeAclRule("S-1-3-0", 0x1f01ff, true, true));
        Check(!SunshineSetupPolicy.SafeAclRule("S-1-3-0", 0x1f01ff, true, false));
        Check(!SunshineSetupPolicy.SafeAclRule("S-1-5-32-545", 0x116, true, false));
        Check(!SunshineSetupPolicy.SafeAclRule("S-1-5-32-545", 0x40, true, false));
        Check(SunshineSetupPolicy.SafeAclRule("S-1-5-32-545", 0x116, false, false));
        Check(SunshineSetupPolicy.SafeAclRule("S-1-5-18", 0x1f01ff, true, false));
        Check(SunshineSetupPolicy.SafeAclRule("S-1-5-32-545", 0x120089, true, false));
        Check(SunshineSetupPolicy.ListenerPid(Table(), true) == 0);
        Check(SunshineSetupPolicy.ListenerPid(Table(Row(0, 47990, 42))) == 42);
        Check(SunshineSetupPolicy.ListenerPid(Table(Row(0x0100007f, 47990, 43), Row(0x0401a8c0, 47990, 99))) == 43);
        Reject(delegate { SunshineSetupPolicy.ListenerPid(Table(Row(0, 47990, 42), Row(0x0100007f, 47990, 43))); });
        Reject(delegate { SunshineSetupPolicy.ListenerPid(Table(Row(0x0401a8c0, 47990, 42))); });
        Reject(delegate { SunshineSetupPolicy.ListenerPid(Table(Row(0, 47989, 42))); });
        Reject(delegate { SunshineSetupPolicy.ListenerPid(Table(Row(0, 47990, 42, 5))); });
        Reject(delegate { SunshineSetupPolicy.ListenerPid(Table(Row(0, 47990, 0))); });
        Reject(delegate { SunshineSetupPolicy.ListenerPid(Table(Row(0, 47990, System.UInt32.MaxValue))); });
        Reject(delegate { SunshineSetupPolicy.ListenerPid(new byte[] { 1, 0, 0, 0 }); });
        Reject(delegate { SunshineSetupPolicy.ListenerPid(new byte[] { 255, 255, 255, 255 }); });
        Check(SunshineSetupPolicy.Matches(new byte[] { 1, 2 }, new byte[] { 1, 2 }));
        Check(!SunshineSetupPolicy.Matches(new byte[] { 1, 2 }, new byte[] { 1, 3 }));
        Check(!SunshineSetupPolicy.Matches(new byte[] { 1 }, new byte[] { 1, 2 }));
        Check(!SunshineSetupPolicy.Matches(null, new byte[] { 1 }));
        Check(!SunshineSetupPolicy.Matches(new byte[0], new byte[0]));
        Reject(delegate { SunshineSetupPolicy.ValidateCredentials("fixture:x", "long-synthetic-password", false); });
        Reject(delegate { SunshineSetupPolicy.ValidateCredentials("fixture", "short", true); });
        Reject(delegate { SunshineSetupPolicy.ValidateCredentials("fixture", "line\nbreak", false); });
        Reject(delegate { SunshineSetupPolicy.ValidateCredentials("fixture", "invisible\u202espoof", false); });
        SunshineSetupPolicy.ValidateCredentials("fixture", "existing-short", false); count++;
        Check(SunshineSetupPolicy.IsWelcome(new SunshineApiReply(307, "", "/welcome")));
        Check(!SunshineSetupPolicy.IsWelcome(new SunshineApiReply(302, "", "/welcome")));
        Check(!SunshineSetupPolicy.IsWelcome(new SunshineApiReply(307, "", "https://elsewhere/welcome")));
        var config = SunshineSetupPolicy.Config(Reply(BasicConfig));
        var desired = SunshineSetupPolicy.Secure(config);
        Check((string)desired["encoder"] == "nvenc" && (string)desired["bitrate"] == "80000" && desired.Count == 6);
        Check(!desired.ContainsKey("status") && !desired.ContainsKey("version") && !desired.ContainsKey("platform"));
        Check((string)desired["lan_encryption_mode"] == "2" && (string)desired["wan_encryption_mode"] == "2");
        Check((string)desired["upnp"] == "disabled" && (string)desired["origin_web_ui_allowed"] == "pc");
        Check(!config.ContainsKey("upnp"));
        Check(SunshineSetupPolicy.Equal(desired, SunshineSetupPolicy.Config(Reply(SecureConfig))));
        Reject(delegate { SunshineSetupPolicy.Config(Reply(BasicConfig.Replace("2026.914.233613", "2026.914.233614"))); });
        Reject(delegate { SunshineSetupPolicy.Config(Reply(BasicConfig.Replace("windows", "linux"))); });
        Reject(delegate { SunshineSetupPolicy.Config(Reply(BasicConfig.Replace("true", "false"))); });
        Reject(delegate { SunshineSetupPolicy.Config(new SunshineApiReply(401, BasicConfig)); });
        Reject(delegate { SunshineSetupPolicy.Config(Reply(BasicConfig.Replace("nvenc", "nvenc\\nupnp = enabled"))); });
        Reject(delegate { SunshineSetupJson.Object("{\"x\":\"one\",\"x\":\"two\"}"); });
        Reject(delegate { SunshineSetupJson.Object("{\"x\":1}"); });
        Reject(delegate { SunshineSetupJson.Object("{\"x\":\"\\ud800\"}"); });
        Reject(delegate { SunshineSetupJson.Object("{\"x\":\"a\"} trailing"); });
        Reject(delegate { SunshineSetupJson.Object("{\"x\":[[[[[[[[[[]]]]]]]]]]}"); });
        Reject(delegate { SunshineSetupJson.Object(new string(' ', SunshineSetupPolicy.MaximumBody + 1)); });
        string roundtrip = SunshineSetupJson.Write(new System.Collections.Generic.Dictionary<string, object> { { "path", "C:\\Synthetic\\test" }, { "quoted", "a\"b" } });
        Check((string)SunshineSetupJson.Object(roundtrip)["quoted"] == "a\"b");
        SunshineSetupPolicy.Success(Reply(Success)); count++;
        Reject(delegate { SunshineSetupPolicy.Success(Reply("{\"status\":false}")); });
        Reject(delegate { SunshineSetupPolicy.Success(Reply("{\"status\":\"true\"}")); });
        var pairs = SunshineSetupPolicy.Pairings(Reply(Pairs)); Check(pairs.Count == 1 && pairs[0].Address == "192.168.1.4");
        Reject(delegate { SunshineSetupPolicy.Pairings(Reply(Pairs.Replace("0123456789abcdef0123456789abcdef", "invalid"))); });
        Reject(delegate { SunshineSetupPolicy.Pairings(Reply(Pairs.Replace("192.168.1.4", "arbitrary.local"))); });
        Reject(delegate { SunshineSetupPolicy.PairBody(null, "1234"); });
        Reject(delegate { SunshineSetupPolicy.PairBody(pairs[0], "１２３４"); });
        Reject(delegate { SunshineSetupPolicy.PairBody(pairs[0], "12345"); });
        Check((string)SunshineSetupJson.Object(SunshineSetupPolicy.PairBody(pairs[0], "1234"))["pairing_id"] == pairs[0].ID);
        // Existing account: no password write; merge keeps unrelated custom settings,
        // readback precedes explicit restart, post-restart readback is required.
        var existing = new Fake(new SunshineApiReply(401, ""), Reply(BasicConfig), Reply(BasicConfig), Reply(Success), Reply(SecureConfig), Reply("{}"), Reply(SecureConfig));
        var session = Session(existing); Prepare(session);
        Check(session.Configured && existing.Paths.Count == 7);
        Check(existing.Witness.Waited && existing.Witness.Verified && existing.Witness.Disposed);
        Check(existing.Paths[3] == "/api/config" && existing.Paths[5] == "/api/restart" && existing.Paths[6] == "/api/config");
        Check(existing.Bodies[3] == SunshineSetupJson.Write(desired));
        Check(existing.Auth[0] == null && existing.Auth[1] == SunshineSetupPolicy.Authorization("fixture", "synthetic-password-1234"));
        Check(!existing.Paths.Contains("/api/password"));
        existing.Replies.Enqueue(Reply(Pairs)); existing.Replies.Enqueue(Reply(Success));
        session.PairAsync(pairs[0], "1234", System.Threading.CancellationToken.None).GetAwaiter().GetResult();
        Check(existing.Paths[existing.Paths.Count - 2] == "/api/pin" && existing.Bodies[existing.Bodies.Count - 2] == null);
        Check(existing.Bodies[existing.Bodies.Count - 1] == SunshineSetupPolicy.PairBody(pairs[0], "1234"));
        existing.Replies.Enqueue(Reply("{\"pairings\":[]}"));
        Reject(delegate { session.PairAsync(pairs[0], "1234", System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
        Check(existing.Bodies[existing.Bodies.Count - 1] == null); // stale request never posted
        session.Clear(); Reject(delegate { session.PendingAsync(System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
        var first = new Fake(new SunshineApiReply(307, "", "/welcome"), Reply(Success), Reply(SecureConfig), Reply("{}"), Reply(SecureConfig));
        var firstSession = Session(first); Prepare(firstSession, true);
        Check(firstSession.Configured && first.Paths[1] == "/api/password" && first.Auth[1] == null);
        Check((string)SunshineSetupJson.Object(first.Bodies[1])["currentPassword"] == "");
        var unverified = new Fake(new SunshineApiReply(307, "", "/welcome"));
        Reject(delegate { Prepare(Session(unverified)); }); Check(unverified.Paths.Count == 1);
        var mismatch = new Fake(new SunshineApiReply(401, ""), Reply(BasicConfig.Replace("2026.914.233613", "other")));
        Reject(delegate { Prepare(Session(mismatch)); }); Check(mismatch.Paths.Count == 2);
        var falsePair = new Fake(new SunshineApiReply(401, ""), Reply(SecureConfig));
        var falseSession = Session(falsePair); Prepare(falseSession); falsePair.Replies.Enqueue(Reply(Pairs)); falsePair.Replies.Enqueue(Reply("{\"status\":false}"));
        Reject(delegate { falseSession.PairAsync(pairs[0], "1234", System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
        var invalidPin = new Fake();
        Reject(delegate { Session(invalidPin).PairAsync(pairs[0], "1234", System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
        Check(invalidPin.Paths.Count == 0);
        // A Mac may already be waiting for PIN approval when this dialog is
        // reopened. Existing authenticated secure settings must preserve it.
        var pinOnly = new Fake(new SunshineApiReply(401, ""), Reply(SecureConfig), Reply(Pairs), Reply(Pairs), Reply(Success));
        var pinOnlySession = Session(pinOnly); Prepare(pinOnlySession);
        Check(pinOnlySession.PairingReady && !pinOnlySession.Configured && pinOnly.Paths.Count == 2 && !pinOnly.Captured);
        Check(pinOnlySession.PendingAsync(System.Threading.CancellationToken.None).GetAwaiter().GetResult().Count == 1);
        pinOnlySession.PairAsync(pairs[0], "1234", System.Threading.CancellationToken.None).GetAwaiter().GetResult();
        Check(!pinOnly.Paths.Contains("/api/restart") && !pinOnly.Paths.Contains("/api/password") && !pinOnly.Captured);
        Check(pinOnly.Paths.Count == 5 && pinOnly.Bodies[pinOnly.Bodies.Count - 1] == SunshineSetupPolicy.PairBody(pairs[0], "1234"));
        Check(SunshineSetupPolicy.ReadyMessage(false).Contains("재시작하지 않았으며") && SunshineSetupPolicy.ReadyMessage(false).Contains("다시 확인하지 않았습니다"));
        Check(SunshineSetupPolicy.ReadyMessage(true).Contains("새 연결 요청"));
        var reapply = new Fake(new SunshineApiReply(401, ""), Reply(SecureConfig), Reply(SecureConfig), Reply("{}"), Reply(SecureConfig));
        var reapplySession = Session(reapply); Prepare(reapplySession);
        Check(reapplySession.PairingReady && !reapplySession.Configured && reapply.Paths.Count == 2);
        reapplySession.ReapplySecurityAsync(System.Threading.CancellationToken.None).GetAwaiter().GetResult();
        Check(reapplySession.PairingReady && reapplySession.Configured && reapply.Witness.Verified && reapply.Witness.Disposed);
        Check(reapply.Paths.Count == 5 && reapply.Paths[2] == "/api/config" && reapply.Paths[3] == "/api/restart" && reapply.Paths[4] == "/api/config");
        Check(reapply.Auth[2] == reapply.Auth[1] && reapply.Auth[3] == reapply.Auth[1]);
        var unauthenticated = new Fake(new SunshineApiReply(401, ""), new SunshineApiReply(401, "{}"));
        var unauthenticatedSession = Session(unauthenticated); Reject(delegate { Prepare(unauthenticatedSession); });
        Check(!unauthenticatedSession.PairingReady && !unauthenticatedSession.Configured && !unauthenticated.Captured);
        Reject(delegate { unauthenticatedSession.PendingAsync(System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
        var neverSignedIn = Session(new Fake()); Reject(delegate { neverSignedIn.ReapplySecurityAsync(System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
        // A successful save followed by failure must never be mistaken for an
        // already-applied configuration on a retry in this same session.
        var partialRestart = new Fake(new SunshineApiReply(401, ""), Reply(BasicConfig), Reply(BasicConfig), Reply(Success), Reply(SecureConfig), new SunshineApiReply(500, "{}"),
            new SunshineApiReply(401, ""), Reply(SecureConfig), Reply("{}"), Reply(SecureConfig));
        var partialSession = Session(partialRestart); Reject(delegate { Prepare(partialSession); });
        Check(partialSession.NeedsSecurityReapply && partialSession.CanReapply && !partialSession.PairingReady && !partialSession.Configured);
        Check(partialRestart.Paths.Count == 6); partialRestart.Witness = new Witness(); Prepare(partialSession);
        Check(partialSession.Configured && partialSession.PairingReady && !partialSession.NeedsSecurityReapply && partialRestart.Paths.Count == 10);
        int configPosts = 0; for (int i = 0; i < partialRestart.Paths.Count; i++) if (partialRestart.Paths[i] == "/api/config" && partialRestart.Bodies[i] != null) configPosts++;
        Check(configPosts == 1 && partialRestart.Paths[8] == "/api/restart");
        var partialRead = new Fake(new SunshineApiReply(401, ""), Reply(BasicConfig), Reply(BasicConfig), Reply(Success), new SunshineApiReply(500, "{}"),
            new SunshineApiReply(401, ""), Reply(SecureConfig), Reply("{}"), Reply(SecureConfig));
        var partialReadSession = Session(partialRead); Reject(delegate { Prepare(partialReadSession); });
        Check(partialReadSession.NeedsSecurityReapply && partialReadSession.CanReapply && !partialReadSession.PairingReady && !partialRead.Captured);
        Prepare(partialReadSession); Check(partialReadSession.Configured && !partialReadSession.NeedsSecurityReapply && partialRead.Paths[7] == "/api/restart");
        var explicitRecovery = new Fake(new SunshineApiReply(401, ""), Reply(BasicConfig), Reply(BasicConfig), Reply(Success), new SunshineApiReply(500, "{}"),
            Reply(SecureConfig), Reply("{}"), Reply(SecureConfig));
        var recoverySession = Session(explicitRecovery); Reject(delegate { Prepare(recoverySession); });
        Check(recoverySession.CanReapply && !recoverySession.PairingReady);
        Check(SunshineSetupPolicy.RecoveryGuidance(recoverySession.NeedsSecurityReapply, recoverySession.CanReapply).Contains("보안 설정 다시 적용 · 재시작"));
        recoverySession.ReapplySecurityAsync(System.Threading.CancellationToken.None).GetAwaiter().GetResult();
        Check(recoverySession.Configured && recoverySession.PairingReady && !recoverySession.NeedsSecurityReapply && explicitRecovery.Paths.Count == 8);
        Check(explicitRecovery.Auth[5] == explicitRecovery.Auth[1]);
        Check(SunshineSetupPolicy.ReapplyRecovery.Contains("보안 설정 다시 적용 · 재시작") && SunshineSetupPolicy.ReadyMessage(false).Contains("이전 준비가 실패했거나 중단"));
        var firstAuthFailure = new Fake(new SunshineApiReply(307, "", "/welcome"), Reply(Success), new SunshineApiReply(500, "{}"));
        var firstAuthSession = Session(firstAuthFailure); Reject(delegate { Prepare(firstAuthSession, true); });
        Check(firstAuthSession.NeedsSecurityReapply && !firstAuthSession.CanReapply && !firstAuthSession.PairingReady && !firstAuthSession.Configured);
        string loginRecovery = SunshineSetupPolicy.RecoveryGuidance(firstAuthSession.NeedsSecurityReapply, firstAuthSession.CanReapply);
        Check(loginRecovery.Contains("연결 준비를 다시 시도") && loginRecovery.Contains("자동으로 재사용") && !loginRecovery.Contains("보안 설정 다시 적용 · 재시작"));
        Reject(delegate { firstAuthSession.ReapplySecurityAsync(System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
        Check(firstAuthFailure.Paths.Count == 3);
        var passwordFailure = new Fake(new SunshineApiReply(307, "", "/welcome"), new SunshineApiReply(500, "{}"),
            new SunshineApiReply(307, "", "/welcome"), Reply(Success), Reply(SecureConfig), Reply("{}"), Reply(SecureConfig));
        var passwordSession = Session(passwordFailure); Reject(delegate { Prepare(passwordSession, true); });
        Check(passwordSession.NeedsSecurityReapply && !passwordSession.CanReapply && !passwordSession.PairingReady && passwordFailure.Paths.Count == 2);
        Check(SunshineSetupPolicy.RecoveryGuidance(passwordSession.NeedsSecurityReapply, passwordSession.CanReapply).Contains("계정 생성 또는 로그인 확인"));
        Prepare(passwordSession, true);
        Check(passwordSession.Configured && passwordSession.PairingReady && !passwordSession.NeedsSecurityReapply && passwordFailure.Paths.Count == 7);
        Check(passwordFailure.Paths[1] == "/api/password" && passwordFailure.Paths[3] == "/api/password" && passwordFailure.Paths[5] == "/api/restart");
        // List loading is a separate result. Its failure preserves completed
        // preparation, reports trust errors explicitly and never selects a peer.
        partialRestart.Replies.Enqueue(null);
        SunshinePendingLoad load = partialSession.LoadPendingAsync(System.Threading.CancellationToken.None).GetAwaiter().GetResult();
        Check(!load.Succeeded && load.Items.Count == 0 && partialSession.PairingReady && partialSession.Configured);
        Check(load.Failure.Contains(SunshineSetupPolicy.RefreshPendingLabel) && SunshineSetupPolicy.PendingStatus(partialSession.Configured, load.Failure).StartsWith(SunshineSetupPolicy.ReadyMessage(true), System.StringComparison.Ordinal));
        var listTrust = new Fake(new SunshineApiReply(401, ""), Reply(SecureConfig), new SunshineApiReply(401, "{}"), Reply(Pairs));
        var listSession = Session(listTrust); Prepare(listSession);
        load = listSession.LoadPendingAsync(System.Threading.CancellationToken.None).GetAwaiter().GetResult();
        Check(!load.Succeeded && load.Items.Count == 0 && listSession.PairingReady && !listSession.Configured && !listTrust.Captured);
        Check(load.Failure.Contains("보안 확인에 실패") && load.Failure.Contains("검증을 생략하지 않습니다"));
        load = listSession.LoadPendingAsync(System.Threading.CancellationToken.None).GetAwaiter().GetResult();
        Check(load.Succeeded && load.Items.Count == 1 && listSession.PairingReady && !listTrust.Paths.Contains("/api/restart"));
        var notReady = Session(new Fake()); Reject(delegate { notReady.LoadPendingAsync(System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
        foreach (int code in new int[] { 400, 401, 403, 500 })
        {
            var rejectedRestart = new Fake(new SunshineApiReply(401, ""), Reply(SecureConfig), Reply(SecureConfig), new SunshineApiReply(code, "{}"), Reply(SecureConfig));
            var rejectedSession = Session(rejectedRestart); Reject(delegate { PrepareForced(rejectedSession); });
            Check(!rejectedSession.Configured && !rejectedSession.PairingReady && rejectedRestart.Paths.Count == 4 && !rejectedRestart.Witness.Waited && rejectedRestart.Witness.Disposed);
        }
        var liveOld = new Fake(new SunshineApiReply(401, ""), Reply(SecureConfig), Reply(SecureConfig), Reply("{}"), Reply(SecureConfig)); liveOld.Witness.Exited = false;
        var liveSession = Session(liveOld); Reject(delegate { PrepareForced(liveSession); });
        Check(!liveSession.Configured && liveOld.Paths.Count == 4 && !liveOld.Witness.Verified && liveOld.Witness.Disposed);
        var socketClosed = new Fake(new SunshineApiReply(401, ""), Reply(SecureConfig), Reply(SecureConfig), null, Reply(SecureConfig));
        var socketSession = Session(socketClosed); PrepareForced(socketSession);
        Check(socketSession.Configured && socketClosed.Witness.Verified && socketClosed.Witness.Disposed);
        var changedImage = new Fake(new SunshineApiReply(401, ""), Reply(SecureConfig), Reply(SecureConfig), Reply("{}"), Reply(SecureConfig)); changedImage.Witness.Replacement = false;
        var imageSession = Session(changedImage); Reject(delegate { PrepareForced(imageSession); });
        Check(!imageSession.Configured && changedImage.Witness.Disposed);
        using (var cancel = new System.Threading.CancellationTokenSource())
        {
            var interrupted = new Fake(new SunshineApiReply(401, ""), Reply(SecureConfig), Reply(SecureConfig), Reply("{}"), Reply(SecureConfig)); interrupted.Witness.CancelOnWait = cancel;
            var interruptedSession = Session(interrupted); bool canceled = false;
            Prepare(interruptedSession);
            try { interruptedSession.ReapplySecurityAsync(cancel.Token).GetAwaiter().GetResult(); }
            catch (System.OperationCanceledException) { canceled = true; }
            Check(canceled && !interruptedSession.Configured && interrupted.Paths.Count == 4 && interrupted.Witness.Disposed);
        }
        var expires = new Fake(new SunshineApiReply(401, ""), Reply(SecureConfig), Reply(SecureConfig), Reply("{}"), Reply(SecureConfig)); expires.Witness.Block = true;
        var expireSession = new SunshineSetupSession(expires, delegate(int ignored, System.Threading.CancellationToken token) { return System.Threading.Tasks.Task.FromResult(0); }, 10);
        bool expired = false;
        try { PrepareForced(expireSession); } catch (SunshineSetupFailure) { expired = true; }
        Check(expired && !expireSession.Configured && expires.Paths.Count == 4 && expires.Witness.Disposed);
        var readExpires = new Fake(new SunshineApiReply(401, ""), Reply(SecureConfig), Reply(SecureConfig), Reply("{}")); readExpires.BlockReadback = true;
        var readExpireSession = new SunshineSetupSession(readExpires, delegate(int ignored, System.Threading.CancellationToken token) { return System.Threading.Tasks.Task.FromResult(0); }, 10);
        bool readExpired = false;
        try { PrepareForced(readExpireSession); } catch (SunshineSetupFailure) { readExpired = true; }
        Check(readExpired && !readExpireSession.Configured && readExpires.Paths.Count == 5 && !readExpires.Witness.Verified && readExpires.Witness.Disposed);
        var changed = new Fake(new SunshineApiReply(401, ""), Reply(BasicConfig), Reply(BasicConfig.Replace("80000", "70000")));
        Reject(delegate { Prepare(Session(changed)); }); Check(changed.Paths.Count == 3);
        var saveFailed = new Fake(new SunshineApiReply(401, ""), Reply(BasicConfig), Reply(BasicConfig), Reply("{\"status\":false}"));
        Reject(delegate { Prepare(Session(saveFailed)); }); Check(!saveFailed.Paths.Contains("/api/restart"));
        var badReadback = new Fake(new SunshineApiReply(401, ""), Reply(BasicConfig), Reply(BasicConfig), Reply(Success), Reply(BasicConfig));
        Reject(delegate { Prepare(Session(badReadback)); }); Check(!badReadback.Paths.Contains("/api/restart"));
        return "{\"status\":\"passed\",\"checks\":" + count.ToString(System.Globalization.CultureInfo.InvariantCulture) + ",\"freshSyntheticOnly\":true,\"nativeApisInvoked\":false,\"syntheticWindowsAclProjection\":" + (windowsAclChecks > 0 ? "true" : "false") + ",\"syntheticWindowsAclChecks\":" + windowsAclChecks.ToString(System.Globalization.CultureInfo.InvariantCulture) + "}";
    }
}
