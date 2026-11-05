// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Threading;

namespace Knot.NativePreview
{
    // Owns a separate listener and worker; it never writes a media/input stream.
    // The host gate is also the synchronous final-publication/revocation gate.
    internal sealed class FileServer : IDisposable
    {
        private readonly object gate;
        private readonly Func<bool> active;
        private readonly IPAddress peer;
        private readonly X509Certificate2 certificate;
        private readonly TcpListener listener;
        private readonly Thread worker;
        private readonly ManualResetEvent stopped = new ManualResetEvent(false);
        private readonly FileSharedRoot root;
        private readonly FileSharingOptions options;
        private readonly FilePacer pacer;
        private readonly Action beforePublish;
        private readonly int packetBudgetMilliseconds;
        private readonly byte[] token = EnrollmentProtocol.Random(32);
        private readonly Dictionary<string, FileEntrySnapshot> entries = new Dictionary<string, FileEntrySnapshot>(StringComparer.Ordinal);
        private TcpClient current;
        private bool isStopped, started, disposed;
        private long reserved;
        internal readonly int Port;
        internal string Token { get { lock (gate) { EnsureActive(); return NativeProtocol.Base64Url(token); } } }
        internal string RootName { get { return options.RootName; } }
        internal long Reserved { get { lock (gate) return reserved; } }
        internal FileServer(IPAddress address, IPAddress peer, X509Certificate2 certificate, FileSharingOptions options,
                            object sessionGate, Func<bool> sessionActive, int port = FileProtocol.Port, Action beforePublish = null,
                            int packetBudgetMilliseconds = 30000)
        {
            if (address == null || peer == null || certificate == null || options == null || sessionGate == null || sessionActive == null)
                throw new ArgumentException("Invalid file session.");
            if (packetBudgetMilliseconds < 1 || packetBudgetMilliseconds > 30000) throw new ArgumentException("Invalid file progress budget.");
            this.peer = peer; this.certificate = certificate; this.options = options; gate = sessionGate; active = sessionActive;
            this.beforePublish = beforePublish; pacer = new FilePacer(stopped, CheckActive);
            this.packetBudgetMilliseconds = packetBudgetMilliseconds;
            root = new FileSharedRoot(options);
            try { listener = new TcpListener(address, port); listener.Start(1); Port = ((IPEndPoint)listener.LocalEndpoint).Port; }
            catch { root.Dispose(); Array.Clear(token, 0, token.Length); throw; }
            worker = new Thread(Run); worker.IsBackground = true; worker.Name = "Knot native file worker";
        }
        internal void Start()
        {
            lock (gate)
            {
                if (isStopped || started) return;
                EnsureActive(); started = true; worker.Start();
            }
        }
        private void EnsureActive()
        { if (isStopped || !active()) throw new FileTransferException("auth"); }
        private void CheckActive() { lock (gate) EnsureActive(); }
        private void Reserve(long size)
        {
            lock (gate)
            {
                EnsureActive();
                if (size < 0 || size > FileProtocol.MaximumSize || reserved > FileProtocol.MaximumSize - size) throw new FileTransferException("quota");
                reserved += size;
            }
        }
        private void Run()
        {
            try
            {
                while (!stopped.WaitOne(0))
                {
                    TcpClient accepted;
                    try { accepted = listener.AcceptTcpClient(); }
                    catch (SocketException) { if (stopped.WaitOne(0)) return; throw; }
                    catch (ObjectDisposedException) { return; }
                    IPAddress source = ((IPEndPoint)accepted.Client.RemoteEndPoint).Address;
                    lock (gate)
                    {
                        if (isStopped || !active() || !source.Equals(peer)) { accepted.Close(); continue; }
                        current = accepted;
                    }
                    Serve(accepted);
                    lock (gate) { if (current == accepted) current = null; }
                }
            }
            catch { Stop(); }
        }
        private void Serve(TcpClient accepted)
        {
            SslStream tls = null;
            try
            {
                accepted.NoDelay = true; accepted.SendBufferSize = 65536; accepted.ReceiveBufferSize = 65536;
                accepted.SendTimeout = 30000; accepted.ReceiveTimeout = 30000;
                tls = new SslStream(accepted.GetStream(), false);
                tls.ReadTimeout = 30000; tls.WriteTimeout = 30000;
                using (ConnectionDeadline budget = new ConnectionDeadline(10000, accepted.Close))
                {
                    tls.AuthenticateAsServer(certificate, false, SslProtocols.Tls12, false);
                    FilePacket hello = FileProtocol.Read(tls);
                    if (hello.Kind != 0x40) throw new FileTransferException("auth");
                    Dictionary<string, object> body = FileProtocol.Object(hello.Payload, "v", "token");
                    if (StrictJson.Integer(body, "v", 1, 1) != 1) throw new FileTransferException("auth");
                    byte[] candidate;
                    try { candidate = NativeProtocol.DecodeToken(FileProtocol.Text(body, "token")); }
                    catch (ProtocolException) { throw new FileTransferException("auth"); }
                    try
                    {
                        lock (gate)
                        {
                            EnsureActive();
                            if (!NativeProtocol.Equal(candidate, token)) throw new FileTransferException("auth");
                            if (!budget.TryComplete()) throw new FileTransferException("timeout");
                        }
                    }
                    finally { Array.Clear(candidate, 0, candidate.Length); }
                }
                Write(tls, accepted, 0x41, FileProtocol.Json("{\"v\":1}"));
                FilePacket request = Read(tls, accepted);
                if (request.Kind == 0x42) List(tls, accepted);
                else if (request.Kind == 0x45) Put(tls, accepted, request.Payload);
                else if (request.Kind == 0x46) Get(tls, accepted, request.Payload);
                else throw new FileTransferException("protocol");
            }
            catch (FileTransferException failure) { TryError(tls, accepted, failure.Code); }
            catch (ProtocolException) { TryError(tls, accepted, "protocol"); }
            catch (UnauthorizedAccessException) { TryError(tls, accepted, "denied"); }
            catch (AuthenticationException) { }
            catch (ObjectDisposedException) { }
            catch (Exception) { TryError(tls, accepted, "io"); }
            finally
            {
                try { if (tls != null) tls.Dispose(); } catch { }
                try { accepted.Close(); } catch { }
            }
        }
        private FilePacket Read(SslStream tls, TcpClient client)
        {
            CheckActive();
            using (ConnectionDeadline budget = new ConnectionDeadline(packetBudgetMilliseconds, client.Close))
            {
                FilePacket result = FileProtocol.Read(tls);
                if (!budget.TryComplete()) throw new FileTransferException("timeout");
                CheckActive(); return result;
            }
        }
        private void Write(SslStream tls, TcpClient client, byte kind, byte[] bytes)
        {
            CheckActive();
            using (ConnectionDeadline budget = new ConnectionDeadline(packetBudgetMilliseconds, client.Close))
            {
                FileProtocol.Write(tls, kind, bytes);
                if (!budget.TryComplete()) throw new FileTransferException("timeout");
                CheckActive();
            }
        }
        private void TryError(SslStream tls, TcpClient client, string code)
        { try { if (tls != null && tls.IsAuthenticated && !stopped.WaitOne(0)) Write(tls, client, 0x7f, FileProtocol.Error(code)); } catch { } }
        private void List(SslStream tls, TcpClient client)
        {
            CheckActive(); bool truncated;
            List<FileEntrySnapshot> values = root.List(out truncated);
            lock (gate)
            {
                EnsureActive(); entries.Clear();
                foreach (FileEntrySnapshot value in values) entries.Add(value.Id, value);
            }
            foreach (FileEntrySnapshot value in values)
                Write(tls, client, 0x43, FileProtocol.Json("{\"entry\":" + StrictJson.Quote(value.Id) + ",\"name\":" + StrictJson.Quote(value.Name) + ",\"size\":" + value.Size.ToString(System.Globalization.CultureInfo.InvariantCulture) + "}"));
            Write(tls, client, 0x44, FileProtocol.Json("{\"count\":" + values.Count.ToString(System.Globalization.CultureInfo.InvariantCulture) + ",\"truncated\":" + (truncated ? "true" : "false") + "}"));
        }
        private void Put(SslStream tls, TcpClient client, byte[] bytes)
        {
            Dictionary<string, object> request = FileProtocol.Object(bytes, "name", "size");
            string name = FileProtocol.Text(request, "name"); FileProtocol.ValidName(name); long size = FileProtocol.Size(request, "size");
            Reserve(size);
            using (FilePartial partial = root.CreatePartial(size))
            using (SHA256 sha = SHA256.Create())
            {
                Write(tls, client, 0x47, FileProtocol.Metadata(name, size));
                long offset = 0;
                for (;;)
                {
                    FilePacket packet = Read(tls, client);
                    if (packet.Kind == 0x49)
                    {
                        if (offset != size || NativeProtocol.U64(packet.Payload, 0) != (ulong)size) throw new FileTransferException("protocol");
                        sha.TransformFinalBlock(new byte[0], 0, 0); byte[] digest = sha.Hash;
                        byte[] offered = new byte[32]; Buffer.BlockCopy(packet.Payload, 8, offered, 0, 32);
                        if (!NativeProtocol.Equal(digest, offered)) throw new FileTransferException("changed");
                        partial.PreparePublication();
                        if (beforePublish != null) beforePublish();
                        string actual;
                        // Stop and publication share this gate: never check then
                        // await/write a destination after permission was revoked.
                        lock (gate) { EnsureActive(); actual = partial.Publish(name); }
                        Write(tls, client, 0x4a, FileProtocol.Complete(actual, size, digest)); return;
                    }
                    if (packet.Kind != 0x48 || NativeProtocol.U64(packet.Payload, 0) != (ulong)offset) throw new FileTransferException("protocol");
                    int count = packet.Payload.Length - 8;
                    if (offset > size - count) throw new FileTransferException("protocol");
                    pacer.Account(count); partial.Stream.Write(packet.Payload, 8, count);
                    sha.TransformBlock(packet.Payload, 8, count, packet.Payload, 8); offset += count;
                }
            }
        }
        private void Get(SslStream tls, TcpClient client, byte[] bytes)
        {
            Dictionary<string, object> request = FileProtocol.Object(bytes, "entry");
            string id = FileProtocol.Text(request, "entry");
            if (!FileProtocol.Hex(id, 32)) throw new FileTransferException("protocol");
            FileEntrySnapshot entry;
            lock (gate) { EnsureActive(); if (!entries.TryGetValue(id, out entry)) throw new FileTransferException("missing"); }
            FileHandleInfo before;
            using (FileStream source = root.OpenRead(entry.Name, out before))
            using (SHA256 sha = SHA256.Create())
            {
                if (!entry.Info.Same(before)) throw new FileTransferException("changed"); Reserve(before.Size);
                Write(tls, client, 0x47, FileProtocol.Metadata(entry.Name, before.Size));
                byte[] buffer = new byte[FileProtocol.ChunkSize], payload = new byte[FileProtocol.ChunkSize + 8];
                long offset = 0;
                while (offset < before.Size)
                {
                    CheckActive(); int count = source.Read(buffer, 0, (int)Math.Min(buffer.Length, before.Size - offset));
                    if (count <= 0) throw new FileTransferException("changed");
                    pacer.Account(count); sha.TransformBlock(buffer, 0, count, buffer, 0);
                    NativeProtocol.Put64(payload, 0, (ulong)offset); Buffer.BlockCopy(buffer, 0, payload, 8, count);
                    byte[] packet = payload;
                    if (count != buffer.Length) { packet = new byte[count + 8]; Buffer.BlockCopy(payload, 0, packet, 0, packet.Length); }
                    Write(tls, client, 0x48, packet); offset += count;
                }
                if (source.ReadByte() != -1 || !before.Same(root.Info(source, entry.Name))) throw new FileTransferException("changed");
                sha.TransformFinalBlock(new byte[0], 0, 0); byte[] digest = sha.Hash;
                Write(tls, client, 0x49, FileProtocol.Finish(before.Size, digest));
                FilePacket complete = Read(tls, client);
                if (complete.Kind != 0x4a) throw new FileTransferException("protocol");
                Dictionary<string, object> result = FileProtocol.Object(complete.Payload, "name", "size", "sha256");
                FileProtocol.ValidName(FileProtocol.Text(result, "name"));
                if (FileProtocol.Size(result, "size") != before.Size || FileProtocol.Text(result, "sha256") != FileProtocol.Hex(digest)) throw new FileTransferException("changed");
            }
        }
        internal void Stop()
        {
            TcpClient owned;
            lock (gate)
            {
                if (isStopped) return; isStopped = true;
                entries.Clear(); Array.Clear(token, 0, token.Length); stopped.Set(); owned = current;
            }
            try { listener.Stop(); } catch { }
            try { if (owned != null) owned.Close(); } catch { }
        }
        public void Dispose()
        {
            Stop();
            bool join; lock (gate) { if (disposed) return; disposed = true; join = started; }
            // Called only by the host's background writer during teardown, never
            // the UI stop action. Closing sockets wakes all bounded TLS work.
            if (join && worker != Thread.CurrentThread) worker.Join();
            root.Dispose(); stopped.Dispose();
        }
    }

    internal sealed class FilePacer
    {
        private readonly ManualResetEvent stopped;
        private readonly Action active;
        private long last = Stopwatch.GetTimestamp();
        private double tokens = FileProtocol.ChunkSize;
        internal FilePacer(ManualResetEvent stopped, Action active) { this.stopped = stopped; this.active = active; }
        internal void Account(int count)
        {
            if (count < 1 || count > FileProtocol.ChunkSize) throw new FileTransferException("protocol");
            for (;;)
            {
                active(); long now = Stopwatch.GetTimestamp(), elapsed = now - last;
                if (elapsed < 0) throw new FileTransferException("timeout");
                tokens = Math.Min(FileProtocol.ChunkSize, tokens + elapsed * (double)FileProtocol.RateBytesPerSecond / Stopwatch.Frequency); last = now;
                if (tokens >= count) { tokens -= count; return; }
                double remaining = (count - tokens) / FileProtocol.RateBytesPerSecond;
                int wait = (int)Math.Max(1, Math.Min(100, Math.Ceiling(remaining * 1000)));
                if (stopped.WaitOne(wait)) throw new FileTransferException("auth");
            }
        }
    }
}
