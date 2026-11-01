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
        internal Action<string> StatusChanged;
        internal Action<string> ApprovalRequested;
        internal Action Finished;
        internal int Port { get { return port; } }
        internal string Pin { get { return certificate.Pin; } }
        internal string OwnedKeyContainerName { get { return certificate.OwnedKeyContainerName; } }
        internal bool IsActive { get { lock (gate) return active; } }
        internal HostServer(IPAddress address, int port, IMediaFactory mediaFactory, IInputSink inputSink, bool syntheticLoopback, Invitation invitation)
        {
            if (!NativeProtocol.IsPrivate(address) && !(syntheticLoopback && IPAddress.IsLoopback(address))) throw new ArgumentException("Choose a private IPv4 or Tailscale address.");
            if (port < 0 || port > 65535 || port == 0 && !syntheticLoopback) throw new ArgumentException("Invalid listener port.");
            this.address = address; this.syntheticLoopback = syntheticLoopback;
            this.mediaFactory = mediaFactory; this.inputSink = inputSink;
            this.invitation = invitation ?? new Invitation();
            certificate = new RunCertificate();
            listener = new TcpListener(address, port);
            try { listener.Start(1); }
            catch { certificate.Dispose(); throw; }
            this.port = ((IPEndPoint)listener.LocalEndpoint).Port;
            worker = new Thread(Run); worker.IsBackground = true; worker.Name = "Knot native media writer";
            worker.SetApartmentState(ApartmentState.MTA);
        }
        internal void Start() { worker.Start(); }
        internal string GetInvitation()
        {
            lock (gate)
            {
                if (isStopped || isClaimed) throw new ProtocolException("expired");
                return invitation.Encode(address, Port, certificate.Pin);
            }
        }
        internal void RespondToApproval(bool allow)
        {
            lock (gate)
            {
                if (isStopped || !isClaimed || approval.WaitOne(0)) return;
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
                Notify("Invitation ready. Expires in 120 seconds. Waiting for a viewer.");
                while (!Stopping)
                {
                    if (invitation.IsExpired) throw new ProtocolException("expired");
                    if (!listener.Pending()) { if (stopped.WaitOne(50)) return; continue; }
                    TcpClient accepted = listener.AcceptTcpClient();
                    IPAddress remote = ((IPEndPoint)accepted.Client.RemoteEndPoint).Address;
                    if (!NativeProtocol.IsPrivate(remote) && !(syntheticLoopback && IPAddress.IsLoopback(remote))) { accepted.Close(); continue; }
                    lock (gate)
                    {
                        if (isStopped) { accepted.Close(); return; }
                        client = accepted;
                    }
                    accepted.NoDelay = true;
                    accepted.ReceiveTimeout = 10000; accepted.SendTimeout = 10000;
                    accepted.ReceiveBufferSize = 16384; accepted.SendBufferSize = 262144;
                    SslStream tls = new SslStream(accepted.GetStream(), false);
                    lock (gate) { if (isStopped) { tls.Dispose(); return; } stream = tls; }
                    // This timer covers the entire TLS+hello exchange, including trickled bytes.
                    using (Timer budget = new Timer(delegate { try { accepted.Close(); } catch { } }, null, 10000, Timeout.Infinite))
                    {
                        tls.ReadTimeout = 10000; tls.WriteTimeout = 10000;
                        tls.AuthenticateAsServer(certificate.Certificate, false, SslProtocols.Tls12, false);
                        Packet hello = NativeProtocol.ReadClient(tls, true);
                        byte[] candidate;
                        peerName = NativeProtocol.HelloName(hello.Payload, out candidate);
                        try { invitation.Claim(candidate); }
                        finally { Array.Clear(candidate, 0, candidate.Length); }
                        lock (gate) { if (isStopped) return; isClaimed = true; }
                    }
                    // A claim consumes this run's invitation even if approval is denied.
                    listener.Stop();
                    Notify("Viewer is waiting for your approval. No capture or input has started.");
                    Action<string> request = ApprovalRequested;
                    if (request != null) request(peerName);
                    if (WaitHandle.WaitAny(new WaitHandle[] { approval, stopped }, 60000) != 0) throw new ProtocolException(Stopping ? "closed" : "timeout");
                    lock (gate) { if (isStopped) return; if (!approved) throw new ProtocolException("declined"); }
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
                    Notify("Sharing with " + peerName + ". Stop revokes this temporary session.");
                    Interlocked.Exchange(ref lastRead, Stopwatch.GetTimestamp());
                    watchdog = new Timer(delegate
                    {
                        if (Stopwatch.GetTimestamp() - Interlocked.Read(ref lastRead) >= 10L * Stopwatch.Frequency) Stop();
                    }, null, 250, 250);
                    reader = new Thread(ReadInput); reader.IsBackground = true; reader.Name = "Knot native input reader"; reader.Start();
                    byte[] encoded = new byte[NativeProtocol.VideoLimit - 17];
                    ulong sequence = 0;
                    long lastHeartbeat = Stopwatch.GetTimestamp();
                    while (!Stopping)
                    {
                        uint written, flags;
                        ulong timestamp;
                        int status = media.Read(encoded, out written, out flags, out timestamp);
                        if (Stopping) return;
                        if (status < 0) throw new ProtocolException(status == -3 ? "encoder" : "capture");
                        if (status == 0)
                        {
                            if (written == 0 || written > encoded.Length || sequence == ulong.MaxValue) throw new ProtocolException("encoder");
                            AnnexB.Validate(encoded, (int)written, flags);
                            byte[] payload = new byte[(int)written + 17];
                            NativeProtocol.Put64(payload, 0, ++sequence); NativeProtocol.Put64(payload, 8, timestamp); payload[16] = (byte)flags;
                            Buffer.BlockCopy(encoded, 0, payload, 17, (int)written);
                            NativeProtocol.Write(tls, 3, payload);
                        }
                        else if (status != 1) throw new ProtocolException("capture");
                        if (Stopwatch.GetTimestamp() - lastHeartbeat >= 2L * Stopwatch.Frequency)
                        {
                            NativeProtocol.Write(tls, 4, new byte[0]); lastHeartbeat = Stopwatch.GetTimestamp();
                        }
                    }
                }
            }
            catch (ProtocolException error) { SendError(error.Code); Notify(Guidance(error.Code)); }
            catch (AuthenticationException) { Notify("TLS authentication failed. Create a new invitation."); }
            catch (IOException) { Notify("Connection ended. Create a new invitation."); }
            catch (SocketException) { if (!Stopping) Notify("Connection ended. Create a new invitation."); }
            catch (ObjectDisposedException) { }
            catch (Exception) { SendError("capture"); Notify("Native preview could not start. Check the bundled media engine and supported SDR display."); }
            finally
            {
                Stop();
                if (watchdog != null) watchdog.Dispose();
                if (reader != null && reader != Thread.CurrentThread) reader.Join(1500);
                try { if (stream != null) stream.Dispose(); } catch { }
                try { if (media != null) media.Dispose(); }
                finally
                {
                    certificate.Dispose();
                    workerDone.Set();
                    Action finished = Finished; if (finished != null) finished();
                }
            }
        }
        private void ReadInput()
        {
            System.Collections.Generic.Queue<long> arrivals = new System.Collections.Generic.Queue<long>();
            try
            {
                while (!Stopping)
                {
                    Packet packet = NativeProtocol.ReadClient(stream, false);
                    long now = Stopwatch.GetTimestamp();
                    while (arrivals.Count > 0 && now - arrivals.Peek() >= Stopwatch.Frequency) arrivals.Dequeue();
                    if (arrivals.Count >= 500) throw new ProtocolException("input");
                    arrivals.Enqueue(now);
                    Interlocked.Exchange(ref lastRead, now);
                    input.Accept(packet);
                }
            }
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
                case "declined": return "Viewer declined. Click Share for a fresh invitation.";
                case "encoder": return "A supported hardware H.264 encoder is required. No software fallback is used.";
                case "capture": return "Capture unavailable. Use a logged-in, unlocked primary SDR display without rotation or HDR.";
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
                ownedInput = input; ownedClient = client;
            }
            try { listener.Stop(); } catch { }
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
            { certificate.Dispose(); workerDone.Set(); ended = true; }
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
