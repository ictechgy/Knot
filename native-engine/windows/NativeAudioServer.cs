// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Threading;

namespace Knot.NativePreview
{
    // Optional sidecar: its failures never reach the media/input worker. All
    // endpoint creation, reads and disposal stay on this dedicated MTA thread.
    internal sealed class NativeAudioServer : IDisposable
    {
        private readonly object gate = new object();
        private readonly IPAddress peer;
        private readonly X509Certificate2 certificate;
        private readonly byte[] key;
        private readonly Func<bool> active;
        private readonly IAudioCaptureFactory factory;
        private readonly Action<string> status;
        private readonly TcpListener listener;
        private readonly Thread worker;
        private readonly ManualResetEvent stopped = new ManualResetEvent(false);
        private TcpClient current;
        private volatile bool isStopped;
        private bool started, disposed;
        private int port;
        internal int Port { get { lock (gate) return port; } }

        internal NativeAudioServer(IPAddress address, IPAddress mediaPeer, X509Certificate2 cert,
            byte[] audioKey, Func<bool> isActive, IAudioCaptureFactory factory,
            Action<string> status = null, bool syntheticLoopback = false, int port = NativeAudioProtocol.Port)
        {
            if (address == null || mediaPeer == null || cert == null || audioKey == null || audioKey.Length != 32 ||
                isActive == null || factory == null) throw new ArgumentException("Invalid audio session.");
            if ((!NativeProtocol.IsPrivate(address) || !NativeProtocol.IsPrivate(mediaPeer)) &&
                !(syntheticLoopback && IPAddress.IsLoopback(address) && IPAddress.IsLoopback(mediaPeer)))
                throw new ArgumentException("Choose a private IPv4 or Tailscale address.");
            if (port != NativeAudioProtocol.Port && !(syntheticLoopback && port >= 0 && port <= 65535))
                throw new ArgumentException("Invalid audio listener port.");
            peer = mediaPeer; certificate = cert; key = (byte[])audioKey.Clone(); active = isActive;
            this.factory = factory; this.status = status; this.port = port;
            listener = new TcpListener(address, port);
            worker = new Thread(Run); worker.IsBackground = true; worker.Name = "Knot playback audio";
            worker.SetApartmentState(ApartmentState.MTA);
        }
        internal void Start()
        {
            // The predicate may take HostServer's gate. Never call it while our
            // gate is held: HostServer stops this sidecar while holding its gate.
            CheckActive();
            lock (gate)
            {
                if (isStopped || disposed || started) return;
                try
                {
                    listener.Start(1); port = ((IPEndPoint)listener.LocalEndpoint).Port;
                    started = true; worker.Start();
                }
                catch { listener.Stop(); isStopped = true; stopped.Set(); Array.Clear(key, 0, key.Length); stopped.Dispose(); throw; }
            }
        }
        private void CheckActive()
        {
            if (isStopped) throw new NativeAudioException("closed");
            bool permitted;
            try { permitted = active(); } catch { permitted = false; }
            if (!permitted || isStopped) throw new NativeAudioException("closed");
        }
        private void Run()
        {
            int failures = 0;
            try
            {
                while (!isStopped && failures < 8)
                {
                    CheckActive();
                    // A short poll observes revocation even when no viewer is
                    // connecting, without holding HostServer's session gate.
                    if (!listener.Pending()) { stopped.WaitOne(25); continue; }
                    TcpClient accepted = listener.AcceptTcpClient();
                    IPAddress source = ((IPEndPoint)accepted.Client.RemoteEndPoint).Address;
                    if (!source.Equals(peer)) { accepted.Close(); continue; }
                    lock (gate)
                    {
                        if (isStopped) { accepted.Close(); return; }
                        current = accepted;
                    }
                    bool authenticated = Serve(accepted);
                    if (!authenticated) ++failures;
                    lock (gate) { if (current == accepted) current = null; }
                }
            }
            catch { }
            finally { Stop(); stopped.Dispose(); }
        }
        private bool Serve(TcpClient accepted)
        {
            SslStream tls = null; bool authenticated = false;
            byte[] expected = null, pcm = null, helloBytes = null;
            try
            {
                accepted.NoDelay = true; accepted.SendBufferSize = 8192; accepted.ReceiveBufferSize = 4096;
                accepted.SendTimeout = 1000; accepted.ReceiveTimeout = 5000;
                tls = new SslStream(accepted.GetStream(), false); tls.ReadTimeout = 5000; tls.WriteTimeout = 1000;
                using (ConnectionDeadline budget = new ConnectionDeadline(5000, accepted.Close))
                {
                    tls.AuthenticateAsServer(certificate, false, SslProtocols.Tls12, false);
                    Packet hello = NativeAudioProtocol.ReadHello(tls); helloBytes = hello.Payload;
                    CheckActive();
                    lock (gate)
                    {
                        if (isStopped) throw new NativeAudioException("closed");
                        expected = (byte[])key.Clone();
                    }
                    if (!NativeAudioProtocol.Authenticate(helloBytes, expected)) throw new NativeAudioException("auth");
                    CheckActive();
                    if (!budget.TryComplete()) throw new NativeAudioException("timeout");
                    authenticated = true;
                }
                Array.Clear(expected, 0, expected.Length); expected = null;
                Array.Clear(helloBytes, 0, helloBytes.Length); helloBytes = null;
                CheckActive();
                // Open is after both independent authentication and a fresh
                // main-session permission check. A stop during a driver call
                // closes the socket; the owner disposes the result immediately.
                using (IAudioCapture capture = OpenCapture())
                {
                    CheckActive();
                    Write(tls, accepted, 2, NativeAudioProtocol.Ready());
                    Notify("Windows 재생 소리를 공유하고 있어요. 마이크는 공유하지 않습니다.");
                    pcm = new byte[NativeAudioProtocol.MaximumPcmBytes];
                    ulong sequence = 0, previousEnd = 0;
                    Stopwatch idle = Stopwatch.StartNew();
                    while (!isStopped)
                    {
                        CheckActive(); int frames; ulong first;
                        int result = capture.Read(pcm, out frames, out first);
                        CheckActive();
                        if (result < 0) throw new NativeAudioException("unavailable");
                        if (result == 0)
                        {
                            if (frames < 1 || frames > NativeAudioProtocol.MaximumFrames || first < previousEnd ||
                                first > ulong.MaxValue - (ulong)frames || sequence == ulong.MaxValue)
                                throw new NativeAudioException("protocol");
                            Write(tls, accepted, 3, NativeAudioProtocol.Pcm(++sequence, first, pcm, frames));
                            previousEnd = first + (ulong)frames; idle.Restart();
                        }
                        else if (result == 1)
                        {
                            if (frames != 0) throw new NativeAudioException("protocol");
                            if (idle.ElapsedMilliseconds >= 1000)
                            { Write(tls, accepted, 4, new byte[0]); idle.Restart(); }
                            stopped.WaitOne(5);
                        }
                        else throw new NativeAudioException("protocol");
                    }
                }
            }
            catch (NativeAudioException failure) { TryError(tls, accepted, failure.Code); }
            catch (ProtocolException) { TryError(tls, accepted, "protocol"); }
            catch (AuthenticationException) { }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
            catch { TryError(tls, accepted, "unavailable"); }
            finally
            {
                if (expected != null) Array.Clear(expected, 0, expected.Length);
                if (helloBytes != null) Array.Clear(helloBytes, 0, helloBytes.Length);
                if (pcm != null) Array.Clear(pcm, 0, pcm.Length);
                try { if (tls != null) tls.Dispose(); } catch { }
                try { accepted.Close(); } catch { }
                if (authenticated && !isStopped) Notify("소리 연결이 종료되었습니다. 화면 공유는 계속됩니다.");
            }
            return authenticated;
        }
        private IAudioCapture OpenCapture()
        {
            CheckActive();
            lock (gate) { if (isStopped) throw new NativeAudioException("closed"); }
            IAudioCapture capture = factory.Open();
            if (capture == null) throw new NativeAudioException("unavailable");
            try { CheckActive(); return capture; }
            catch { capture.Dispose(); throw; }
        }
        private void Write(SslStream tls, TcpClient client, byte kind, byte[] bytes)
        {
            CheckActive();
            using (ConnectionDeadline budget = new ConnectionDeadline(1000, client.Close))
            {
                NativeAudioProtocol.Write(tls, kind, bytes);
                if (!budget.TryComplete()) throw new NativeAudioException("timeout");
            }
            CheckActive();
        }
        private void TryError(SslStream tls, TcpClient client, string code)
        { try { if (tls != null && tls.IsAuthenticated && !isStopped) Write(tls, client, 127, NativeAudioProtocol.Error(code)); } catch { } }
        private void Notify(string text) { try { if (status != null) status(text); } catch { } }
        internal void Stop()
        {
            TcpClient closing;
            lock (gate)
            {
                if (isStopped) return;
                isStopped = true; stopped.Set(); Array.Clear(key, 0, key.Length); closing = current;
            }
            try { listener.Stop(); } catch { }
            try { if (closing != null) closing.Close(); } catch { }
        }
        public void Dispose()
        {
            bool releaseEvent;
            lock (gate) { if (disposed) return; disposed = true; releaseEvent = !started; }
            Stop();
            if (releaseEvent) stopped.Dispose();
            // Never wait for a driver while HostServer may hold its gate: the
            // audio worker may be finishing its final active() call. COM and the
            // endpoint are released by their owner, not this caller's thread.
        }
    }
}
