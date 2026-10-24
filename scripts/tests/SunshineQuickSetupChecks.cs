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
    private sealed class Fake : ISunshineSetupApi
    {
        internal readonly System.Collections.Generic.Queue<SunshineApiReply> Replies = new System.Collections.Generic.Queue<SunshineApiReply>();
        internal readonly System.Collections.Generic.List<string> Paths = new System.Collections.Generic.List<string>();
        internal readonly System.Collections.Generic.List<string> Bodies = new System.Collections.Generic.List<string>();
        internal readonly System.Collections.Generic.List<string> Auth = new System.Collections.Generic.List<string>();
        internal Fake(params SunshineApiReply[] replies) { foreach (var reply in replies) Replies.Enqueue(reply); }
        public System.Threading.Tasks.Task<SunshineApiReply> SendAsync(string path, string body, string auth, System.Threading.CancellationToken cancel)
        { cancel.ThrowIfCancellationRequested(); Paths.Add(path); Bodies.Add(body); Auth.Add(auth); return System.Threading.Tasks.Task.FromResult(Replies.Dequeue()); }
    }
    private static SunshineSetupSession Session(Fake fake)
    { return new SunshineSetupSession(fake, delegate(int ignored, System.Threading.CancellationToken cancel) { cancel.ThrowIfCancellationRequested(); return System.Threading.Tasks.Task.FromResult(0); }); }
    private static void Prepare(SunshineSetupSession session, bool first = false)
    { session.PrepareAsync("fixture", "synthetic-password-1234", first, System.Threading.CancellationToken.None).GetAwaiter().GetResult(); }
    public static void Main() { System.Console.WriteLine(Run()); }
    public static string Run()
    {
        count = 0;
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
        var falsePair = new Fake(new SunshineApiReply(401, ""), Reply(SecureConfig), Reply("{}"), Reply(SecureConfig));
        var falseSession = Session(falsePair); Prepare(falseSession); falsePair.Replies.Enqueue(Reply(Pairs)); falsePair.Replies.Enqueue(Reply("{\"status\":false}"));
        Reject(delegate { falseSession.PairAsync(pairs[0], "1234", System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
        var invalidPin = new Fake();
        Reject(delegate { Session(invalidPin).PairAsync(pairs[0], "1234", System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
        Check(invalidPin.Paths.Count == 0);
        var changed = new Fake(new SunshineApiReply(401, ""), Reply(BasicConfig), Reply(BasicConfig.Replace("80000", "70000")));
        Reject(delegate { Prepare(Session(changed)); }); Check(changed.Paths.Count == 3);
        var saveFailed = new Fake(new SunshineApiReply(401, ""), Reply(BasicConfig), Reply(BasicConfig), Reply("{\"status\":false}"));
        Reject(delegate { Prepare(Session(saveFailed)); }); Check(!saveFailed.Paths.Contains("/api/restart"));
        var badReadback = new Fake(new SunshineApiReply(401, ""), Reply(BasicConfig), Reply(BasicConfig), Reply(Success), Reply(BasicConfig));
        Reject(delegate { Prepare(Session(badReadback)); }); Check(!badReadback.Paths.Contains("/api/restart"));
        return "{\"status\":\"passed\",\"checks\":" + count.ToString(System.Globalization.CultureInfo.InvariantCulture) + ",\"freshSyntheticOnly\":true,\"nativeApisInvoked\":false}";
    }
}
