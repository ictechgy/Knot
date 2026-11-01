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
        private readonly Action unavailable;
        private readonly Action<string> status;
        private readonly bool syntheticLoopback;
        private TcpClient client;
        private bool started, stopped, grantSent;
        internal readonly EnrollmentSlot Slot;
        internal readonly int Port;
        internal int DiscoveryPort { get { return discovery.Port; } }
        internal string Code { get { return Slot.DisplayCode; } }
        internal EnrollmentServer(IPAddress address, string name, bool syntheticLoopback, Func<long> clock,
                                  Func<byte[], string, IPAddress, EnrollmentGrant> issue, Action unavailable, Action<string> status)
        {
            this.issue = issue; this.unavailable = unavailable; this.status = status; this.syntheticLoopback = syntheticLoopback;
            Slot = new EnrollmentSlot(clock); listener = new TcpListener(address, syntheticLoopback ? 0 : EnrollmentProtocol.Port);
            try
            {
                listener.Start(1); Port = ((IPEndPoint)listener.LocalEndpoint).Port;
                discovery = new DiscoveryServer(address, syntheticLoopback ? 0 : EnrollmentProtocol.DiscoveryPort, Port, Slot, name, syntheticLoopback, clock);
                worker = new Thread(Run); worker.IsBackground = true; worker.Name = "Knot native enrollment";
            }
            catch { Slot.Dispose(); listener.Stop(); throw; }
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
                        using (Timer deadline = new Timer(delegate { try { accepted.Close(); } catch { } }, null, budget, Timeout.Infinite))
                        {
                            if (!NativeProtocol.Equal(EnrollmentProtocol.ReadExact(stream, 8), EnrollmentProtocol.Preamble)) throw new ProtocolException("protocol");
                            Packet hello = EnrollmentProtocol.Read(stream, 1);
                            byte[] claimedSlot = new byte[16], peerMessage = new byte[32];
                            Buffer.BlockCopy(hello.Payload, 0, claimedSlot, 0, 16); Buffer.BlockCopy(hello.Payload, 16, peerMessage, 0, 32);
                            if (!NativeProtocol.Equal(claimedSlot, Slot.Id)) throw new ProtocolException("auth");
                            using (PairingCryptoSession crypto = PairingCryptoSession.Create(true, password, Slot.Id))
                            {
                                byte[] response = new byte[48]; Buffer.BlockCopy(Slot.Id, 0, response, 0, 16); Buffer.BlockCopy(crypto.Message, 0, response, 16, 32);
                                EnrollmentProtocol.Write(stream, 2, response);
                                crypto.Process(peerMessage);
                                // SPAKE2 process success alone cannot authorize anything.
                                confirmPlain = crypto.Open(3, EnrollmentProtocol.Read(stream, 3).Payload);
                                string name = EnrollmentProtocol.ConfirmName(confirmPlain, Slot.Id);
                                if (IsStopped) throw new ProtocolException("closed");
                                EnrollmentGrant grant = issue(Slot.Id, name, remote);
                                offerPlain = EnrollmentProtocol.Offer(grant.Slot, grant.Id, grant.Invitation, grant.RemainingMilliseconds);
                                byte[] sealedOffer = crypto.Seal(4, offerPlain);
                                if (IsStopped) throw new ProtocolException("closed");
                                EnrollmentProtocol.Write(stream, 4, sealedOffer);
                                grantSent = true;
                            }
                        }
                    }
                    catch (ProtocolException error) { TryError(stream, error.Code); if (status != null && !IsStopped) status("연결번호를 확인하지 못했어요. Mac에서 번호를 다시 입력해주세요."); }
                    catch (IOException) { }
                    catch (SocketException) { }
                    catch (ObjectDisposedException) { }
                    catch (Exception) { TryError(stream, "protocol"); if (status != null && !IsStopped) status("연결을 준비하지 못했어요. 설치 파일과 연결 경로를 확인해주세요."); }
                    finally
                    {
                        if (password != null) Array.Clear(password, 0, password.Length);
                        if (confirmPlain != null) Array.Clear(confirmPlain, 0, confirmPlain.Length);
                        if (offerPlain != null) Array.Clear(offerPlain, 0, offerPlain.Length);
                        Slot.Failed();
                        try { accepted.Close(); } catch { }
                        lock (gate) { if (client == accepted) client = null; }
                    }
                    if (grantSent) break;
                }
            }
            catch (SocketException) { }
            catch (ObjectDisposedException) { }
            catch (InvalidOperationException) { } // Stop may deactivate Pending/Accept.
            finally
            {
                bool failed = !grantSent && !IsStopped;
                try { listener.Stop(); } catch { } discovery.Stop();
                if (failed && unavailable != null) unavailable();
            }
        }
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
            discovery.Dispose(); Slot.Dispose();
        }
    }
}
