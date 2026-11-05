// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        private static int fileFixtures, fileTlsFixtures, fileMediaTlsFixtures, fileEnrollmentFixtures, fileDiscoveryFixtures;
        private static void FileReject(Action action)
        {
            bool failed = false;
            try { action(); } catch (FileTransferException) { failed = true; }
            Check(failed);
        }
        private static void FileChecks()
        {
            stage = "file-wire"; FileWireChecks();
            stage = "file-storage"; FileStorageChecks();
            stage = "file-link-containment"; FileLinkChecks();
            stage = "file-tls-roundtrip"; FileTlsRoundTrip();
            stage = "file-tls-auth-source"; FileTlsAuthSource();
            stage = "file-tls-cancel-digest"; FileTlsCancelDigest();
            stage = "file-tls-revoke-commit"; FileTlsRevokeCommit();
            stage = "file-tls-quota"; FileTlsQuota();
            stage = "file-tls-slow-dribble"; FileTlsSlowDribble();
            stage = "file-enrollment-scopes"; FileEnrollmentScopes();
            stage = "file-host-consent"; FileHostConsent();
            stage = "file-windows-vectors"; FileVectors();
        }
        private static byte[] FileHash(byte[] bytes) { using (SHA256 hash = SHA256.Create()) return hash.ComputeHash(bytes); }
        private static void FileWireChecks()
        {
            foreach (string valid in new string[] { "a", "한글 문서.txt", "ordinary😀.bin", ".config", "שלום.txt", "résumé.txt" }) { FileProtocol.ValidName(valid); Check(true); }
            foreach (string invalid in new string[] { "", ".", "..", "../x", "a/b", "a\\b", "a:b", "file.", "file ", "CON", "nul.txt", "COM1.log", "Lpt².txt", ".knot-owned.part", "bad\0name", "a\nname", "invisible\u200bname", "line\u2028name", "<bad>", "a?b", "a*b", "a|b", "quote\"", new string('a', 256) }) FileReject(delegate { FileProtocol.ValidName(invalid); });
            FileProtocol.ValidName(new string('a', 255)); Check(true);
            foreach (byte kind in new byte[] { 0x40, 0x41, 0x43, 0x44, 0x45, 0x46, 0x47, 0x4a })
            {
                FileProtocol.Validate(kind, 1); FileProtocol.Validate(kind, 4096);
                FileReject(delegate { FileProtocol.Validate(kind, 0); }); FileReject(delegate { FileProtocol.Validate(kind, 4097); });
            }
            FileProtocol.Validate(0x42, 0); FileProtocol.Validate(0x48, 9); FileProtocol.Validate(0x48, 65544); FileProtocol.Validate(0x49, 40);
            FileReject(delegate { FileProtocol.Validate(0x48, 8); }); FileReject(delegate { FileProtocol.Validate(0x48, 65545); });
            FileReject(delegate { FileProtocol.Validate(0x49, 39); }); FileReject(delegate { FileProtocol.Validate(0x49, 41); });
            FileReject(delegate { FileProtocol.Validate(0x4b, 1); }); FileReject(delegate { FileProtocol.Validate(3, 100); });
            FileReject(delegate { FileProtocol.Read(new MemoryStream(new byte[] { 0x48, 0xff, 0xff, 0xff, 0xff })); });
            FileReject(delegate { FileProtocol.Object(Bytes("{\"name\":\"a\",\"name\":\"b\",\"size\":0}"), "name", "size"); });
            FileReject(delegate { FileProtocol.Object(Bytes("{\"name\":\"a\",\"size\":0,\"path\":\"x\"}"), "name", "size"); });
            FileReject(delegate { FileProtocol.Size(FileProtocol.Object(Bytes("{\"name\":\"a\",\"size\":8589934593}"), "name", "size"), "size"); });
            Check(FileProtocol.Size(FileProtocol.Object(FileProtocol.Metadata("a", FileProtocol.MaximumSize), "name", "size"), "size") == FileProtocol.MaximumSize);
            byte[] token = new byte[32]; bool requested;
            byte[] decoded; NativeProtocol.HelloName(Bytes("{\"v\":1,\"token\":" + StrictJson.Quote(NativeProtocol.Base64Url(token)) + ",\"name\":\"viewer\",\"filesVersion\":1}"), out decoded, out requested); Check(requested);
            Reject(delegate { NativeProtocol.HelloName(Bytes("{\"v\":1,\"token\":" + StrictJson.Quote(NativeProtocol.Base64Url(token)) + ",\"name\":\"viewer\",\"filesVersion\":2}"), out decoded, out requested); });
            byte[] slot = new byte[16]; bool files;
            EnrollmentProtocol.ConfirmName(Confirm(slot, "viewer"), slot, out files); Check(!files);
            EnrollmentProtocol.ConfirmName(Bytes("{\"v\":2,\"slot\":" + StrictJson.Quote(NativeProtocol.Base64Url(slot)) + ",\"name\":\"viewer\",\"permissions\":\"screen,input,files\"}"), slot, out files); Check(files);
        }
        private sealed class OwnedFileDirectory : IDisposable
        {
            internal readonly string PathValue = Path.Combine(Path.GetTempPath(), "KnotNativeFile_" + Guid.NewGuid().ToString("N"));
            internal OwnedFileDirectory() { Directory.CreateDirectory(PathValue); }
            public void Dispose() { if (Directory.Exists(PathValue)) Directory.Delete(PathValue, true); }
        }
        private static void FileStorageChecks()
        {
            ++fileFixtures;
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            using (FileSharedRoot root = new FileSharedRoot(new FileSharingOptions(temp.PathValue)))
            {
                byte[] bytes = Bytes("fresh synthetic bytes");
                string name;
                using (FilePartial partial = root.CreatePartial(bytes.Length))
                {
                    partial.Stream.Write(bytes, 0, bytes.Length); partial.PreparePublication(); name = partial.Publish("a");
                }
                Check(name == "a" && NativeProtocol.Equal(File.ReadAllBytes(Path.Combine(temp.PathValue, name)), bytes));
                Check((File.GetAttributes(Path.Combine(temp.PathValue, name)) & (FileAttributes.Hidden | FileAttributes.Temporary)) == 0);
                Check(File.ReadAllText(Path.Combine(temp.PathValue, name) + ":Zone.Identifier").Contains("ZoneId=3"));
                using (FilePartial partial = root.CreatePartial(0)) { partial.PreparePublication(); name = partial.Publish("a"); }
                Check(name == "a (1)" && File.ReadAllBytes(Path.Combine(temp.PathValue, "a")).Length == bytes.Length);
                using (FilePartial partial = root.CreatePartial(3)) partial.Stream.WriteByte(1);
                Check(Directory.GetFiles(temp.PathValue, ".knot-*.part").Length == 0);
                bool truncated; List<FileEntrySnapshot> values = root.List(out truncated); Check(!truncated && values.Count == 2);
                FileEntrySnapshot first = values.Find(delegate(FileEntrySnapshot v) { return v.Name == "a"; }); Check(first != null);
                FileHandleInfo actual; using (FileStream source = root.OpenRead(first.Name, out actual)) Check(first.Info.Same(actual));
                File.WriteAllText(Path.Combine(temp.PathValue, first.Name), "changed");
                using (FileStream source = root.OpenRead(first.Name, out actual)) Check(!first.Info.Same(actual));
                for (int i = 0; i < 260; ++i) File.WriteAllBytes(Path.Combine(temp.PathValue, "entry-" + i + ".bin"), new byte[0]);
                Check(root.List(out truncated).Count == FileProtocol.EntryLimit && truncated);
            }
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateHardLink(string target, string source, IntPtr reserved);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(SafeFileHandle device, uint code, byte[] input, uint inputLength, IntPtr output, uint outputLength, out uint returned, IntPtr overlapped);
        private static void MakeOwnedJunction(string link, string target)
        {
            Directory.CreateDirectory(link);
            byte[] substitute = Encoding.Unicode.GetBytes("\\??\\" + target), print = Encoding.Unicode.GetBytes(target);
            byte[] data = new byte[16 + substitute.Length + 2 + print.Length + 2];
            Buffer.BlockCopy(BitConverter.GetBytes(0xA0000003u), 0, data, 0, 4);
            Buffer.BlockCopy(BitConverter.GetBytes((ushort)(data.Length - 8)), 0, data, 4, 2);
            Buffer.BlockCopy(BitConverter.GetBytes((ushort)substitute.Length), 0, data, 10, 2);
            Buffer.BlockCopy(BitConverter.GetBytes((ushort)(substitute.Length + 2)), 0, data, 12, 2);
            Buffer.BlockCopy(BitConverter.GetBytes((ushort)print.Length), 0, data, 14, 2);
            Buffer.BlockCopy(substitute, 0, data, 16, substitute.Length); Buffer.BlockCopy(print, 0, data, 18 + substitute.Length, print.Length);
            using (SafeFileHandle handle = FileNative.CreateFile(link, FileNative.Write, FileShare.ReadWrite, IntPtr.Zero, 3, FileNative.Backup | FileNative.OpenReparse, IntPtr.Zero))
            { uint returned; Check(!handle.IsInvalid && DeviceIoControl(handle, 0x000900A4, data, (uint)data.Length, IntPtr.Zero, 0, out returned, IntPtr.Zero)); }
        }
        private static void FileLinkChecks()
        {
            ++fileFixtures;
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            using (OwnedFileDirectory outside = new OwnedFileDirectory())
            {
                string sentinel = Path.Combine(outside.PathValue, "sentinel.bin"), linked = Path.Combine(temp.PathValue, "linked.bin");
                File.WriteAllBytes(sentinel, Bytes("fresh outside sentinel")); Check(CreateHardLink(linked, sentinel, IntPtr.Zero));
                using (FileSharedRoot root = new FileSharedRoot(new FileSharingOptions(temp.PathValue)))
                {
                    FileReject(delegate { FileHandleInfo info; using (FileStream input = root.OpenRead("linked.bin", out info)) { } });
                    bool truncated; Check(root.List(out truncated).Count == 0);
                }
                File.Delete(linked);
                string junction = Path.Combine(temp.PathValue, "junction"); MakeOwnedJunction(junction, outside.PathValue);
                try { FileReject(delegate { using (FileSharedRoot root = new FileSharedRoot(new FileSharingOptions(junction))) { } }); }
                finally { Directory.Delete(junction, false); }
                Check(File.ReadAllText(sentinel) == "fresh outside sentinel");
            }
        }
        private sealed class FileTlsClient : IDisposable
        {
            internal readonly TcpClient Client;
            internal readonly SslStream Stream;
            internal FileTlsClient(int port, string pin, IPAddress source = null)
            {
                Client = new TcpClient(AddressFamily.InterNetwork);
                if (source != null) Client.Client.Bind(new IPEndPoint(source, 0));
                try
                {
                    Client.Connect(IPAddress.Loopback, port); Client.NoDelay = true; Client.ReceiveTimeout = Client.SendTimeout = 5000;
                    Stream = new SslStream(Client.GetStream(), false, delegate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) { return RunCertificate.VerifyPinned(cert, errors, pin); });
                    Stream.ReadTimeout = Stream.WriteTimeout = 5000;
                    Stream.AuthenticateAsClient("knot-native", new X509CertificateCollection(), SslProtocols.Tls12, false); ++fileTlsFixtures;
                }
                catch { Client.Close(); throw; }
            }
            internal FilePacket Read() { return FileProtocol.Read(Stream); }
            internal void Send(byte kind, byte[] bytes) { FileProtocol.Write(Stream, kind, bytes); }
            internal void Authorize(string token)
            { Send(0x40, FileProtocol.Hello(NativeProtocol.DecodeToken(token))); Check(Read().Kind == 0x41); }
            public void Dispose() { try { if (Stream != null) Stream.Dispose(); } finally { Client.Close(); } }
        }
        private static FileServer NewFileServer(string folder, RunCertificate cert, object gate, Func<bool> active, Action beforePublish = null)
        {
            FileServer server = new FileServer(IPAddress.Loopback, IPAddress.Loopback, cert.Certificate, new FileSharingOptions(folder), gate, active, 0, beforePublish);
            server.Start(); return server;
        }
        private static string PutFile(FileServer server, string pin, string name, byte[] bytes, bool corrupt = false)
        {
            using (FileTlsClient client = new FileTlsClient(server.Port, pin))
            {
                client.Authorize(server.Token); client.Send(0x45, FileProtocol.Metadata(name, bytes.Length)); Check(client.Read().Kind == 0x47);
                WriteFileData(client, bytes); byte[] hash = FileHash(bytes); if (corrupt) hash[0] ^= 1;
                client.Send(0x49, FileProtocol.Finish(bytes.Length, hash)); FilePacket complete = client.Read();
                if (corrupt) { Check(complete.Kind == 0x7f && FileProtocol.Text(FileProtocol.Object(complete.Payload, "code"), "code") == "changed"); return null; }
                Check(complete.Kind == 0x4a); Dictionary<string, object> body = FileProtocol.Object(complete.Payload, "name", "size", "sha256");
                Check(FileProtocol.Size(body, "size") == bytes.Length && FileProtocol.Text(body, "sha256") == FileProtocol.Hex(hash));
                return FileProtocol.Text(body, "name");
            }
        }
        private static void WriteFileData(FileTlsClient client, byte[] bytes)
        {
            for (int offset = 0; offset < bytes.Length; offset += FileProtocol.ChunkSize)
            {
                int count = Math.Min(FileProtocol.ChunkSize, bytes.Length - offset); byte[] data = new byte[8 + count];
                NativeProtocol.Put64(data, 0, (ulong)offset); Buffer.BlockCopy(bytes, offset, data, 8, count); client.Send(0x48, data);
            }
        }
        private static Dictionary<string, object> FindFile(FileServer server, string pin, string name)
        {
            using (FileTlsClient client = new FileTlsClient(server.Port, pin))
            {
                client.Authorize(server.Token); client.Send(0x42, new byte[0]); int count = 0; Dictionary<string, object> found = null;
                for (;;)
                {
                    FilePacket packet = client.Read();
                    if (packet.Kind == 0x44)
                    { Dictionary<string, object> end = FileProtocol.Object(packet.Payload, "count", "truncated"); Check(StrictJson.Integer(end, "count", 0, 256) == count); return found; }
                    Check(packet.Kind == 0x43); Dictionary<string, object> entry = FileProtocol.Object(packet.Payload, "entry", "name", "size");
                    Check(FileProtocol.Hex(FileProtocol.Text(entry, "entry"), 32)); ++count;
                    if (FileProtocol.Text(entry, "name") == name) found = entry;
                }
            }
        }
        private static byte[] GetFile(FileServer server, string pin, Dictionary<string, object> entry)
        {
            using (FileTlsClient client = new FileTlsClient(server.Port, pin))
            using (MemoryStream received = new MemoryStream())
            {
                client.Authorize(server.Token); client.Send(0x46, FileProtocol.Json("{\"entry\":" + StrictJson.Quote(FileProtocol.Text(entry, "entry")) + "}"));
                Check(client.Read().Kind == 0x47);
                for (;;)
                {
                    FilePacket packet = client.Read();
                    if (packet.Kind == 0x49)
                    {
                        byte[] bytes = received.ToArray(), hash = FileHash(bytes), offered = new byte[32]; Buffer.BlockCopy(packet.Payload, 8, offered, 0, 32);
                        Check(NativeProtocol.U64(packet.Payload, 0) == (ulong)bytes.Length && NativeProtocol.Equal(hash, offered));
                        client.Send(0x4a, FileProtocol.Complete(FileProtocol.Text(entry, "name"), bytes.Length, hash)); return bytes;
                    }
                    Check(packet.Kind == 0x48 && NativeProtocol.U64(packet.Payload, 0) == (ulong)received.Length);
                    received.Write(packet.Payload, 8, packet.Payload.Length - 8);
                }
            }
        }
        private static void FileTlsRoundTrip()
        {
            ++fileFixtures;
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            using (RunCertificate cert = new RunCertificate())
            using (FileServer server = NewFileServer(temp.PathValue, cert, new object(), delegate { return true; }))
            {
                byte[] bytes = new byte[65541]; for (int i = 0; i < bytes.Length; ++i) bytes[i] = (byte)(i * 17 + 3);
                Check(PutFile(server, cert.Pin, "한글😀.bin", bytes) == "한글😀.bin");
                Check(PutFile(server, cert.Pin, "한글😀.bin", Bytes("collision")) == "한글😀 (1).bin");
                Check(PutFile(server, cert.Pin, "empty.bin", new byte[0]) == "empty.bin");
                Dictionary<string, object> entry = FindFile(server, cert.Pin, "한글😀.bin"); Check(entry != null);
                Check(NativeProtocol.Equal(GetFile(server, cert.Pin, entry), bytes));
                Check(server.Reserved == bytes.Length * 2 + Bytes("collision").Length);
            }
        }
        private static void FileTlsAuthSource()
        {
            ++fileFixtures;
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            using (RunCertificate cert = new RunCertificate())
            using (FileServer server = NewFileServer(temp.PathValue, cert, new object(), delegate { return true; }))
            {
                using (FileTlsClient client = new FileTlsClient(server.Port, cert.Pin))
                { client.Send(0x40, FileProtocol.Hello(new byte[32])); FilePacket error = client.Read(); Check(error.Kind == 0x7f && FileProtocol.Text(FileProtocol.Object(error.Payload, "code"), "code") == "auth"); }
                bool rejected = false;
                try { using (FileTlsClient client = new FileTlsClient(server.Port, cert.Pin, IPAddress.Parse("127.0.0.2"))) { } }
                catch (Exception) { rejected = true; }
                Check(rejected && server.Reserved == 0 && Directory.GetFileSystemEntries(temp.PathValue).Length == 0);
            }
        }
        private static void WaitNoPartials(string folder)
        {
            Stopwatch budget = Stopwatch.StartNew();
            while (Directory.GetFiles(folder, ".knot-*.part").Length != 0 && budget.ElapsedMilliseconds < 3000) Thread.Sleep(10);
            Check(Directory.GetFiles(folder, ".knot-*.part").Length == 0);
        }
        private static void FileTlsCancelDigest()
        {
            ++fileFixtures;
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            using (RunCertificate cert = new RunCertificate())
            using (FileServer server = NewFileServer(temp.PathValue, cert, new object(), delegate { return true; }))
            {
                using (FileTlsClient client = new FileTlsClient(server.Port, cert.Pin))
                { client.Authorize(server.Token); client.Send(0x45, FileProtocol.Metadata("cancel.bin", 10)); Check(client.Read().Kind == 0x47); }
                WaitNoPartials(temp.PathValue); Check(!File.Exists(Path.Combine(temp.PathValue, "cancel.bin")));
                PutFile(server, cert.Pin, "bad-hash.bin", Bytes("bad digest fixture"), true);
                WaitNoPartials(temp.PathValue); Check(!File.Exists(Path.Combine(temp.PathValue, "bad-hash.bin")));
                Check(PutFile(server, cert.Pin, "retry.bin", Bytes("retry")) == "retry.bin");
            }
        }
        private static void FileTlsRevokeCommit()
        {
            ++fileFixtures; object gate = new object(); bool active = true;
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            using (RunCertificate cert = new RunCertificate())
            using (ManualResetEvent reached = new ManualResetEvent(false))
            using (ManualResetEvent release = new ManualResetEvent(false))
            using (FileServer server = NewFileServer(temp.PathValue, cert, gate, delegate { return active; }, delegate { reached.Set(); release.WaitOne(5000); }))
            {
                string token = server.Token;
                try
                {
                    using (FileTlsClient client = new FileTlsClient(server.Port, cert.Pin))
                    {
                        client.Authorize(token); client.Send(0x45, FileProtocol.Metadata("revoked.bin", 0)); Check(client.Read().Kind == 0x47);
                        client.Send(0x49, FileProtocol.Finish(0, FileHash(new byte[0]))); Check(reached.WaitOne(3000));
                        lock (gate) active = false; server.Stop(); release.Set();
                    }
                    WaitNoPartials(temp.PathValue); Check(!File.Exists(Path.Combine(temp.PathValue, "revoked.bin")));
                    FileReject(delegate { string ignored = server.Token; });
                }
                finally { release.Set(); }
            }
        }
        private static void FileTlsQuota()
        {
            ++fileFixtures;
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            using (RunCertificate cert = new RunCertificate())
            using (FileServer server = NewFileServer(temp.PathValue, cert, new object(), delegate { return true; }))
            {
                using (FileTlsClient client = new FileTlsClient(server.Port, cert.Pin))
                {
                    client.Authorize(server.Token); client.Send(0x45, FileProtocol.Metadata("reserve.bin", FileProtocol.MaximumSize));
                    FilePacket result = client.Read(); Check(result.Kind == 0x47 || result.Kind == 0x7f);
                    if (result.Kind == 0x7f) Check(FileProtocol.Text(FileProtocol.Object(result.Payload, "code"), "code") == "quota");
                }
                WaitNoPartials(temp.PathValue);
                using (FileTlsClient client = new FileTlsClient(server.Port, cert.Pin))
                { client.Authorize(server.Token); client.Send(0x45, FileProtocol.Metadata("over.bin", 1)); Check(client.Read().Kind == 0x7f); }
                Check(server.Reserved == FileProtocol.MaximumSize && !File.Exists(Path.Combine(temp.PathValue, "over.bin")));
            }
        }
        private static byte[] FileOptInHello(string token)
        { return Bytes("{\"v\":1,\"token\":" + StrictJson.Quote(token) + ",\"name\":\"Synthetic viewer\",\"filesVersion\":1}"); }
        private static void FileTlsSlowDribble()
        {
            ++fileFixtures;
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            using (RunCertificate cert = new RunCertificate())
            using (FileServer server = new FileServer(IPAddress.Loopback, IPAddress.Loopback, cert.Certificate,
                new FileSharingOptions(temp.PathValue), new object(), delegate { return true; }, 0, null, 150))
            {
                server.Start();
                using (FileTlsClient client = new FileTlsClient(server.Port, cert.Pin))
                {
                    client.Authorize(server.Token); bool ended = false; Stopwatch budget = Stopwatch.StartNew();
                    try
                    {
                        // Every byte arrives inside the socket timeout, but the
                        // whole header cannot outrun its single absolute budget.
                        foreach (byte value in new byte[] { 0x45, 0, 0, 0, 20 })
                        { client.Stream.WriteByte(value); client.Stream.Flush(); Thread.Sleep(80); }
                        client.Read();
                    }
                    catch (IOException) { ended = true; }
                    catch (ObjectDisposedException) { ended = true; }
                    Check(ended && budget.ElapsedMilliseconds < 2500 && Directory.GetFileSystemEntries(temp.PathValue).Length == 0);
                }
            }
        }
        private static void FileHostConsent()
        {
            ++fileFixtures;
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            {
                string oldRoot = Path.Combine(temp.PathValue, "old-client");
                using (HostServer server = new HostServer(IPAddress.Loopback, 0, new FakeMediaFactory(), new FakeInput(), true, null, false, Stopwatch.GetTimestamp, null, files: new FileSharingOptions(oldRoot)))
                {
                    server.ApprovalRequested = delegate { server.RespondToApproval(true); };
                    string token = Token(server); server.Start();
                    using (TlsClient client = new TlsClient(server, server.Pin))
                    { ++fileMediaTlsFixtures; client.Send(1, Hello(token)); Check(client.ReadNonHeartbeat().Kind == 2 && !Directory.Exists(oldRoot)); }
                    Check(server.WaitStopped(3000));
                }
                string rootPath = Path.Combine(temp.PathValue, "new-client");
                using (ManualResetEvent pending = new ManualResetEvent(false))
                using (HostServer server = new HostServer(IPAddress.Loopback, 0, new FakeMediaFactory(), new FakeInput(), true, null, false, Stopwatch.GetTimestamp, null, files: new FileSharingOptions(rootPath)))
                {
                    server.ApprovalRequested = delegate { pending.Set(); };
                    string token = Token(server); server.Start();
                    using (TlsClient client = new TlsClient(server, server.Pin))
                    {
                        ++fileMediaTlsFixtures;
                        client.Send(1, FileOptInHello(token)); Check(pending.WaitOne(3000) && !Directory.Exists(rootPath));
                        server.RespondToApproval(true); Packet ready = client.ReadNonHeartbeat(); Check(ready.Kind == 2 && Directory.Exists(rootPath));
                        Dictionary<string, object> metadata = StrictJson.Parse(ready.Payload, "v", "codec", "width", "height", "fps", "bitrate", "hardwareEncoder", "filesVersion", "filePort", "fileToken", "fileRootName");
                        Check(StrictJson.Integer(metadata, "filesVersion", 1, 1) == 1 && StrictJson.Integer(metadata, "filePort", 48634, 48634) == 48634);
                        using (FileTlsClient files = new FileTlsClient(48634, server.Pin))
                        { files.Authorize(StrictJson.String(metadata, "fileToken")); files.Send(0x42, new byte[0]); Check(files.Read().Kind == 0x44); }
                        Check(server.IsActive); server.Stop(); Check(server.WaitStopped(3000));
                    }
                }
            }
        }
        private static void FileEnrollmentScopes()
        {
            ++fileFixtures;
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            {
                // File access requires all three independent gates: this local
                // folder, authenticated PAKE scope, and the later Hello opt-in.
                for (int index = 0; index < 4; ++index)
                {
                    bool requested = index != 0, local = index != 2, helloOptIn = index != 3;
                    bool expected = requested && local && helloOptIn;
                    string folder = Path.Combine(temp.PathValue, "scope-" + index);
                    using (HostServer server = new HostServer(IPAddress.Loopback, 0, new FakeMediaFactory(), new FakeInput(), true, null,
                        true, Stopwatch.GetTimestamp, "Synthetic Windows", files: local ? new FileSharingOptions(folder) : null))
                    {
                        server.Start(); byte[] slot = Discover(server, true);
                        string offered = Enroll(server, slot, server.EnrollmentCode, false, requested, true);
                        Dictionary<string, object> invitation = InvitationObject(offered);
                        using (TlsClient client = new TlsClient(server, server.Pin))
                        {
                            ++fileMediaTlsFixtures; string token = StrictJson.String(invitation, "token");
                            client.Send(1, helloOptIn ? FileOptInHello(token) : Hello(token)); Packet ready = client.ReadNonHeartbeat(); Check(ready.Kind == 2);
                            if (expected)
                            {
                                StrictJson.Parse(ready.Payload, "v", "codec", "width", "height", "fps", "bitrate", "hardwareEncoder", "filesVersion", "filePort", "fileToken", "fileRootName");
                                Check(Directory.Exists(folder));
                            }
                            else
                            {
                                StrictJson.Parse(ready.Payload, "v", "codec", "width", "height", "fps", "bitrate", "hardwareEncoder");
                                Check(!Directory.Exists(folder));
                            }
                            server.Stop(); Check(server.WaitStopped(3000));
                        }
                    }
                }
            }
        }
        private static void FileVectors()
        {
            if (certificateExportPath == null) return;
            List<string> vectors = new List<string>(); byte[] token = new byte[32];
            for (int i = 0; i < token.Length; ++i) token[i] = (byte)i;
            Action<string, byte, byte[]> vector = delegate(string name, byte kind, byte[] bytes)
            {
                using (MemoryStream stream = new MemoryStream())
                {
                    FileProtocol.Write(stream, kind, bytes);
                    vectors.Add("{\"name\":" + StrictJson.Quote(name) + ",\"kind\":" + kind + ",\"payloadBase64\":" + StrictJson.Quote(Convert.ToBase64String(bytes)) + ",\"encodedBase64\":" + StrictJson.Quote(Convert.ToBase64String(stream.ToArray())) + "}");
                }
            };
            byte[] emptyHash = FileHash(new byte[0]);
            vector("hello", 0x40, FileProtocol.Hello(token)); vector("authorized", 0x41, Bytes("{\"v\":1}")); vector("list", 0x42, new byte[0]);
            vector("entry", 0x43, Bytes("{\"entry\":\"0123456789abcdef0123456789abcdef\",\"name\":\"한글😀.txt\",\"size\":0}"));
            vector("list-end", 0x44, Bytes("{\"count\":1,\"truncated\":false}")); vector("put", 0x45, FileProtocol.Metadata("a", 0));
            vector("get", 0x46, Bytes("{\"entry\":\"0123456789abcdef0123456789abcdef\"}")); vector("accepted", 0x47, FileProtocol.Metadata("a", 0));
            vector("chunk", 0x48, new byte[9]); vector("finish", 0x49, FileProtocol.Finish(0, emptyHash)); vector("complete", 0x4a, FileProtocol.Complete("a", 0, emptyHash)); vector("error", 0x7f, FileProtocol.Error("denied"));
            byte[] boundary = new byte[65541]; for (int i = 0; i < boundary.Length; ++i) boundary[i] = (byte)(i * 17 + 3);
            byte[][] contents = new byte[][] { new byte[0], Bytes("새 합성 파일 · Native transfer\n"), boundary };
            string[] names = { "empty.bin", "한글😀.txt", "boundary.bin" }; List<string> files = new List<string>(), transfers = new List<string>();
            for (int i = 0; i < contents.Length; ++i)
            {
                byte[] bytes = contents[i], digest = FileHash(bytes); string hash = FileProtocol.Hex(digest), encoded;
                using (MemoryStream stream = new MemoryStream())
                {
                    FileProtocol.Write(stream, 0x47, FileProtocol.Metadata(names[i], bytes.Length));
                    for (int offset = 0; offset < bytes.Length; offset += FileProtocol.ChunkSize)
                    {
                        int count = Math.Min(FileProtocol.ChunkSize, bytes.Length - offset); byte[] payload = new byte[count + 8];
                        NativeProtocol.Put64(payload, 0, (ulong)offset); Buffer.BlockCopy(bytes, offset, payload, 8, count); FileProtocol.Write(stream, 0x48, payload);
                    }
                    FileProtocol.Write(stream, 0x49, FileProtocol.Finish(bytes.Length, digest)); encoded = Convert.ToBase64String(stream.ToArray());
                }
                string prefix = "{\"name\":" + StrictJson.Quote(i == 0 ? "empty" : i == 1 ? "unicode" : "boundary") + ",\"fileName\":" + StrictJson.Quote(names[i]) + ",\"size\":" + bytes.Length + ",\"sha256\":" + StrictJson.Quote(hash) + ",\"bytesBase64\":" + StrictJson.Quote(Convert.ToBase64String(bytes));
                files.Add("{\"name\":" + StrictJson.Quote(names[i]) + ",\"size\":" + bytes.Length + ",\"sha256\":" + StrictJson.Quote(hash) + ",\"bytesBase64\":" + StrictJson.Quote(Convert.ToBase64String(bytes)) + "}");
                transfers.Add(prefix + ",\"encodedBase64\":" + StrictJson.Quote(encoded) + "}");
            }
            string json = "{\"schema\":1,\"status\":\"passed\",\"freshSyntheticOnly\":true,\"actualCapture\":false,\"actualInput\":false,\"vectors\":[" + string.Join(",", vectors) + "],\"files\":[" + string.Join(",", files) + "],\"transfers\":[" + string.Join(",", transfers) + "]}";
            string path = Path.Combine(Path.GetDirectoryName(certificateExportPath), "native-file-vectors.json");
            using (FileStream output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            { byte[] bytes = Bytes(json); output.Write(bytes, 0, bytes.Length); output.Flush(true); }
        }
    }
}
