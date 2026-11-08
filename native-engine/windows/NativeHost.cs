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
    internal enum HostEnrollmentState { None, Number, Pending, RegisteredWaiting, Stopped }

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
        private readonly Func<long> inputClock;
        private readonly EnrollmentServer enrollment;
        private readonly FileSharingOptions fileOptions;
        private FileServer files;
        private readonly bool audioAllowed;
        private readonly IAudioCaptureFactory audioFactory;
        private NativeAudioServer audio;
        private byte[] sessionAudioKey;
        internal Action<string> AudioStatusChanged;
        private TrustedDeviceServer trustedServer;
        private readonly INativeTrustedDeviceStore trustedDevices;
        private readonly IClipboardText syntheticClipboard;
        private long trustedRefreshAt, trustedRevision;
        private bool trustedRevocationPending, enrollmentUnavailable;
        internal int TrustedPort { get { return trustedServer == null ? 0 : trustedServer.ListeningPort; } }
        // UI receives one gate-owned state rather than inferring readiness
        // from the absence of a grant (which is also true after Stop).
        internal HostEnrollmentState EnrollmentState
        {
            get
            {
                lock (gate)
                {
                    if (!enrollmentMode) return HostEnrollmentState.None;
                    if (isStopped) return HostEnrollmentState.Stopped;
                    if (isClaimed || enrollmentInvitation != null) return HostEnrollmentState.Pending;
                    if (NumberCanProgress) return HostEnrollmentState.Number;
                    return registeredAvailable ? HostEnrollmentState.RegisteredWaiting : HostEnrollmentState.Stopped;
                }
            }
        }
        internal bool WaitingForRegisteredDevice { get { return EnrollmentState == HostEnrollmentState.RegisteredWaiting; } }
        // Called only under the host gate. A fifth in-flight PAKE may finish;
        // an ended listener, consumed slot or expired number cannot progress.
        private bool NumberCanProgress
        { get { return !enrollmentUnavailable && enrollment != null && enrollment.Slot.LifetimeRemainingMilliseconds > 0 &&
            (enrollment.Slot.Available || enrollment.Slot.Busy); } }
        private byte[] registrationHash;
        private long registrationDeadline;
        private bool registrationUsed, registeredSession, registeredAvailable;
        private ClipboardBridge clipboard;
        private NativeQualityController quality;
        internal bool IsRegisteredSession { get { lock (gate) return registeredSession; } }
        internal bool HasRegisteredDevices { get { lock (gate) return registeredAvailable; } }
        private bool mayResumeRegisteredConnection, terminalFailure;
        internal bool MayResumeRegisteredConnection { get { lock (gate) return mayResumeRegisteredConnection; } }
        private bool enrollmentAllowsFiles, claimedFiles;
        private IPAddress claimedPeer;
        private Invitation enrollmentInvitation;
        private int enrollmentGrantsIssued;
        private string enrollmentName;
        private IPAddress enrollmentPeer;
        private readonly ManualResetEvent approval;
        private readonly ManualResetEvent stopped;
        private readonly ManualResetEvent workerDone;
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
        internal Action<string> FileStatusChanged;
        internal int Port { get { return port; } }
        internal int AudioPort { get { lock (gate) return isStopped || !active || audio == null ? 0 : audio.Port; } }
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
                            Invitation invitation, bool enrollmentMode, Func<long> clock, string deviceName, Func<long> inputClock = null,
                            FileSharingOptions files = null, Action<int, int, int> syntheticAfterEnrollment = null,
                            bool allowAudio = false, IAudioCaptureFactory audioFactory = null, bool syntheticRegisteredDevices = false,
                            INativeTrustedDeviceStore syntheticTrustedDevices = null, IClipboardText syntheticClipboard = null)
        {
            if (!NativeProtocol.IsPrivate(address) && !(syntheticLoopback && IPAddress.IsLoopback(address))) throw new ArgumentException("Choose a private IPv4 or Tailscale address.");
            if (port < 0 || port > 65535 || port == 0 && !syntheticLoopback) throw new ArgumentException("Invalid listener port.");
            if (syntheticAfterEnrollment != null && (!syntheticLoopback || !enrollmentMode))
                throw new ArgumentException("Construction fault injection requires an owned synthetic enrollment fixture.");
            if (syntheticRegisteredDevices && (!syntheticLoopback || !enrollmentMode))
                throw new ArgumentException("Synthetic registered state requires an owned synthetic enrollment fixture.");
            if ((syntheticTrustedDevices != null && (!syntheticLoopback || !enrollmentMode || !IPAddress.IsLoopback(address))) ||
                (syntheticClipboard != null && (!syntheticLoopback || !IPAddress.IsLoopback(address))))
                throw new ArgumentException("Synthetic child adapters require owned loopback fixtures.");
            trustedDevices = syntheticLoopback ? syntheticTrustedDevices : NativeTrustedDevices.Production;
            this.syntheticClipboard = syntheticClipboard;
            this.address = address; this.syntheticLoopback = syntheticLoopback;
            this.enrollmentMode = enrollmentMode; this.clock = clock ?? new Func<long>(Stopwatch.GetTimestamp);
            this.inputClock = inputClock ?? new Func<long>(Stopwatch.GetTimestamp);
            fileOptions = files;
            audioAllowed = allowAudio; this.audioFactory = audioFactory ?? new WindowsAudioCaptureFactory();
            this.mediaFactory = mediaFactory; this.inputSink = inputSink;
            try
            {
                approval = new ManualResetEvent(false); stopped = new ManualResetEvent(false); workerDone = new ManualResetEvent(false);
                this.invitation = invitation ?? new Invitation(this.clock);
                certificate = enrollmentMode && !syntheticLoopback ? RunCertificate.Persistent() : new RunCertificate();
                Identity = new RunIdentity(certificate.Pin);
                registeredAvailable = trustedDevices != null ? enrollmentMode && trustedDevices.HasDevices : syntheticRegisteredDevices;
                trustedRefreshAt = this.clock();
                listener = new TcpListener(address, port);
                listener.Start(1);
                this.port = ((IPEndPoint)listener.LocalEndpoint).Port;
                if (enrollmentMode)
                {
                    string name = deviceName ?? Environment.MachineName;
                    try { EnrollmentProtocol.ValidName(name); } catch (ProtocolException) { name = "Windows PC"; }
                    enrollment = new EnrollmentServer(address, name, syntheticLoopback, this.clock,
                        IssueEnrollmentGrant, delegate(EnrollmentFailure failure) {
                            lock (gate) enrollmentUnavailable = true;
                            bool registeredWaiting = trustedServer != null && HasRegisteredDevices;
                            Notify(registeredWaiting && failure == EnrollmentFailure.Unavailable ? EnrollmentGuidance.RegisteredWaiting : EnrollmentGuidance.For(failure));
                            if (!registeredWaiting) Stop();
                        }, Notify,
                        issueWithFiles: IssueEnrollmentGrantWithFiles);
                    if (syntheticAfterEnrollment != null) syntheticAfterEnrollment(this.port, enrollment.Port, enrollment.DiscoveryPort);
                    if (trustedDevices != null)
                        trustedServer = new TrustedDeviceServer(address, certificate.Certificate, Pin, RegisterDevice, IssueTrustedGrant, delegate { return !Stopping; },
                            syntheticLoopback: syntheticLoopback, port: syntheticLoopback ? 0 : TrustedDeviceServer.Port,
                            lookupKey: trustedDevices.Key, revoke: RevokeRegisteredDevice, revokeFinished: FinishRegisteredRevocation);
                }
                worker = new Thread(Run); worker.IsBackground = true; worker.Name = "Knot native media writer";
                worker.SetApartmentState(ApartmentState.MTA);
            }
            catch
            {
                // Construction owns every resource until this transaction commits.
                // In particular, enrollment has already bound TCP/UDP before the
                // trusted listener is attempted. Teardown must not wait for GC or
                // mask the original failure if one independent cleanup fails.
                try { if (trustedServer != null) trustedServer.Dispose(); } catch { }
                try { if (enrollment != null) enrollment.Dispose(); } catch { }
                try { if (listener != null) listener.Stop(); } catch { }
                try { if (certificate != null) certificate.Dispose(); } catch { }
                try { if (this.invitation != null) this.invitation.Revoke(); } catch { }
                try { if (workerDone != null) workerDone.Dispose(); } catch { }
                try { if (stopped != null) stopped.Dispose(); } catch { }
                try { if (approval != null) approval.Dispose(); } catch { }
                throw;
            }
        }
        internal void Start() { if (enrollment != null) enrollment.Start(); if (trustedServer != null) trustedServer.Start(); worker.Start(); }
        internal string GetInvitation()
        {
            lock (gate)
            {
                if (enrollmentMode || isStopped || isClaimed) throw new ProtocolException("expired");
                return invitation.Encode(address, Port, Pin);
            }
        }
        private bool RegisterDevice(IPAddress peer, string token, string id, string name, string key)
        {
            byte[] candidate = NativeProtocol.DecodeToken(token), digest;
            try { using (System.Security.Cryptography.SHA256 sha = System.Security.Cryptography.SHA256.Create()) digest = sha.ComputeHash(candidate); }
            finally { Array.Clear(candidate, 0, candidate.Length); }
            lock (gate)
            {
                if (isStopped || !active || !enrollmentMode || registrationUsed || registrationHash == null ||
                    !peer.Equals(claimedPeer) || registrationDeadline == 0 || clock() > registrationDeadline || !NativeProtocol.Equal(digest, registrationHash) || registeredSession) return false;
                if (trustedDevices == null) return false;
                trustedDevices.Add(id, name, key); registrationUsed = true; registeredAvailable = true; ++trustedRevision;
                Array.Clear(registrationHash, 0, registrationHash.Length); registrationHash = null;
                return true;
            }
        }
        private void RevokeRegisteredDevice(string id)
        {
            // Do not keep an expired-number listener alive on a stale cached
            // record after the authenticated last-device revocation.
            lock (gate) { trustedRevocationPending = true; ++trustedRevision; }
            trustedDevices.Revoke(id);
        }
        private void FinishRegisteredRevocation()
        {
            try
            {
                for (int attempt = 0; attempt < 2; ++attempt)
                {
                    long revision; lock (gate) revision = trustedRevision;
                    bool any = trustedDevices.HasDevices;
                    lock (gate)
                    {
                        if (revision != trustedRevision) continue;
                        registeredAvailable = any; trustedRefreshAt = clock(); ++trustedRevision;
                        // Last-key removal also retires an outstanding trusted
                        // grant. A number-derived grant and an already-claimed
                        // session have separate authority and remain unchanged.
                        if (!any && !isClaimed && registeredSession && enrollmentInvitation != null)
                        {
                            enrollmentInvitation.Revoke(); enrollmentInvitation = null;
                            registeredSession = false; enrollmentName = null; enrollmentPeer = null;
                            enrollmentAllowsFiles = false;
                        }
                        break;
                    }
                }
            }
            finally { lock (gate) trustedRevocationPending = false; }
        }
        private string IssueTrustedGrant(IPAddress peer, string name)
        {
            lock (gate)
            {
                if (isStopped || isClaimed || !enrollmentMode || !(NativeProtocol.IsPrivate(peer) || syntheticLoopback && IPAddress.IsLoopback(peer))) throw new ProtocolException("busy");
                EnrollmentProtocol.ValidName(name);
                if (enrollmentInvitation != null && !enrollmentInvitation.IsExpired) throw new ProtocolException("busy");
                if (enrollmentInvitation != null) enrollmentInvitation.Revoke();
                enrollmentInvitation = new Invitation(clock, 30000); enrollmentName = name; enrollmentPeer = peer;
                enrollmentAllowsFiles = fileOptions != null; registeredSession = true; invitation.Revoke();
                return enrollmentInvitation.Encode(address, Port, Pin);
            }
        }
        private EnrollmentGrant IssueEnrollmentGrant(byte[] slot, string name, IPAddress peer)
        { return IssueEnrollmentGrantWithFiles(slot, name, peer, false); }
        private EnrollmentGrant IssueEnrollmentGrantWithFiles(byte[] slot, string name, IPAddress peer, bool wantsFiles)
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
                    registrationHash = grant.RegistrationHash; registrationUsed = false; registeredSession = false;
                    enrollmentAllowsFiles = wantsFiles && fileOptions != null;
                    ++enrollmentGrantsIssued;
                }
                catch { grant.Revoke(); throw; }
            }
            Notify("연결번호를 확인했어요. Mac의 화면 연결을 준비하고 있어요.");
            return result;
        }
        private Invitation ClaimInvitation
        { get { lock (gate) return enrollmentMode ? enrollmentInvitation : invitation; } }
        private void RefreshTrustedAvailability()
        {
            long revision;
            lock (gate)
            {
                if (!enrollmentMode || trustedDevices == null || isClaimed || isStopped || trustedRevocationPending ||
                    clock() - trustedRefreshAt < Stopwatch.Frequency) return;
                trustedRefreshAt = clock(); revision = trustedRevision;
            }
            // DPAPI/store contention must not hold the session's Stop gate.
            // A failed store read is not a lost media transport. Preserve the
            // fail-closed policy and prevent automatic replacement of this run.
            bool any;
            try { any = trustedDevices.HasDevices; }
            catch { throw new ProtocolException("auth", "trusted-storage"); }
            lock (gate) { if (!isClaimed && !isStopped && !trustedRevocationPending && revision == trustedRevision) registeredAvailable = any; }
        }
        private bool CredentialsExpired
        {
            get
            {
                RefreshTrustedAvailability();
                lock (gate)
                {
                    if (!enrollmentMode) return invitation.IsExpired;
                    // Allow the already-authenticated revocation's bounded ACK
                    // write to finish before expiry closes its exact socket.
                    if (!isClaimed && trustedRevocationPending) return false;
                    if (trustedServer != null && registeredAvailable && !isClaimed)
                    {
                        if (enrollmentInvitation != null && enrollmentInvitation.IsExpired)
                        { enrollmentInvitation.Revoke(); enrollmentInvitation = null; }
                        return false;
                    }
                    return enrollmentInvitation == null ? !NumberCanProgress : enrollmentInvitation.IsExpired;
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
                Notify(enrollmentMode ? EnrollmentGuidance.Ready : "Invitation ready. Expires in 120 seconds. Waiting for a viewer.");
                while (!Stopping)
                {
                    if (CredentialsExpired) throw new ProtocolException("expired");
                    if (!listener.Pending()) { if (stopped.WaitOne(50)) return; continue; }
                    TcpClient accepted = listener.AcceptTcpClient();
                    IPAddress remote = ((IPEndPoint)accepted.Client.RemoteEndPoint).Address;
                    if (!NativeProtocol.IsPrivate(remote) && !(syntheticLoopback && IPAddress.IsLoopback(remote))) { accepted.Close(); continue; }
                    if (!MayAttemptClaim(remote)) { accepted.Close(); continue; }
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
                    if (media is WindowsMediaSource) {
                        quality = new NativeQualityController(media.Info); ready = NativeQualityController.WithOffer(ready);
                    }
                    FileServer preparedFiles = null;
                    if (claimedFiles)
                    {
                        try { preparedFiles = new FileServer(address, claimedPeer, certificate.Certificate, fileOptions, gate, delegate { return active && !isStopped; },
                            captureDrag: CaptureExplorerDrag, cancelDrag: CancelExplorerDrag); }
                        catch (Exception)
                        {
                            Action<string> fileStatus = FileStatusChanged;
                            if (fileStatus != null) fileStatus("파일 공유 폴더를 준비하지 못했어요. 화면 연결은 계속 사용할 수 있어요.");
                        }
                    }
                    lock (gate)
                    {
                        if (isStopped) { if (preparedFiles != null) preparedFiles.Dispose(); return; }
                        input = new InputSession(inputSink, media.Info.Rectangle);
                        input.ExplorerReleaseFailed = delegate { RecordTerminalFailure(); Stop(); };
                        if (inputSink is WindowsInputSink || syntheticClipboard != null)
                        {
                            clipboard = new ClipboardBridge(ApplyClipboardShortcut,
                                delegate { lock (gate) return active && !isStopped; }, syntheticClipboard ?? new WindowsClipboardText());
                            ready = ClipboardProtocol.WithOffer(ready);
                        }
                        files = preparedFiles;
                        // File authorization cannot race delivery of its offer.
                        // A failed Ready write reaches Stop and revokes both.
                        active = true;
                    }
                    if (preparedFiles != null) { preparedFiles.Start(); ready = FileProtocol.WithOffer(ready, preparedFiles.Token, preparedFiles.RootName); }
                    if (audioAllowed && sessionAudioKey != null)
                    {
                        NativeAudioServer preparedAudio = null;
                        try
                        {
                            preparedAudio = new NativeAudioServer(address, claimedPeer, certificate.Certificate, sessionAudioKey,
                                delegate { lock (gate) return active && !isStopped; }, audioFactory,
                                delegate(string message) { Action<string> status = AudioStatusChanged; if (status != null) status(message); }, syntheticLoopback,
                                syntheticLoopback ? 0 : NativeAudioProtocol.Port);
                            bool cancelled;
                            lock (gate) { cancelled = isStopped; if (!cancelled) audio = preparedAudio; }
                            if (cancelled) { preparedAudio.Dispose(); return; }
                            preparedAudio.Start();
                        }
                        catch (Exception)
                        {
                            try { if (preparedAudio != null) preparedAudio.Dispose(); } catch { }
                            lock (gate) { if (audio == preparedAudio) audio = null; }
                            Action<string> status = AudioStatusChanged;
                            try { if (status != null) status("화면 연결은 계속되지만 Windows 재생 소리를 준비하지 못했어요."); } catch { }
                        }
                    }
                    lock (gate)
                    {
                        if (isStopped) return;
                        // Media initialization may legitimately consume the old
                        // claim-time window. Registration begins at Ready.
                        if (registrationHash != null) registrationDeadline = clock() + 30L * Stopwatch.Frequency;
                    }
                    NativeProtocol.Write(tls, 2, ready);
                    lock (gate) { if (isStopped) return; }
                    Notify("Sharing with claimed viewer label (UNVERIFIED): " + peerName + ". Stop revokes this temporary session.");
                    Interlocked.Exchange(ref lastRead, inputClock());
                    watchdog = new Timer(delegate
                    {
                        if (inputClock() - Interlocked.Read(ref lastRead) >= 10L * Stopwatch.Frequency)
                        {
                            NotifyTransportEnded(Guidance("timeout"));
                            Stop();
                        }
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
                        if (quality != null)
                        {
                            quality.Apply(media);
                            byte[] changed = quality.TakeStatus();
                            if (changed != null) NativeProtocol.Write(tls, 0x34, changed);
                        }
                        byte[] clipboardResponse;
                        if (clipboard != null && clipboard.TryTake(out clipboardResponse)) NativeProtocol.Write(tls, 0x31, clipboardResponse);
                        uint written, flags;
                        ulong timestamp;
                        int status = media.Read(encoded, out written, out flags, out timestamp);
                        // An in-flight read can finish after transport teardown.
                        // Preserve a real media failure before honoring Stop so
                        // it cannot be reclassified as resumable transport loss.
                        if (status < 0) throw NativeMediaErrors.ForStatus(status);
                        if (status != 0 && status != 1) throw new ProtocolException("capture");
                        if (status == 0)
                        {
                            if (written == 0 || written > encoded.Length || sequence == ulong.MaxValue) throw new ProtocolException("encoder");
                            AnnexB.Validate(encoded, (int)written, flags);
                        }
                        if (Stopping) return;
                        if (status == 0)
                        {
                            NativeProtocol.Put64(payload, 0, ++sequence); NativeProtocol.Put64(payload, 8, timestamp); payload[16] = (byte)flags;
                            Buffer.BlockCopy(encoded, 0, payload, 17, (int)written);
                            long writeStart = Stopwatch.GetTimestamp();
                            NativeProtocol.Write(tls, 3, payload, (int)written + 17);
                            if (quality != null) quality.ObserveWrite((Stopwatch.GetTimestamp() - writeStart) * 1000.0 / Stopwatch.Frequency);
                        }
                        if (Stopwatch.GetTimestamp() - lastHeartbeat >= 2L * Stopwatch.Frequency)
                        {
                            NativeProtocol.Write(tls, 4, new byte[0]); lastHeartbeat = Stopwatch.GetTimestamp();
                        }
                    }
                }
            }
            catch (ProtocolException error) { RecordTerminalFailure(error.Code); if (!Stopping) { SendError(error.Code); Notify(Guidance(error.GuidanceCategory)); } }
            catch (AuthenticationException) { RecordTerminalFailure(); if (!Stopping) Notify("TLS authentication failed. Create a new invitation."); }
            catch (IOException) { NotifyTransportEnded(); }
            catch (SocketException) { NotifyTransportEnded(); }
            catch (ObjectDisposedException) { }
            catch (Exception) { RecordTerminalFailure(); if (!Stopping) { SendError("capture"); Notify("Native preview could not start. Check the bundled media engine and supported SDR display."); } }
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
                        if (files != null) files.Dispose();
                        if (audio != null) audio.Dispose();
                        if (clipboard != null) clipboard.Dispose();
                        if (trustedServer != null) trustedServer.Dispose();
                        certificate.Dispose();
                        workerDone.Set();
                        Action finished = Finished; if (finished != null) finished();
                    }
                }
            }
        }
        private bool MayAttemptClaim(IPAddress observedRemote)
        {
            lock (gate)
            {
                // Only the source which authenticated enrollment can use its
                // short T2 window. Other private peers receive no TLS work.
                return !isStopped && (!enrollmentMode || enrollmentInvitation != null && observedRemote.Equals(enrollmentPeer));
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
                using (ConnectionDeadline budget = new ConnectionDeadline(milliseconds, accepted.Close))
                {
                    tls.ReadTimeout = 10000; tls.WriteTimeout = 10000;
                    tls.AuthenticateAsServer(certificate.Certificate, false, SslProtocols.Tls12, false);
                    Packet hello = NativeProtocol.ReadClient(tls, true);
                    byte[] candidate;
                    bool wantsFiles;
                    string name = NativeProtocol.HelloName(hello.Payload, out candidate, out wantsFiles);
                    try
                    {
                        lock (gate)
                        {
                            if (isStopped || enrollmentMode && (!object.ReferenceEquals(claimInvitation, enrollmentInvitation) ||
                                name != enrollmentName || !observedRemote.Equals(enrollmentPeer))) throw new ProtocolException("auth");
                            if (!budget.TryComplete()) throw new ProtocolException("timeout");
                            claimInvitation.Claim(candidate);
                            if (audioAllowed) sessionAudioKey = NativeAudioProtocol.DeriveKey(candidate);
                            // Token consumption and scope publication have one
                            // winner against last-key revocation on this gate.
                            isClaimed = true; peerName = name; claimed = true; registrationDeadline = 0;
                            claimedPeer = observedRemote;
                            claimedFiles = fileOptions != null && wantsFiles && (!enrollmentMode || enrollmentAllowsFiles);
                            approvalMetadata = new ApprovalMetadata(Identity, name, observedRemote);
                            if (enrollmentMode) { approved = true; approval.Set(); }
                        }
                    }
                    finally { Array.Clear(candidate, 0, candidate.Length); }
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
        internal void ApplyClipboardShortcut(byte operation)
        {
            bool attempted = false;
            try
            {
                lock (gate)
                {
                    if (!active || isStopped || input == null) throw new ProtocolException("closed");
                    attempted = true;
                    try { input.ClipboardShortcut(operation); }
                    catch
                    {
                        // Publish the failure before releasing the host lock so
                        // concurrent transport EOF cannot finish a resumable run
                        // before this clipboard worker reaches Stop.
                        RecordTerminalFailure("input");
                        throw;
                    }
                }
            }
            catch
            {
                // The optional clipboard worker may catch content/OS access
                // failures, but it must never swallow failed input injection or
                // key release and leave the authoritative input session alive.
                if (attempted)
                {
                    try { if (!Stopping) Notify(Guidance("input")); }
                    finally { Stop(); }
                }
                throw;
            }
        }
        private void ReadInput()
        {
            InputRateLimiter rate = new InputRateLimiter();
            try
            {
                while (!Stopping)
                {
                    Packet packet = NativeProtocol.ReadClient(stream, false);
                    long now = inputClock();
                    if (!rate.TryConsume()) throw new ProtocolException("input", "input-rate");
                    Interlocked.Exchange(ref lastRead, now);
                    if (packet.Kind == 0x30) { if (clipboard == null) throw new ProtocolException("protocol"); clipboard.Handle(packet.Payload); }
                    else if (packet.Kind == 0x32 || packet.Kind == 0x33) { if (quality == null) throw new ProtocolException("protocol"); quality.Handle(packet); }
                    else { if (packet.Kind == 0x24 && clipboard != null) clipboard.Cancel(); input.Accept(packet); }
                }
            }
            catch (ProtocolException error) { RecordTerminalFailure(error.Code); if (!Stopping) Notify(Guidance(error.GuidanceCategory)); Stop(); }
            catch (IOException) { NotifyTransportEnded(); Stop(); }
            catch (SocketException) { NotifyTransportEnded(); Stop(); }
            catch (ObjectDisposedException) { Stop(); }
            catch (Exception) { RecordTerminalFailure(); if (!Stopping) Notify("Session stopped. Check the host before reconnecting."); Stop(); }
        }
        private void RecordTerminalFailure(string code = null)
        {
            lock (gate)
            {
                // Stop may make an already-read input packet observe "closed".
                // Every other terminal failure wins over concurrent socket IO,
                // including IO caused by its own notification/teardown window.
                if (code == "closed" && isStopped) return;
                terminalFailure = true; mayResumeRegisteredConnection = false;
            }
        }
        private void NotifyTransportEnded(string guidance = null)
        {
            bool resume;
            lock (gate)
            {
                if (isStopped || terminalFailure) return;
                // A fresh number claim is temporary even when this host has
                // older saved devices. Keep their listener eligible to resume;
                // the owner must still want sharing and every reconnect must
                // authenticate a fresh trusted-device challenge and pinned TLS.
                resume = mayResumeRegisteredConnection = registeredSession || registrationUsed || registeredAvailable;
            }
            Notify(guidance ?? (resume ? "Connection ended. Waiting to reconnect a registered device." : "Connection ended. Create a new invitation."));
        }
        private string[] CaptureExplorerDrag(string nonce)
        {
            InputSession owned;
            lock (gate)
            {
                if (!active || isStopped || !claimedFiles || files == null || !(inputSink is WindowsInputSink))
                    throw new FileTransferException("denied");
                owned = input;
            }
            if (owned == null) throw new FileTransferException("denied");
            return WindowsDragBridge.Capture(owned.AcquireExplorerDrag(nonce), delegate
            {
                lock (gate) return active && !isStopped && claimedFiles && input == owned;
            });
        }
        private void CancelExplorerDrag(string nonce)
        {
            InputSession owned;
            lock (gate) owned = input;
            if (owned != null) owned.CancelExplorerDrag(nonce);
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
                case "trusted-storage": return "Registered device storage could not be verified. Sharing stopped; check Windows account and storage access before sharing again.";
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
            FileServer ownedFiles;
            NativeAudioServer ownedAudio;
            lock (gate)
            {
                if (isStopped) return;
                isStopped = true; active = false;
                invitation.Revoke(); stopped.Set(); approval.Set();
                if (enrollmentInvitation != null) enrollmentInvitation.Revoke();
                if (registrationHash != null) { Array.Clear(registrationHash, 0, registrationHash.Length); registrationHash = null; }
                if (sessionAudioKey != null) { Array.Clear(sessionAudioKey, 0, sessionAudioKey.Length); sessionAudioKey = null; }
                ownedInput = input; ownedClient = client; ownedFiles = files;
                ownedAudio = audio;
            }
            try { listener.Stop(); } catch { }
            if (enrollment != null) enrollment.Stop();
            if (trustedServer != null) trustedServer.Stop();
            if (ownedFiles != null) ownedFiles.Stop();
            if (ownedAudio != null) ownedAudio.Stop();
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
            { if (enrollment != null) enrollment.Dispose(); if (trustedServer != null) trustedServer.Dispose(); certificate.Dispose(); workerDone.Set(); ended = true; }
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
