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
        private readonly Func<string, string[]> captureDrag;
        private readonly Action<string> cancelDrag;
        private readonly FileExportRegistry exports = new FileExportRegistry();
        private readonly int packetBudgetMilliseconds;
        private readonly byte[] token = EnrollmentProtocol.Random(32);
        private readonly Dictionary<string, FileEntrySnapshot> entries = new Dictionary<string, FileEntrySnapshot>(StringComparer.Ordinal);
        private TcpClient current;
        private bool isStopped, started, disposed;
        private long reserved;
        private int reservedNodes;
        internal readonly int Port;
        internal string Token { get { lock (gate) { EnsureActive(); return NativeProtocol.Base64Url(token); } } }
        internal string RootName { get { return options.RootName; } }
        internal long Reserved { get { lock (gate) return reserved; } }
        internal int ReservedNodes { get { lock (gate) return reservedNodes; } }
        internal FileServer(IPAddress address, IPAddress peer, X509Certificate2 certificate, FileSharingOptions options,
                            object sessionGate, Func<bool> sessionActive, int port = FileProtocol.Port, Action beforePublish = null,
                            int packetBudgetMilliseconds = 30000, Func<string, string[]> captureDrag = null, Action<string> cancelDrag = null)
        {
            if (address == null || peer == null || certificate == null || options == null || sessionGate == null || sessionActive == null)
                throw new ArgumentException("Invalid file session.");
            if (packetBudgetMilliseconds < 1 || packetBudgetMilliseconds > 30000) throw new ArgumentException("Invalid file progress budget.");
            this.peer = peer; this.certificate = certificate; this.options = options; gate = sessionGate; active = sessionActive;
            this.beforePublish = beforePublish; pacer = new FilePacer(stopped, CheckActive);
            this.captureDrag = captureDrag; this.cancelDrag = cancelDrag;
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
        private void Reserve(long size, int nodes = 1)
        {
            lock (gate)
            {
                EnsureActive();
                if (size < 0 || size > FileProtocol.MaximumSize || reserved > FileProtocol.MaximumSize - size || nodes < 1 || nodes > FileProtocol.RunNodeLimit || reservedNodes > FileProtocol.RunNodeLimit - nodes) throw new FileTransferException("quota");
                reserved += size; reservedNodes += nodes;
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
                    if (StrictJson.Integer(body, "v", 2, 2) != 2) throw new FileTransferException("auth");
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
                Write(tls, accepted, 0x41, FileProtocol.Json("{\"v\":2}"));
                FilePacket request = Read(tls, accepted);
                if (request.Kind == 0x42) List(tls, accepted);
                else if (request.Kind == 0x45) Put(tls, accepted, request.Payload);
                else if (request.Kind == 0x46) Get(tls, accepted, request.Payload);
                else if (request.Kind == 0x4b) PutTree(tls, accepted, request.Payload);
                else if (request.Kind == 0x4e) Capture(tls, accepted, request.Payload);
                else if (request.Kind == 0x4f) CancelCapture(request.Payload);
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
                Write(tls, client, 0x43, FileProtocol.Entry(value));
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
                Write(tls, client, 0x47, FileProtocol.Accepted(name, size, "file", 0));
                long offset = 0;
                for (;;)
                {
                    FilePacket packet = Read(tls, client);
                    if (packet.Kind == 0x49)
                    {
                        if (offset != size || FileProtocol.U64(packet.Payload, 0) != (ulong)size) throw new FileTransferException("protocol");
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
                    if (packet.Kind != 0x48 || FileProtocol.U64(packet.Payload, 0) != (ulong)offset) throw new FileTransferException("protocol");
                    int count = packet.Payload.Length - 8;
                    if (offset > size - count) throw new FileTransferException("protocol");
                    pacer.Account(count); partial.Stream.Write(packet.Payload, 8, count);
                    sha.TransformBlock(packet.Payload, 8, count, packet.Payload, 8); offset += count;
                }
            }
        }
        private static string Nonce(byte[] bytes)
        {
            string nonce = FileProtocol.Text(FileProtocol.Object(bytes, "nonce"), "nonce");
            if (!FileProtocol.Hex(nonce, 32)) throw new FileTransferException("protocol"); return nonce;
        }
        private void Capture(SslStream tls, TcpClient client, byte[] bytes)
        {
            string nonce = Nonce(bytes);
            try
            {
                CheckActive(); if (captureDrag == null) throw new FileTransferException("denied");
                string[] paths = captureDrag(nonce); CheckActive();
                List<FileEntrySnapshot> captured;
                lock (gate) { EnsureActive(); captured = exports.Add(nonce, paths); }
                foreach (FileEntrySnapshot entry in captured) Write(tls, client, 0x43, FileProtocol.Entry(entry));
                Write(tls, client, 0x44, FileProtocol.Json("{\"count\":" + captured.Count.ToString(System.Globalization.CultureInfo.InvariantCulture) + ",\"truncated\":false}"));
            }
            catch { exports.Revoke(nonce); if (cancelDrag != null) cancelDrag(nonce); throw; }
        }
        private void CancelCapture(byte[] bytes)
        {
            string nonce = Nonce(bytes); CheckActive(); exports.Revoke(nonce);
            if (cancelDrag != null) cancelDrag(nonce);
        }
        private void PutTree(SslStream tls, TcpClient client, byte[] bytes)
        {
            Dictionary<string, object> request = FileProtocol.Object(bytes, "name", "size", "count");
            string name = FileProtocol.Text(request, "name"); FileProtocol.ValidName(name);
            FileExportSource.RejectPackage(name, true);
            long size = FileProtocol.Size(request, "size"); int count = FileProtocol.Count(request, "count", FileProtocol.TreeNodeLimit);
            Reserve(size, count + 1);
            using (FileTreePartial partial = root.CreateTree(size, count))
            using (SHA256 tree = SHA256.Create())
            {
                Write(tls, client, 0x47, FileProtocol.Accepted(name, size, "folder", count));
                for (int i = 0; i < count; ++i)
                {
                    FilePacket packet = Read(tls, client); if (packet.Kind != 0x4c) throw new FileTransferException("protocol");
                    FileTreeNode node; FileStream stream = partial.Add(packet.Payload, out node); FileTreeManifest.HashNode(tree, packet.Payload);
                    if (node.Kind == "file") ReceiveFile(tls, client, stream, node.Size, tree);
                }
                FilePacket end = Read(tls, client); if (end.Kind != 0x4d) throw new FileTransferException("protocol");
                Dictionary<string, object> result = FileProtocol.Object(end.Payload, "count", "size", "sha256");
                tree.TransformFinalBlock(new byte[0], 0, 0); byte[] hash = tree.Hash;
                if (FileProtocol.Count(result, "count", FileProtocol.TreeNodeLimit) != count || FileProtocol.Size(result, "size") != size || FileProtocol.Text(result, "sha256") != FileProtocol.Hex(hash))
                    throw new FileTransferException("changed");
                partial.PreparePublication(); if (beforePublish != null) beforePublish(); string actual;
                lock (gate) { EnsureActive(); actual = partial.Publish(name); }
                Write(tls, client, 0x4a, FileProtocol.Complete(actual, size, hash));
            }
        }
        private void ReceiveFile(SslStream tls, TcpClient client, FileStream destination, long size, HashAlgorithm tree)
        {
            using (SHA256 hash = SHA256.Create())
            {
                long offset = 0;
                for (;;)
                {
                    FilePacket packet = Read(tls, client);
                    if (packet.Kind == 0x49)
                    {
                        if (offset != size || FileProtocol.U64(packet.Payload, 0) != (ulong)size) throw new FileTransferException("protocol");
                        hash.TransformFinalBlock(new byte[0], 0, 0); byte[] offered = new byte[32]; Buffer.BlockCopy(packet.Payload, 8, offered, 0, 32);
                        if (!NativeProtocol.Equal(offered, hash.Hash)) throw new FileTransferException("changed"); return;
                    }
                    if (packet.Kind != 0x48 || FileProtocol.U64(packet.Payload, 0) != (ulong)offset) throw new FileTransferException("protocol");
                    int count = packet.Payload.Length - 8; if (offset > size - count) throw new FileTransferException("protocol");
                    pacer.Account(count); destination.Write(packet.Payload, 8, count); hash.TransformBlock(packet.Payload, 8, count, packet.Payload, 8);
                    if (tree != null) tree.TransformBlock(packet.Payload, 8, count, packet.Payload, 8); offset += count;
                }
            }
        }
        private byte[] SendFile(SslStream tls, TcpClient client, FileStream source, long size, HashAlgorithm tree, Action validate)
        {
            using (SHA256 hash = SHA256.Create())
            {
                byte[] payload = new byte[FileProtocol.ChunkSize + 8]; long offset = 0;
                while (offset < size)
                {
                    CheckActive(); int count = source.Read(payload, 8, (int)Math.Min(FileProtocol.ChunkSize, size - offset));
                    if (count <= 0) throw new FileTransferException("changed"); pacer.Account(count);
                    hash.TransformBlock(payload, 8, count, payload, 8); if (tree != null) tree.TransformBlock(payload, 8, count, payload, 8);
                    NativeProtocol.Put64(payload, 0, (ulong)offset); byte[] packet = payload;
                    if (count != FileProtocol.ChunkSize) { packet = new byte[count + 8]; Buffer.BlockCopy(payload, 0, packet, 0, packet.Length); }
                    Write(tls, client, 0x48, packet); offset += count;
                }
                if (source.ReadByte() != -1) throw new FileTransferException("changed"); validate();
                hash.TransformFinalBlock(new byte[0], 0, 0); byte[] digest = hash.Hash;
                Write(tls, client, 0x49, FileProtocol.Finish(size, digest)); return digest;
            }
        }
        private void ReadComplete(SslStream tls, TcpClient client, long size, byte[] hash)
        {
            FilePacket complete = Read(tls, client); if (complete.Kind != 0x4a) throw new FileTransferException("protocol");
            Dictionary<string, object> result = FileProtocol.Object(complete.Payload, "name", "size", "sha256");
            FileProtocol.ValidName(FileProtocol.Text(result, "name"));
            if (FileProtocol.Size(result, "size") != size || FileProtocol.Text(result, "sha256") != FileProtocol.Hex(hash)) throw new FileTransferException("changed");
        }
        private void Get(SslStream tls, TcpClient client, byte[] bytes)
        {
            string id = FileProtocol.Text(FileProtocol.Object(bytes, "entry"), "entry");
            if (!FileProtocol.Hex(id, 32)) throw new FileTransferException("protocol");
            FileExportSource selected;
            lock (gate)
            {
                EnsureActive(); selected = exports.Claim(id);
                if (selected == null)
                {
                    FileEntrySnapshot entry; if (!entries.TryGetValue(id, out entry)) throw new FileTransferException("missing");
                    selected = new FileExportSource(root.OpenEntry(entry.Name), entry);
                }
            }
            using (FileExportSource source = selected)
            {
                source.Validate();
                if (source.Entry.Info.Directory)
                {
                    using (FileTreeSource snapshot = new FileTreeSource(source))
                    using (SHA256 tree = SHA256.Create())
                    {
                        CheckActive(); Reserve(snapshot.Size, snapshot.Nodes.Count + 1);
                        Write(tls, client, 0x47, FileProtocol.Accepted(source.Entry.Name, snapshot.Size, "folder", snapshot.Nodes.Count));
                        foreach (FileTreeSource.Node node in snapshot.Nodes)
                        {
                            Write(tls, client, 0x4c, node.Metadata.Json); FileTreeManifest.HashNode(tree, node.Metadata.Json);
                            if (node.Metadata.Kind == "file")
                                SendFile(tls, client, node.Stream, node.Info.Size, tree, delegate {
                                    if (!node.Info.Same(new FileHandleInfo(FileNative.Info(node.Handle, false)))) throw new FileTransferException("changed");
                                });
                        }
                        snapshot.Validate(); tree.TransformFinalBlock(new byte[0], 0, 0); byte[] hash = tree.Hash;
                        Write(tls, client, 0x4d, FileProtocol.TreeEnd(snapshot.Nodes.Count, snapshot.Size, hash)); ReadComplete(tls, client, snapshot.Size, hash);
                    }
                }
                else
                {
                    Reserve(source.Entry.Size);
                    using (FileStream stream = new FileStream(source.Handle, FileAccess.Read, FileProtocol.ChunkSize, false))
                    {
                        Write(tls, client, 0x47, FileProtocol.Accepted(source.Entry.Name, source.Entry.Size, "file", 0));
                        byte[] hash = SendFile(tls, client, stream, source.Entry.Size, null, source.Validate); ReadComplete(tls, client, source.Entry.Size, hash);
                    }
                }
            }
        }
        internal void Stop()
        {
            TcpClient owned;
            lock (gate)
            {
                if (isStopped) return; isStopped = true;
                entries.Clear(); exports.Dispose(); Array.Clear(token, 0, token.Length); stopped.Set(); owned = current;
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
