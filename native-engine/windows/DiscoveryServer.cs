// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Threading;

namespace Knot.NativePreview
{
    internal sealed class DiscoveryRate
    {
        private readonly Func<long> clock;
        private long last;
        private double tokens = 10;
        internal DiscoveryRate(Func<long> clock) { this.clock = clock; last = clock(); }
        internal bool Take()
        {
            long now = clock(); if (now < last) return false;
            tokens = Math.Min(10, tokens + ((double)now - last) * 10 / Stopwatch.Frequency); last = now;
            if (tokens < 1) return false; tokens -= 1; return true;
        }
    }
    internal sealed class DiscoveryServer : IDisposable
    {
        private readonly object gate = new object();
        private readonly Socket receiver, sender;
        private readonly EnrollmentSlot slot;
        private readonly string name;
        private readonly int enrollmentPort;
        private readonly bool syntheticLoopback;
        private readonly Thread worker;
        private readonly DiscoveryRate rate;
        private bool stopped, started;
        internal readonly int Port;
        internal DiscoveryServer(IPAddress address, int discoveryPort, int enrollmentPort, EnrollmentSlot slot,
                                 string name, bool syntheticLoopback, Func<long> clock)
        {
            EnrollmentProtocol.ValidName(name);
            this.slot = slot; this.name = name; this.enrollmentPort = enrollmentPort; this.syntheticLoopback = syntheticLoopback;
            rate = new DiscoveryRate(clock);
            receiver = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            sender = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            try
            {
                receiver.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                receiver.ReceiveTimeout = 250;
                receiver.Bind(new IPEndPoint(syntheticLoopback ? address : IPAddress.Any, discoveryPort));
                sender.Bind(new IPEndPoint(address, 0)); sender.SendTimeout = 250;
                Port = ((IPEndPoint)receiver.LocalEndPoint).Port;
                worker = new Thread(Run); worker.IsBackground = true; worker.Name = "Knot native discovery";
            }
            catch { receiver.Close(); sender.Close(); throw; }
        }
        internal void Start() { lock (gate) { if (stopped || started) return; started = true; worker.Start(); } }
        private void Run()
        {
            byte[] buffer = new byte[1025];
            while (!IsStopped && slot.Available)
            {
                try
                {
                    EndPoint from = new IPEndPoint(IPAddress.Any, 0);
                    int count = receiver.ReceiveFrom(buffer, 0, buffer.Length, SocketFlags.None, ref from);
                    IPEndPoint peer = from as IPEndPoint;
                    if (peer == null || !(NativeProtocol.IsPrivate(peer.Address) || syntheticLoopback && IPAddress.IsLoopback(peer.Address)) || count != 24 || !rate.Take()) continue;
                    byte[] query = new byte[count]; Buffer.BlockCopy(buffer, 0, query, 0, count);
                    byte[] nonce = EnrollmentProtocol.DiscoveryNonce(query);
                    if (!slot.Available) continue;
                    // The sending socket is bound to the same selected address as
                    // enrollment and media. Reply port is intentionally ephemeral.
                    byte[] reply = EnrollmentProtocol.DiscoveryReply(nonce, slot.Id, name, enrollmentPort);
                    sender.SendTo(reply, peer);
                }
                catch (SocketException) { if (IsStopped) return; }
                catch (ObjectDisposedException) { return; }
                catch (ProtocolException) { }
            }
        }
        private bool IsStopped { get { lock (gate) return stopped; } }
        internal void Stop()
        {
            lock (gate) { if (stopped) return; stopped = true; }
            try { receiver.Close(); } catch { } try { sender.Close(); } catch { }
        }
        public void Dispose()
        {
            Stop();
            if (started && Thread.CurrentThread != worker && (worker.ThreadState & System.Threading.ThreadState.Unstarted) == 0) worker.Join();
        }
    }
}
