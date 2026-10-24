// SPDX-License-Identifier: GPL-3.0-only
// Fresh inert protocol fixtures only. No HTTP implementation, Forms, files or host APIs.
public static class SunshineQuickSetupChecks
{
    private static int count;
    private static void Check(bool value) { if (!value) throw new System.Exception("Quick setup fixture failed."); count++; }
    private static void Reject(System.Action action)
    { bool rejected = false; try { action(); } catch (SunshineSetupFailure) { rejected = true; } Check(rejected); }
    private static SunshineApiReply Reply(string body) { return new SunshineApiReply(200, body); }
    private const string Success = "{\"status\":true}";
    private const string BasicConfig = "{\"status\":true,\"platform\":\"windows\",\"version\":\"2026.914.233613\",\"encoder\":\"nvenc\",\"bitrate\":\"80000\"}";
    private const string SecureConfig = "{\"status\":true,\"platform\":\"windows\",\"version\":\"2026.914.233613\",\"encoder\":\"nvenc\",\"bitrate\":\"80000\",\"lan_encryption_mode\":\"2\",\"wan_encryption_mode\":\"2\",\"upnp\":\"disabled\",\"origin_web_ui_allowed\":\"pc\"}";
    private const string Pairs = "{\"pairings\":[{\"id\":\"0123456789abcdef0123456789abcdef\",\"name\":\"Synthetic Mac\",\"address\":\"192.168.1.4\"}]}";
    private sealed class Resource : System.IDisposable
    {
        internal int Disposals;
        public void Dispose() { System.Threading.Interlocked.Increment(ref Disposals); }
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
        internal Witness Witness = new Witness(); internal bool Captured, BlockReadback;
        private async System.Threading.Tasks.Task<SunshineApiReply> BlockAsync(System.Threading.CancellationToken cancel)
        { await System.Threading.Tasks.Task.Delay(System.Threading.Timeout.Infinite, cancel); throw new System.Exception("Unreachable fixture path."); }
        internal Fake(params SunshineApiReply[] replies) { foreach (var reply in replies) Replies.Enqueue(reply); }
        public ISunshineRestartWitness CaptureRestart(System.Threading.CancellationToken cancel)
        { cancel.ThrowIfCancellationRequested(); Captured = true; return Witness; }
        public System.Threading.Tasks.Task<SunshineApiReply> SendAsync(string path, string body, string auth, System.Threading.CancellationToken cancel)
        { cancel.ThrowIfCancellationRequested(); Paths.Add(path); Bodies.Add(body); Auth.Add(auth); if (Captured && Witness.Waited && path == "/api/config" && BlockReadback) return BlockAsync(cancel); if (path == "/api/restart") Check(Captured && !Witness.Waited); var reply = Replies.Dequeue(); if (reply == null) throw new System.IO.IOException(); return System.Threading.Tasks.Task.FromResult(reply); }
    }
    private static SunshineSetupSession Session(Fake fake)
    { return new SunshineSetupSession(fake, delegate(int ignored, System.Threading.CancellationToken cancel) { cancel.ThrowIfCancellationRequested(); return System.Threading.Tasks.Task.FromResult(0); }); }
    private static void Prepare(SunshineSetupSession session, bool first = false)
    { session.PrepareAsync("fixture", "synthetic-password-1234", first, System.Threading.CancellationToken.None).GetAwaiter().GetResult(); }
    private static void PrepareForced(SunshineSetupSession session)
    { Prepare(session); if (!session.Configured) session.ReapplySecurityAsync(System.Threading.CancellationToken.None).GetAwaiter().GetResult(); }
    public static void Main() { System.Console.WriteLine(Run()); }
    public static string Run()
    {
        count = 0; CheckDispatch(); CheckOwnedFactory();
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
        return "{\"status\":\"passed\",\"checks\":" + count.ToString(System.Globalization.CultureInfo.InvariantCulture) + ",\"freshSyntheticOnly\":true,\"nativeApisInvoked\":false}";
    }
}
