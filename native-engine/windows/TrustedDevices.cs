// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;
using System.Threading;

namespace Knot.NativePreview
{
    // Only explicitly registered devices are persisted. Invitations and media/file
    // capabilities remain single-use; a fresh challenge is required on every use.
    internal static class NativeTrustedDevices
    {
        private static readonly object gate = new object();
        internal static string DirectoryPath { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Knot", "NativeTrust"); } }
        private static string StorePath { get { return Path.Combine(DirectoryPath, "devices.dpapi"); } }
        internal static void PrepareDirectory()
        {
            string path = DirectoryPath;
            Directory.CreateDirectory(path);
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("Trust storage cannot be linked.");
            DirectorySecurity security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            new DirectoryInfo(path).SetAccessControl(security);
        }
        internal static byte[] ReadProtected(string path)
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0 || new FileInfo(path).Length > 65536) throw new IOException("Invalid trust storage.");
            return ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.CurrentUser);
        }
        internal static void WriteProtected(string path, byte[] plain)
        {
            PrepareDirectory(); byte[] encrypted = ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser);
            string temporary = Path.Combine(DirectoryPath, Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                using (FileStream file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { file.Write(encrypted, 0, encrypted.Length); file.Flush(true); }
                if (File.Exists(path)) { if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("Invalid trust storage."); File.Replace(temporary, path, null); }
                else File.Move(temporary, path);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); Array.Clear(encrypted, 0, encrypted.Length); }
        }
        private static Dictionary<string, string[]> Load()
        {
            Dictionary<string, string[]> entries = new Dictionary<string, string[]>(StringComparer.Ordinal);
            if (!File.Exists(StorePath)) return entries;
            byte[] bytes = ReadProtected(StorePath);
            try
            {
                using (BinaryReader reader = new BinaryReader(new MemoryStream(bytes), Encoding.UTF8))
                {
                    if (reader.ReadInt32() != 1) throw new IOException("Unsupported trust storage.");
                    int count = reader.ReadInt32(); if (count < 0 || count > 16) throw new IOException("Invalid trust storage.");
                    for (int i = 0; i < count; ++i)
                    {
                        string id = reader.ReadString(), name = reader.ReadString(), key = reader.ReadString();
                        Validate(id, name, key); entries.Add(id, new string[] { name, key });
                    }
                    if (reader.BaseStream.Position != reader.BaseStream.Length) throw new IOException("Invalid trust storage.");
                }
                return entries;
            }
            finally { Array.Clear(bytes, 0, bytes.Length); }
        }
        private static void Save(Dictionary<string, string[]> entries)
        {
            using (MemoryStream stream = new MemoryStream())
            {
                using (BinaryWriter writer = new BinaryWriter(stream, Encoding.UTF8, true))
                {
                    writer.Write(1); writer.Write(entries.Count);
                    foreach (KeyValuePair<string, string[]> entry in entries) { writer.Write(entry.Key); writer.Write(entry.Value[0]); writer.Write(entry.Value[1]); }
                }
                byte[] bytes = stream.ToArray(); try { WriteProtected(StorePath, bytes); } finally { Array.Clear(bytes, 0, bytes.Length); }
            }
        }
        internal static void Validate(string id, string name, string key)
        { if (NativeProtocol.DecodeToken(id).Length != 32 || NativeProtocol.DecodeToken(key).Length != 32) throw new ProtocolException("auth"); EnrollmentProtocol.ValidName(name); }
        internal static void Add(string id, string name, string key)
        { lock (gate) { Validate(id, name, key); var entries = Load(); if (!entries.ContainsKey(id) && entries.Count >= 16) throw new ProtocolException("busy"); entries[id] = new string[] { name, key }; Save(entries); } }
        internal static byte[] Key(string id)
        { lock (gate) { var entries = Load(); string[] entry; if (!entries.TryGetValue(id, out entry)) throw new ProtocolException("auth"); return NativeProtocol.DecodeToken(entry[1]); } }
        internal static Dictionary<string, string> List()
        { lock (gate) { var entries = Load(); var result = new Dictionary<string, string>(); foreach (var item in entries) result.Add(item.Key, item.Value[0]); return result; } }
        internal static void Revoke(string id) { lock (gate) { var entries = Load(); if (entries.Remove(id)) Save(entries); } }
        internal static void RevokeAll() { lock (gate) { Save(new Dictionary<string, string[]>()); } }
        internal static byte[] Proof(byte[] key, string id, string nonce, string name, string pin, string operation = "connect")
        { using (HMACSHA256 hmac = new HMACSHA256(key)) return hmac.ComputeHash(Encoding.UTF8.GetBytes("KnotNativeTrusted:v1\n" + operation + "\n" + id + "\n" + nonce + "\n" + name + "\n" + pin)); }
    }

    internal sealed class TrustedDeviceServer : IDisposable
    {
        internal const int Port = 48635;
        private readonly TcpListener listener;
        private readonly Thread worker;
        private readonly X509Certificate2 certificate;
        private readonly string pin;
        private readonly Func<IPAddress, string, string, string, string, bool> register;
        private readonly Func<IPAddress, string, string> issue;
        private readonly Func<bool> authorize;
        private readonly Func<string, byte[]> lookupKey;
        private readonly Action<string> revoke;
        private readonly bool syntheticLoopback;
        internal int ListeningPort { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }
        private readonly object gate = new object();
        private bool stopped;
        private TcpClient client;
        internal TrustedDeviceServer(IPAddress address, X509Certificate2 certificate, string pin,
            Func<IPAddress, string, string, string, string, bool> register, Func<IPAddress, string, string> issue, Func<bool> authorize,
            bool syntheticLoopback = false, int port = Port, Func<string, byte[]> lookupKey = null, Action<string> revoke = null)
        {
            this.certificate = certificate; this.pin = pin; this.register = register; this.issue = issue; this.authorize = authorize;
            this.syntheticLoopback = syntheticLoopback;
            if (!NativeProtocol.IsPrivate(address) && !(syntheticLoopback && IPAddress.IsLoopback(address))) throw new ArgumentException("Choose private address.");
            if (port != Port && !syntheticLoopback) throw new ArgumentException("Invalid trusted port.");
            this.lookupKey = lookupKey ?? NativeTrustedDevices.Key; this.revoke = revoke ?? NativeTrustedDevices.Revoke;
            listener = new TcpListener(address, port); listener.Start(1);
            worker = new Thread(Run); worker.IsBackground = true; worker.Name = "Knot registered devices";
        }
        internal void Start() { worker.Start(); }
        private static Dictionary<string, object> Read(Stream stream, params string[] fields)
        {
            byte[] header = EnrollmentProtocol.ReadExact(stream, 5);
            int length = (header[1] << 24) | (header[2] << 16) | (header[3] << 8) | header[4];
            if (header[0] != 1 || length < 1 || length > 4096) throw new ProtocolException("protocol");
            return StrictJson.Parse(EnrollmentProtocol.ReadExact(stream, length), fields);
        }
        private static void Write(Stream stream, string json)
        {
            byte[] bytes = StrictJson.Utf8.GetBytes(json);
            if (bytes.Length < 1 || bytes.Length > 4096) throw new ProtocolException("protocol");
            byte[] header = new byte[5]; header[0] = 1; NativeProtocol.Put32(header, 1, (uint)bytes.Length);
            stream.Write(header, 0, header.Length); stream.Write(bytes, 0, bytes.Length);
        }
        private void Run()
        {
            while (true)
            {
                TcpClient accepted = null;
                try
                {
                    lock (gate) { if (stopped) return; }
                    accepted = listener.AcceptTcpClient();
                    IPAddress remote = ((IPEndPoint)accepted.Client.RemoteEndPoint).Address;
                    if (!NativeProtocol.IsPrivate(remote) && !(syntheticLoopback && IPAddress.IsLoopback(remote))) { accepted.Close(); continue; }
                    lock (gate) { if (stopped) { accepted.Close(); return; } client = accepted; }
                    accepted.NoDelay = true; accepted.ReceiveTimeout = 10000; accepted.SendTimeout = 10000;
                    using (ConnectionDeadline deadline = new ConnectionDeadline(10000, accepted.Close))
                    using (SslStream tls = new SslStream(accepted.GetStream(), false))
                    {
                        tls.AuthenticateAsServer(certificate, false, SslProtocols.Tls12, false);
                        var hello = Read(tls, "op", "id", "name", "value", "key");
                        string op = StrictJson.String(hello, "op"), id = StrictJson.String(hello, "id"), name = StrictJson.String(hello, "name");
                        string value = StrictJson.String(hello, "value"), keyText = StrictJson.String(hello, "key");
                        EnrollmentProtocol.ValidName(name);
                        if (op == "register")
                        {
                            NativeTrustedDevices.Validate(id, name, keyText);
                            if (!register(remote, value, id, name, keyText)) throw new ProtocolException("auth");
                            Write(tls, "{\"ok\":true}");
                        }
                        else if (op == "connect" || op == "revoke")
                        {
                            if (value != "" || keyText != "" || !authorize()) throw new ProtocolException("auth");
                            byte[] key = lookupKey(id);
                            try
                            {
                                string nonce = NativeProtocol.Base64Url(EnrollmentProtocol.Random(32));
                                Write(tls, "{\"nonce\":" + StrictJson.Quote(nonce) + "}");
                                var response = Read(tls, "proof");
                                byte[] expected = NativeTrustedDevices.Proof(key, id, nonce, name, pin, op);
                                if (!NativeProtocol.Equal(expected, NativeProtocol.DecodeToken(StrictJson.String(response, "proof")))) throw new ProtocolException("auth");
                                if (op == "revoke") { revoke(id); Write(tls, "{\"ok\":true}"); }
                                else { string invitation = issue(remote, name); Write(tls, "{\"invitation\":" + StrictJson.Quote(invitation) + "}"); }
                            }
                            finally { Array.Clear(key, 0, key.Length); }
                        }
                        else throw new ProtocolException("protocol");
                        deadline.TryComplete();
                    }
                }
                catch (Exception) { lock (gate) { if (stopped) return; } }
                finally { if (accepted != null) try { accepted.Close(); } catch { } lock (gate) { if (client == accepted) client = null; } }
            }
        }
        internal void Stop() { lock (gate) { if (stopped) return; stopped = true; listener.Stop(); if (client != null) client.Close(); } }
        public void Dispose() { Stop(); if (Thread.CurrentThread != worker && (worker.ThreadState & ThreadState.Unstarted) == 0) worker.Join(1500); }
    }
}
