// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;

namespace Knot.NativePreview
{
    internal sealed class EnrollmentGrant
    {
        internal readonly byte[] Slot, Id;
        internal readonly string Invitation;
        internal readonly int RemainingMilliseconds;
        internal EnrollmentGrant(byte[] slot, byte[] id, string invitation, int remaining)
        { Slot = (byte[])slot.Clone(); Id = (byte[])id.Clone(); Invitation = invitation; RemainingMilliseconds = remaining; }
    }

    internal sealed class EnrollmentServer : IDisposable
    {
        private readonly object gate = new object();
        private readonly TcpListener listener;
        private readonly Thread worker;
        private readonly DiscoveryServer discovery;
        private readonly Func<byte[], string, IPAddress, EnrollmentGrant> issue;
        private readonly Func<byte[], string, IPAddress, bool, EnrollmentGrant> issueWithFiles;
        private readonly Action<EnrollmentFailure> unavailable;
        private readonly Action<string> status;
        private readonly Action<Stream, byte[]> writeOffer;
        private readonly IDisposable pairingModule;
        private readonly bool syntheticLoopback;
        private TcpClient client;
        private bool started, stopped, grantSent;
        internal readonly EnrollmentSlot Slot;
        internal readonly int Port;
        internal int DiscoveryPort { get { return discovery.Port; } }
        internal string Code { get { return Slot.DisplayCode; } }
        internal EnrollmentServer(IPAddress address, string name, bool syntheticLoopback, Func<long> clock,
                                  Func<byte[], string, IPAddress, EnrollmentGrant> issue, Action<EnrollmentFailure> unavailable, Action<string> status,
                                  Func<IDisposable> preflight = null, Action<Stream, byte[]> writeOffer = null,
                                  Func<byte[], string, IPAddress, bool, EnrollmentGrant> issueWithFiles = null)
        {
            this.issue = issue; this.unavailable = unavailable; this.status = status; this.syntheticLoopback = syntheticLoopback;
            this.issueWithFiles = issueWithFiles;
            this.writeOffer = writeOffer ?? delegate(Stream stream, byte[] payload) { EnrollmentProtocol.Write(stream, 4, payload); };
            // Fail before generating a code, charging attempts or opening discovery.
            pairingModule = (preflight ?? new Func<IDisposable>(PairingCryptoSession.Preflight))();
            if (pairingModule == null) throw new PairingSetupException();
            try
            {
                Slot = new EnrollmentSlot(clock); listener = new TcpListener(address, syntheticLoopback ? 0 : EnrollmentProtocol.Port);
                listener.Start(1); Port = ((IPEndPoint)listener.LocalEndpoint).Port;
                discovery = new DiscoveryServer(address, syntheticLoopback ? 0 : EnrollmentProtocol.DiscoveryPort, Port, Slot, name, syntheticLoopback, clock);
                worker = new Thread(Run); worker.IsBackground = true; worker.Name = "Knot native enrollment";
            }
            catch { if (Slot != null) Slot.Dispose(); if (listener != null) listener.Stop(); pairingModule.Dispose(); throw; }
        }
        internal void Start()
        {
            lock (gate)
            {
                if (stopped || started) return;
                started = true;
                try { discovery.Start(); worker.Start(); }
                catch { started = false; Stop(); throw; }
            }
        }
        private bool IsStopped { get { lock (gate) return stopped; } }
        private void Run()
        {
            EnrollmentFailure terminalFailure = EnrollmentFailure.Unavailable;
            try
            {
                while (!IsStopped && Slot.Available)
                {
                    if (!listener.Pending()) { Thread.Sleep(25); continue; }
                    TcpClient accepted = listener.AcceptTcpClient();
                    IPAddress remote = ((IPEndPoint)accepted.Client.RemoteEndPoint).Address;
                    if (!(NativeProtocol.IsPrivate(remote) || syntheticLoopback && IPAddress.IsLoopback(remote))) { accepted.Close(); continue; }
                    lock (gate) { if (stopped) { accepted.Close(); break; } client = accepted; }
                    byte[] password = null, confirmPlain = null, offerPlain = null;
                    NetworkStream stream = null;
                    try
                    {
                        int budget = Math.Max(1, Math.Min(10000, Slot.RemainingMilliseconds));
                        password = Slot.Begin();
                        accepted.NoDelay = true; accepted.ReceiveTimeout = budget; accepted.SendTimeout = budget;
                        accepted.ReceiveBufferSize = 8192; accepted.SendBufferSize = 8192;
                        stream = accepted.GetStream();
                        using (ConnectionDeadline deadline = new ConnectionDeadline(budget, accepted.Close))
                        {
                            if (!NativeProtocol.Equal(EnrollmentProtocol.ReadExact(stream, 8), EnrollmentProtocol.Preamble)) throw new ProtocolException("protocol");
                            Packet hello = EnrollmentProtocol.Read(stream, 1);
                            byte[] claimedSlot = new byte[16], peerMessage = new byte[32];
                            Buffer.BlockCopy(hello.Payload, 0, claimedSlot, 0, 16); Buffer.BlockCopy(hello.Payload, 16, peerMessage, 0, 32);
                            if (!NativeProtocol.Equal(claimedSlot, Slot.Id)) throw new EnrollmentAttemptException(EnrollmentFailure.StaleCandidate, "auth");
                            using (PairingCryptoSession crypto = PairingCryptoSession.Create(true, password, Slot.Id))
                            {
                                byte[] response = new byte[48]; Buffer.BlockCopy(Slot.Id, 0, response, 0, 16); Buffer.BlockCopy(crypto.Message, 0, response, 16, 32);
                                EnrollmentProtocol.Write(stream, 2, response);
                                crypto.Process(peerMessage);
                                // SPAKE2 process success alone cannot authorize anything.
                                byte[] confirmation = EnrollmentProtocol.Read(stream, 3).Payload;
                                try { confirmPlain = crypto.Open(3, confirmation); }
                                catch (ProtocolException error)
                                {
                                    if (error.Code == "auth") throw new EnrollmentAttemptException(EnrollmentFailure.Authentication, "auth");
                                    throw;
                                }
                                bool files;
                                string name = EnrollmentProtocol.ConfirmName(confirmPlain, Slot.Id, out files);
                                if (IsStopped) throw new ProtocolException("closed");
                                EnrollmentGrant grant = issueWithFiles == null ? issue(Slot.Id, name, remote) : issueWithFiles(Slot.Id, name, remote, files);
                                // The consumed slot/grant must never be retried if
                                // encoding, sealing or delivering this offer fails.
                                terminalFailure = EnrollmentFailure.Delivery;
                                offerPlain = EnrollmentProtocol.Offer(grant.Slot, grant.Id, grant.Invitation, grant.RemainingMilliseconds);
                                byte[] sealedOffer = crypto.Seal(4, offerPlain);
                                if (IsStopped) throw new ProtocolException("closed");
                                writeOffer(stream, sealedOffer);
                                if (!deadline.TryComplete()) throw new ProtocolException("expired");
                                grantSent = true;
                            }
                        }
                    }
                    catch (EnrollmentAttemptException error) { TryError(stream, error.WireCode); if (terminalFailure != EnrollmentFailure.Delivery) Notice(error.Failure); }
                    catch (PairingSetupException) { TryError(stream, "protocol"); if (terminalFailure != EnrollmentFailure.Delivery) terminalFailure = EnrollmentFailure.Setup; }
                    catch (ProtocolException error) { TryError(stream, error.Code); if (terminalFailure != EnrollmentFailure.Delivery) Notice(EnrollmentGuidance.Classify(error)); }
                    catch (IOException) { }
                    catch (SocketException) { }
                    catch (ObjectDisposedException) { }
                    catch (Exception) { TryError(stream, "protocol"); if (terminalFailure != EnrollmentFailure.Delivery) Notice(EnrollmentFailure.Protocol); }
                    finally
                    {
                        if (password != null) Array.Clear(password, 0, password.Length);
                        if (confirmPlain != null) Array.Clear(confirmPlain, 0, confirmPlain.Length);
                        if (offerPlain != null) Array.Clear(offerPlain, 0, offerPlain.Length);
                        Slot.Failed();
                        try { accepted.Close(); } catch { }
                        lock (gate) { if (client == accepted) client = null; }
                    }
                    if (grantSent || terminalFailure == EnrollmentFailure.Setup || terminalFailure == EnrollmentFailure.Delivery) break;
                }
            }
            catch (SocketException) { }
            catch (ObjectDisposedException) { }
            catch (InvalidOperationException) { } // Stop may deactivate Pending/Accept.
            finally
            {
                bool failed = !grantSent && !IsStopped;
                try { listener.Stop(); } catch { } discovery.Stop();
                if (failed && unavailable != null) unavailable(terminalFailure);
            }
        }
        private void Notice(EnrollmentFailure failure) { if (status != null && !IsStopped) status(EnrollmentGuidance.For(failure)); }
        private static void TryError(Stream stream, string code)
        { try { if (stream != null) EnrollmentProtocol.Write(stream, 127, EnrollmentProtocol.Error(code)); } catch { } }
        internal void Stop()
        {
            TcpClient owned;
            lock (gate) { if (stopped) return; stopped = true; owned = client; Slot.Dispose(); }
            try { listener.Stop(); } catch { } discovery.Stop();
            try { if (owned != null) owned.Close(); } catch { }
        }
        public void Dispose()
        {
            Stop();
            if (started && Thread.CurrentThread != worker && (worker.ThreadState & ThreadState.Unstarted) == 0) worker.Join();
            discovery.Dispose(); Slot.Dispose(); pairingModule.Dispose();
        }
    }
}
