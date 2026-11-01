using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Threading;

namespace Knot.NativePreview
{
    internal sealed class HostServer : IDisposable
    {
        private readonly object gate = new object();
        private readonly IPAddress address;
        private readonly int port;
        private readonly bool syntheticLoopback;
        private readonly IMediaFactory mediaFactory;
        private readonly IInputSink inputSink;
        private readonly RunCertificate certificate;
        private readonly Invitation invitation;
        private readonly bool enrollmentMode;
        private readonly Func<long> clock;
        private readonly EnrollmentServer enrollment;
        private Invitation enrollmentInvitation;
        private int enrollmentGrantsIssued;
        private string enrollmentName;
        private IPAddress enrollmentPeer;
        private readonly ManualResetEvent approval = new ManualResetEvent(false);
        private readonly ManualResetEvent stopped = new ManualResetEvent(false);
        private readonly ManualResetEvent workerDone = new ManualResetEvent(false);
        private readonly Thread worker;
        private readonly TcpListener listener;
        private TcpClient client;
        private SslStream stream;
        private InputSession input;
        private bool isStopped, approved, isClaimed, active, handlesDisposed;
        private long lastRead;
        private string peerName;
        private ApprovalMetadata approvalMetadata;
        internal readonly RunIdentity Identity;
        internal Action<string> StatusChanged;
        internal Action<ApprovalMetadata> ApprovalRequested;
        internal Action<ApprovalMetadata> ClaimAccepted;
        internal Action Finished;
        internal int Port { get { return port; } }
        internal string Pin { get { return Identity.Pin; } }
        internal string OwnedKeyContainerName { get { return certificate.OwnedKeyContainerName; } }
        internal bool IsActive { get { lock (gate) return active; } }
        internal bool UsesEnrollment { get { return enrollmentMode; } }
        internal string EnrollmentCode { get { return enrollment == null ? "" : enrollment.Code; } }
        internal int EnrollmentPort { get { return enrollment == null ? 0 : enrollment.Port; } }
        internal int DiscoveryPort { get { return enrollment == null ? 0 : enrollment.DiscoveryPort; } }
        internal int EnrollmentGrantsIssued { get { lock (gate) return enrollmentGrantsIssued; } }
        internal int EnrollmentAttempts { get { return enrollment == null ? 0 : enrollment.Slot.Attempts; } }
        internal bool EnrollmentBusy { get { return enrollment != null && enrollment.Slot.Busy; } }
        internal bool EnrollmentReady { get { lock (gate) return enrollmentMode && !isStopped && enrollmentInvitation != null; } }
        internal HostServer(IPAddress address, int port, IMediaFactory mediaFactory, IInputSink inputSink, bool syntheticLoopback, Invitation invitation)
            : this(address, port, mediaFactory, inputSink, syntheticLoopback, invitation, false, Stopwatch.GetTimestamp, null) { }
        internal HostServer(IPAddress address, int port, IMediaFactory mediaFactory, IInputSink inputSink, bool syntheticLoopback,
                            Invitation invitation, bool enrollmentMode, Func<long> clock, string deviceName)
        {
            if (!NativeProtocol.IsPrivate(address) && !(syntheticLoopback && IPAddress.IsLoopback(address))) throw new ArgumentException("Choose a private IPv4 or Tailscale address.");
            if (port < 0 || port > 65535 || port == 0 && !syntheticLoopback) throw new ArgumentException("Invalid listener port.");
            this.address = address; this.syntheticLoopback = syntheticLoopback;
            this.enrollmentMode = enrollmentMode; this.clock = clock ?? new Func<long>(Stopwatch.GetTimestamp);
            this.mediaFactory = mediaFactory; this.inputSink = inputSink;
            this.invitation = invitation ?? new Invitation(this.clock);
            certificate = new RunCertificate();
            Identity = new RunIdentity(certificate.Pin);
            listener = new TcpListener(address, port);
            try
            {
                listener.Start(1);
                this.port = ((IPEndPoint)listener.LocalEndpoint).Port;
                if (enrollmentMode)
                {
                    string name = deviceName ?? Environment.MachineName;
                    try { EnrollmentProtocol.ValidName(name); } catch (ProtocolException) { name = "Windows PC"; }
                    enrollment = new EnrollmentServer(address, name, syntheticLoopback, this.clock,
                        IssueEnrollmentGrant, delegate { Notify("연결번호가 만료됐거나 사용할 수 없어요. 새 번호로 다시 공유해주세요."); Stop(); }, Notify);
                }
            }
            catch { try { listener.Stop(); } catch { } certificate.Dispose(); throw; }
            worker = new Thread(Run); worker.IsBackground = true; worker.Name = "Knot native media writer";
            worker.SetApartmentState(ApartmentState.MTA);
        }
        internal void Start() { if (enrollment != null) enrollment.Start(); worker.Start(); }
        internal string GetInvitation()
        {
            lock (gate)
            {
                if (enrollmentMode || isStopped || isClaimed) throw new ProtocolException("expired");
                return invitation.Encode(address, Port, Pin);
            }
        }
        private EnrollmentGrant IssueEnrollmentGrant(byte[] slot, string name, IPAddress peer)
        {
            EnrollmentGrant result;
            lock (gate)
            {
                if (!enrollmentMode || isStopped || isClaimed || enrollmentInvitation != null || enrollment == null ||
                    enrollment.Slot.IsConsumed || !enrollment.Slot.Busy || enrollment.Slot.LifetimeRemainingMilliseconds <= 0 ||
                    !NativeProtocol.Equal(slot, enrollment.Slot.Id)) throw new ProtocolException("expired");
                EnrollmentProtocol.ValidName(name);
                if (!(NativeProtocol.IsPrivate(peer) || syntheticLoopback && IPAddress.IsLoopback(peer))) throw new ProtocolException("auth");
                // Consume and mint while Stop is excluded by this run's gate.
                // The caller has already authenticated and validated ClientConfirm.
                enrollment.Slot.Confirm();
                Invitation grant = new Invitation(clock, 30000);
                try
                {
                    string encoded = grant.Encode(address, Port, Pin);
                    byte[] grantId = EnrollmentProtocol.Random(16);
                    int remaining = grant.RemainingMilliseconds;
                    if (remaining < 1) throw new ProtocolException("expired");
                    result = new EnrollmentGrant(slot, grantId, encoded, remaining);
                    // A new capability, never the fallback T1, owns this one pregrant.
                    invitation.Revoke(); enrollmentInvitation = grant; enrollmentName = name; enrollmentPeer = peer;
                    ++enrollmentGrantsIssued;
                }
                catch { grant.Revoke(); throw; }
            }
            Notify("연결번호를 확인했어요. Mac의 화면 연결을 준비하고 있어요.");
            return result;
        }
        private Invitation ClaimInvitation
        { get { lock (gate) return enrollmentMode ? enrollmentInvitation : invitation; } }
        private bool CredentialsExpired
        {
            get
            {
                lock (gate)
                {
                    if (!enrollmentMode) return invitation.IsExpired;
                    return enrollmentInvitation == null ? enrollment.Slot.LifetimeRemainingMilliseconds <= 0 : enrollmentInvitation.IsExpired;
                }
            }
        }
        internal void RespondToApproval(bool allow)
        {
            lock (gate)
            {
                if (enrollmentMode || isStopped || !isClaimed || approval.WaitOne(0)) return;
                approved = allow; approval.Set();
            }
        }
        private bool Stopping { get { lock (gate) return isStopped; } }
        private void Notify(string text) { Action<string> action = StatusChanged; if (action != null) action(text); }
        private void Run()
        {
            Thread reader = null;
            IMediaSource media = null;
            Timer watchdog = null;
            try
            {
                Notify(enrollmentMode ? "Mac에서 이 PC를 선택하고 8자리 연결번호를 입력해주세요. 이 번호로 한 번의 화면·입력 연결을 허용해요." : "Invitation ready. Expires in 120 seconds. Waiting for a viewer.");
                while (!Stopping)
                {
                    if (CredentialsExpired) throw new ProtocolException("expired");
                    if (!listener.Pending()) { if (stopped.WaitOne(50)) return; continue; }
                    TcpClient accepted = listener.AcceptTcpClient();
                    IPAddress remote = ((IPEndPoint)accepted.Client.RemoteEndPoint).Address;
                    if (!NativeProtocol.IsPrivate(remote) && !(syntheticLoopback && IPAddress.IsLoopback(remote))) { accepted.Close(); continue; }
                    if (!TryClaim(accepted, remote)) continue;
                    SslStream tls = stream;
                    // A claim consumes this run's invitation even if approval is denied.
                    listener.Stop();
                    Action<ApprovalMetadata> acceptedClaim = ClaimAccepted;
                    if (acceptedClaim != null) acceptedClaim(approvalMetadata);
                    if (!enrollmentMode)
                    {
                        Notify("Viewer is waiting for your approval. No capture or input has started.");
                        Action<ApprovalMetadata> request = ApprovalRequested;
                        if (request != null) request(approvalMetadata);
                        WaitForApproval(tls);
                    }
                    lock (gate) { if (isStopped) return; if (!approved) throw new ProtocolException("declined"); }
                    NativeProtocol.Write(tls, 4, new byte[0]);
                    Notify("Approved. Initializing the primary SDR display and hardware encoder.");
                    media = mediaFactory.Open(); // create/read/close all stay on this MTA writer.
                    byte[] ready = media.Info.Ready();
                    lock (gate)
                    {
                        if (isStopped) return;
                        input = new InputSession(inputSink, media.Info.Rectangle);
                    }
                    NativeProtocol.Write(tls, 2, ready);
                    lock (gate) { if (isStopped) return; active = true; }
                    Notify("Sharing with claimed viewer label (UNVERIFIED): " + peerName + ". Stop revokes this temporary session.");
                    Interlocked.Exchange(ref lastRead, Stopwatch.GetTimestamp());
                    watchdog = new Timer(delegate
                    {
                        if (Stopwatch.GetTimestamp() - Interlocked.Read(ref lastRead) >= 10L * Stopwatch.Frequency) Stop();
                    }, null, 250, 250);
                    reader = new Thread(ReadInput); reader.IsBackground = true; reader.Name = "Knot native input reader"; reader.Start();
                    byte[] encoded = new byte[NativeProtocol.VideoLimit - 17];
                    // Synchronous writes finish before the next frame overwrites
                    // this bounded buffer's valid prefix.
                    byte[] payload = new byte[NativeProtocol.VideoLimit];
                    ulong sequence = 0;
                    long lastHeartbeat = Stopwatch.GetTimestamp();
                    while (!Stopping)
                    {
                        uint written, flags;
                        ulong timestamp;
                        int status = media.Read(encoded, out written, out flags, out timestamp);
                        if (Stopping) return;
                        if (status < 0) throw NativeMediaErrors.ForStatus(status);
                        if (status == 0)
                        {
                            if (written == 0 || written > encoded.Length || sequence == ulong.MaxValue) throw new ProtocolException("encoder");
                            AnnexB.Validate(encoded, (int)written, flags);
                            NativeProtocol.Put64(payload, 0, ++sequence); NativeProtocol.Put64(payload, 8, timestamp); payload[16] = (byte)flags;
                            Buffer.BlockCopy(encoded, 0, payload, 17, (int)written);
                            NativeProtocol.Write(tls, 3, payload, (int)written + 17);
                        }
                        else if (status != 1) throw new ProtocolException("capture");
                        if (Stopwatch.GetTimestamp() - lastHeartbeat >= 2L * Stopwatch.Frequency)
                        {
                            NativeProtocol.Write(tls, 4, new byte[0]); lastHeartbeat = Stopwatch.GetTimestamp();
                        }
                    }
                }
            }
            catch (ProtocolException error) { if (!Stopping) { SendError(error.Code); Notify(Guidance(error.GuidanceCategory)); } }
            catch (AuthenticationException) { if (!Stopping) Notify("TLS authentication failed. Create a new invitation."); }
            catch (IOException) { if (!Stopping) Notify("Connection ended. Create a new invitation."); }
            catch (SocketException) { if (!Stopping) Notify("Connection ended. Create a new invitation."); }
            catch (ObjectDisposedException) { }
            catch (Exception) { if (!Stopping) { SendError("capture"); Notify("Native preview could not start. Check the bundled media engine and supported SDR display."); } }
            finally
            {
                Stop();
                if (watchdog != null) watchdog.Dispose();
                if (reader != null && reader != Thread.CurrentThread) reader.Join(1500);
                try { if (stream != null) stream.Dispose(); } catch { }
                try { if (media != null) media.Dispose(); }
                finally
                {
                    try { if (enrollment != null) enrollment.Dispose(); }
                    finally
                    {
                        certificate.Dispose();
                        workerDone.Set();
                        Action finished = Finished; if (finished != null) finished();
                    }
                }
            }
        }
        private void WaitForApproval(SslStream tls)
        {
            long deadline = Stopwatch.GetTimestamp() + 60L * Stopwatch.Frequency;
            WaitHandle[] handles = new WaitHandle[] { approval, stopped };
            while (!Stopping)
            {
                long remaining = deadline - Stopwatch.GetTimestamp();
                if (remaining <= 0) throw new ProtocolException("timeout");
                int milliseconds = (int)Math.Max(1, Math.Min(2000, remaining * 1000.0 / Stopwatch.Frequency));
                int signaled = WaitHandle.WaitAny(handles, milliseconds);
                if (signaled == 0) return;
                if (signaled == 1 || Stopping) throw new ProtocolException("closed");
                if (Stopwatch.GetTimestamp() >= deadline) throw new ProtocolException("timeout");
                // The sole writer keeps the authenticated viewer alive throughout the
                // approval window. Capture and input remain uninitialized.
                NativeProtocol.Write(tls, 4, new byte[0]);
            }
            throw new ProtocolException("closed");
        }
        private bool TryClaim(TcpClient accepted, IPAddress observedRemote)
        {
            SslStream tls = null;
            bool claimed = false;
            try
            {
                lock (gate)
                {
                    if (isStopped) return false;
                    client = accepted;
                }
                accepted.NoDelay = true;
                accepted.ReceiveTimeout = 10000; accepted.SendTimeout = 10000;
                accepted.ReceiveBufferSize = 16384; accepted.SendBufferSize = 262144;
                tls = new SslStream(accepted.GetStream(), false);
                lock (gate) { if (isStopped) return false; stream = tls; }
                // Admission policy: one private-source pre-claim connection, no worker
                // fan-out, and min(10 seconds, remaining invitation TTL) for all TLS
                // and hello bytes. Repeated private peers can occupy this bounded
                // window; this is an availability watch, never an approval/trust bypass.
                Invitation claimInvitation = ClaimInvitation;
                if (claimInvitation == null) throw new ProtocolException("auth");
                int milliseconds = Math.Max(1, Math.Min(10000, claimInvitation.RemainingMilliseconds));
                using (Timer budget = new Timer(delegate { try { accepted.Close(); } catch { } }, null, milliseconds, Timeout.Infinite))
                {
                    tls.ReadTimeout = 10000; tls.WriteTimeout = 10000;
                    tls.AuthenticateAsServer(certificate.Certificate, false, SslProtocols.Tls12, false);
                    Packet hello = NativeProtocol.ReadClient(tls, true);
                    byte[] candidate;
                    string name = NativeProtocol.HelloName(hello.Payload, out candidate);
                    try
                    {
                        lock (gate)
                        {
                            if (isStopped || enrollmentMode && (!object.ReferenceEquals(claimInvitation, enrollmentInvitation) ||
                                name != enrollmentName || !observedRemote.Equals(enrollmentPeer))) throw new ProtocolException("auth");
                            claimInvitation.Claim(candidate);
                        }
                    }
                    finally { Array.Clear(candidate, 0, candidate.Length); }
                    lock (gate)
                    {
                        if (isStopped) return false;
                        isClaimed = true; peerName = name; claimed = true;
                        approvalMetadata = new ApprovalMetadata(Identity, name, observedRemote);
                        if (enrollmentMode) { approved = true; approval.Set(); }
                    }
                }
                return true;
            }
            catch (ProtocolException error) { SendError(error.Code); }
            catch (AuthenticationException) { }
            catch (IOException) { }
            catch (SocketException) { }
            catch (ObjectDisposedException) { }
            finally
            {
                if (!claimed)
                {
                    try { if (tls != null) tls.Dispose(); } catch { }
                    try { accepted.Close(); } catch { }
                    lock (gate)
                    {
                        if (client == accepted) client = null;
                        if (stream == tls) stream = null;
                    }
                }
            }
            if (CredentialsExpired) throw new ProtocolException("expired");
            return false;
        }
        private void ReadInput()
        {
            InputRateLimiter rate = new InputRateLimiter();
            try
            {
                while (!Stopping)
                {
                    Packet packet = NativeProtocol.ReadClient(stream, false);
                    long now = Stopwatch.GetTimestamp();
                    if (!rate.TryConsume()) throw new ProtocolException("input", "input-rate");
                    Interlocked.Exchange(ref lastRead, now);
                    input.Accept(packet);
                }
            }
            catch (ProtocolException error) { if (!Stopping) Notify(Guidance(error.GuidanceCategory)); Stop(); }
            catch (Exception) { Stop(); }
        }
        private void SendError(string code)
        {
            // Only the writer owns server->client writes; this method is called there.
            try { if (stream != null && stream.IsAuthenticated && !Stopping) NativeProtocol.Write(stream, 127, NativeProtocol.Error(code)); }
            catch { }
        }
        internal static string Guidance(string code)
        {
            switch (code)
            {
                case "expired": return "Invitation expired. Click Share for a fresh invitation.";
                case "auth": return "Invitation authentication failed. Click Share for a fresh invitation.";
                case "declined": return "Host declined the viewer request. Click Share for a fresh invitation.";
                case "encoder": return "Hardware H.264 encoding is unavailable or failed. Check the graphics driver and encoder availability; then create a fresh invitation.";
                case "display": return "Display unsupported. Use a logged-in, unlocked primary SDR display without rotation or HDR.";
                case "device": return "The graphics device was lost or could not be initialized. Check the display and graphics driver; then create a fresh invitation.";
                case "capture": return "Desktop capture could not continue. Check that the primary desktop is available; then create a fresh invitation.";
                case "input-rate": return "Input rate exceeded the bounded allowance (500 envelopes/second average, burst 1000). Sharing stopped; create a fresh invitation.";
                case "input": return "Remote input could not be applied safely. Sharing stopped; create a fresh invitation.";
                case "timeout": return "Session timed out. Click Share for a fresh invitation.";
                default: return "Session stopped. Click Share for a fresh invitation.";
            }
        }
        internal void Stop()
        {
            InputSession ownedInput;
            TcpClient ownedClient;
            lock (gate)
            {
                if (isStopped) return;
                isStopped = true; active = false;
                invitation.Revoke(); stopped.Set(); approval.Set();
                if (enrollmentInvitation != null) enrollmentInvitation.Revoke();
                ownedInput = input; ownedClient = client;
            }
            try { listener.Stop(); } catch { }
            if (enrollment != null) enrollment.Stop();
            // Closing the socket interrupts TLS reads/writes and their bounded budgets.
            try { if (ownedClient != null) ownedClient.Close(); } catch { }
            if (ownedInput != null) ownedInput.Close();
        }
        internal bool WaitStopped(int milliseconds) { return workerDone.WaitOne(milliseconds); }
        public void Dispose()
        {
            Stop();
            bool ended;
            if (worker.ThreadState == System.Threading.ThreadState.Unstarted || (worker.ThreadState & System.Threading.ThreadState.Unstarted) != 0)
            { if (enrollment != null) enrollment.Dispose(); certificate.Dispose(); workerDone.Set(); ended = true; }
            else ended = worker != Thread.CurrentThread && worker.Join(2000);
            if (ended)
            {
                lock (gate)
                {
                    if (handlesDisposed) return;
                    handlesDisposed = true;
                    approval.Dispose(); stopped.Dispose(); workerDone.Dispose();
                }
            }
        }
    }
}
