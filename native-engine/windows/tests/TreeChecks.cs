// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        private static int treeFixtures, treeTlsFixtures;
        private sealed class TreeFixture
        {
            internal readonly string Name, FolderName;
            internal readonly byte[][] Json, Data;
            internal readonly long Size;
            internal readonly byte[] Hash;
            internal int Count { get { return Json.Length; } }
            internal TreeFixture(string name, string folderName, byte[][] json, byte[][] data)
            {
                Name = name; FolderName = folderName; Json = json; Data = data;
                using (MemoryStream exact = new MemoryStream())
                {
                    for (int i = 0; i < json.Length; ++i)
                    {
                        byte[] length = new byte[4]; NativeProtocol.Put32(length, 0, (uint)json[i].Length);
                        exact.Write(length, 0, 4); exact.Write(json[i], 0, json[i].Length); exact.Write(data[i], 0, data[i].Length); Size += data[i].Length;
                    }
                    Hash = FileHash(exact.ToArray());
                }
            }
            internal void Write(Action<byte, byte[]> send)
            {
                for (int i = 0; i < Json.Length; ++i)
                {
                    send(0x4c, Json[i]); Dictionary<string, object> node = FileProtocol.Object(Json[i], "id", "parent", "name", "kind", "size");
                    if (FileProtocol.Kind(node) != "file") continue;
                    for (int offset = 0; offset < Data[i].Length; offset += FileProtocol.ChunkSize)
                    {
                        int count = Math.Min(FileProtocol.ChunkSize, Data[i].Length - offset); byte[] chunk = new byte[count + 8];
                        NativeProtocol.Put64(chunk, 0, (ulong)offset); Buffer.BlockCopy(Data[i], offset, chunk, 8, count); send(0x48, chunk);
                    }
                    send(0x49, FileProtocol.Finish(Data[i].Length, FileHash(Data[i])));
                }
                send(0x4d, FileProtocol.TreeEnd(Count, Size, Hash));
            }
        }
        private static TreeFixture[] FreshTrees()
        {
            byte[] text = Bytes("새 합성 폴더 · Native tree\n"), boundary = new byte[65541];
            for (int i = 0; i < boundary.Length; ++i) boundary[i] = (byte)(i * 17 + 3);
            return new TreeFixture[] {
                new TreeFixture("empty", "빈 폴더😀", new byte[0][], new byte[0][]),
                new TreeFixture("nested", "상자😀", new byte[][] {
                    FileTreeNode.Encode(1, 0, "문서", "folder", 0), FileTreeNode.Encode(2, 1, "한글😀.txt", "file", text.Length),
                    FileTreeNode.Encode(3, 1, "empty.bin", "file", 0), FileTreeNode.Encode(4, 0, "empty folder", "folder", 0)
                }, new byte[][] { new byte[0], text, new byte[0], new byte[0] }),
                new TreeFixture("boundary", "boundary folder", new byte[][] { FileTreeNode.Encode(1, 0, "boundary.bin", "file", boundary.Length) }, new byte[][] { boundary })
            };
        }
        private static void TreeChecks()
        {
            int fixturesBefore = fileFixtures, tlsBefore = fileTlsFixtures;
            stage = "tree-manifest"; TreeManifestChecks();
            stage = "tree-storage"; TreeStorageChecks();
            stage = "tree-source"; TreeSourceChecks();
            stage = "tree-tls-roundtrip"; TreeTlsRoundtrip();
            stage = "tree-tls-cancel-invalid"; TreeTlsCancelInvalid();
            stage = "tree-tls-late-publication"; TreeTlsLatePublication();
            stage = "tree-run-node-quota"; TreeTlsNodeQuota();
            stage = "tree-export-scopes"; TreeExportChecks();
            stage = "tree-export-tls"; TreeExportTls();
            treeFixtures = fileFixtures - fixturesBefore; treeTlsFixtures = fileTlsFixtures - tlsBefore;
            fileFixtures = fixturesBefore; fileTlsFixtures = tlsBefore;
        }
        private static void TreeManifestChecks()
        {
            ++fileFixtures;
            foreach (TreeFixture fixture in FreshTrees())
            {
                FileTreeManifest manifest = new FileTreeManifest(fixture.Count, fixture.Size);
                using (SHA256 hash = SHA256.Create())
                {
                    for (int i = 0; i < fixture.Count; ++i)
                    {
                        manifest.Add(fixture.Json[i]); FileTreeManifest.HashNode(hash, fixture.Json[i]);
                        hash.TransformBlock(fixture.Data[i], 0, fixture.Data[i].Length, fixture.Data[i], 0);
                    }
                    manifest.Complete(); hash.TransformFinalBlock(new byte[0], 0, 0); Check(NativeProtocol.Equal(hash.Hash, fixture.Hash));
                }
            }
            foreach (byte[] invalid in new byte[][] {
                FileTreeNode.Encode(0,0,"a","file",0), FileTreeNode.Encode(2,0,"a","file",0), FileTreeNode.Encode(1,1,"a","folder",0),
                FileTreeNode.Encode(1,2,"a","file",0), FileTreeNode.Encode(1,0,"../a","file",0), FileTreeNode.Encode(1,0,"a","link",0),
                FileTreeNode.Encode(1,0,"a","folder",1), Bytes("{\"id\":1,\"parent\":0,\"name\":\"a\",\"kind\":\"file\",\"size\":0,\"path\":\"x\"}") })
                FileReject(delegate { new FileTreeManifest(1, 1).Add(invalid); });
            FileTreeManifest leafParent = new FileTreeManifest(2, 0); leafParent.Add(FileTreeNode.Encode(1,0,"a","file",0));
            FileReject(delegate { leafParent.Add(FileTreeNode.Encode(2,1,"b","file",0)); });
            foreach (string alias in new string[] { "A", "a" })
            {
                FileTreeManifest siblings = new FileTreeManifest(2, 0); siblings.Add(FileTreeNode.Encode(1,0,"a","file",0));
                FileReject(delegate { siblings.Add(FileTreeNode.Encode(2,0,alias,"folder",0)); });
            }
            FileTreeManifest unicode = new FileTreeManifest(2, 0); unicode.Add(FileTreeNode.Encode(1,0,"é","file",0));
            FileReject(delegate { unicode.Add(FileTreeNode.Encode(2,0,"e\u0301","file",0)); });
            FileTreeManifest depth = new FileTreeManifest(17, 0);
            for (int i = 1; i <= 16; ++i) depth.Add(FileTreeNode.Encode(i,i-1,"d","folder",0));
            FileReject(delegate { depth.Add(FileTreeNode.Encode(17,16,"d","folder",0)); });
            FileReject(delegate { new FileTreeManifest(4097, 0); }); FileReject(delegate { new FileTreeManifest(0, 1).Complete(); });
            FileTreeManifest nodes = new FileTreeManifest(4096, 0);
            for (int i = 1; i <= 4096; ++i) nodes.Add(FileTreeNode.Encode(i,0,"n" + i,"file",0)); nodes.Complete();
            FileReject(delegate { nodes.Add(FileTreeNode.Encode(4097,0,"over","file",0)); });
            FileTreeManifest metadata = new FileTreeManifest(4096, 0); bool bounded = false;
            for (int i = 1; i <= 4096; ++i)
            {
                try { metadata.Add(FileTreeNode.Encode(i,0,new string('a',240) + i,"file",0)); }
                catch (FileTransferException error) { Check(error.Code == "quota"); bounded = true; break; }
            }
            Check(bounded);
        }
        private static void TreeStorageChecks()
        {
            ++fileFixtures;
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            using (FileSharedRoot root = new FileSharedRoot(new FileSharingOptions(temp.PathValue)))
            {
                foreach (TreeFixture fixture in FreshTrees())
                {
                    bool privateRoot = false;
                    using (FileTreePartial partial = root.CreateTree(fixture.Size, fixture.Count, delegate(SafeFileHandle h) { CheckEarliestPrivateHandle(h); privateRoot = true; }))
                    {
                        Check(privateRoot);
                        for (int i = 0; i < fixture.Count; ++i)
                        {
                            FileTreeNode node; FileStream stream = partial.Add(fixture.Json[i], out node);
                            if (stream != null) { CheckEarliestPrivateHandle(stream.SafeFileHandle); stream.Write(fixture.Data[i],0,fixture.Data[i].Length); }
                        }
                        partial.PreparePublication(); Check(partial.Publish(fixture.FolderName) == fixture.FolderName);
                    }
                    Check(Directory.Exists(Path.Combine(temp.PathValue, fixture.FolderName)));
                    using (FileTreePartial collision = root.CreateTree(0,0))
                    { collision.PreparePublication(); Check(collision.Publish(fixture.FolderName) == fixture.FolderName + " (1)"); }
                }
                string received = Path.Combine(temp.PathValue, "상자😀", "문서", "한글😀.txt");
                using (SafeFileHandle file = FileNative.CreateFile(received,FileNative.Read,FileShare.ReadWrite,IntPtr.Zero,3,FileNative.OpenReparse,IntPtr.Zero))
                using (SafeFileHandle zone = FileNative.ZoneStream(file,FileNative.Read,false))
                using (FileStream stream = new FileStream(zone,FileAccess.Read,1024,false))
                using (StreamReader reader = new StreamReader(stream)) Check(reader.ReadToEnd().Contains("ZoneId=3"));
                using (FileTreePartial partial = root.CreateTree(2,1))
                {
                    FileTreeNode node; partial.Add(FileTreeNode.Encode(1,0,"short","file",2),out node).WriteByte(1);
                    FileReject(partial.PreparePublication);
                }
                using (FileTreePartial partial = root.CreateTree(0,1)) { FileTreeNode node; partial.Add(FileTreeNode.Encode(1,0,"cancel","folder",0),out node); }
                Check(Directory.GetDirectories(temp.PathValue,".knot-*.part").Length == 0);
            }
        }
        private static void TreeSourceChecks()
        {
            ++fileFixtures;
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            {
                string folder = Path.Combine(temp.PathValue,"source"); Directory.CreateDirectory(folder); File.WriteAllText(Path.Combine(folder,"a"),"synthetic");
                using (FileExportSource root = FileExportSource.Capture(folder))
                using (FileTreeSource source = new FileTreeSource(root))
                {
                    Check(source.Nodes.Count == 1 && source.Size == Bytes("synthetic").Length); source.Validate();
                    bool mutated = false;
                    try { File.WriteAllText(Path.Combine(folder,"late"),"mutation"); mutated = true; } catch (IOException) { } catch (UnauthorizedAccessException) { }
                    if (mutated) FileReject(source.Validate); else source.Validate();
                }
                string hard = Path.Combine(folder,"hard"); Check(CreateHardLink(hard,Path.Combine(folder,"a"),IntPtr.Zero));
                using (FileExportSource root = FileExportSource.Capture(folder)) FileReject(delegate { using (FileTreeSource source = new FileTreeSource(root)) { } });
                File.Delete(hard);
                string junction = Path.Combine(folder,"junction"); MakeOwnedJunction(junction,temp.PathValue);
                using (FileExportSource root = FileExportSource.Capture(folder)) FileReject(delegate { using (FileTreeSource source = new FileTreeSource(root)) { } });
                Directory.Delete(junction);
                string nested = Path.Combine(temp.PathValue,"deep"); Directory.CreateDirectory(nested); string cursor = nested;
                for (int i = 0; i < 17; ++i) { cursor = Path.Combine(cursor,"d"); Directory.CreateDirectory(cursor); }
                using (FileExportSource root = FileExportSource.Capture(nested)) FileReject(delegate { using (FileTreeSource source = new FileTreeSource(root)) { } });
                string package = Path.Combine(temp.PathValue,"Synthetic.app"); Directory.CreateDirectory(package); FileReject(delegate { using (FileExportSource source = FileExportSource.Capture(package)) { } });
            }
        }
        private static string PutTree(FileServer server, string pin, TreeFixture fixture)
        {
            using (FileTlsClient client = new FileTlsClient(server.Port,pin))
            {
                client.Authorize(server.Token); client.Send(0x4b,FileProtocol.TreeOffer(fixture.FolderName,fixture.Size,fixture.Count));
                FilePacket accepted = client.Read(); Check(accepted.Kind == 0x47);
                Dictionary<string,object> a = FileProtocol.Object(accepted.Payload,"name","size","kind","count");
                Check(FileProtocol.Kind(a) == "folder" && FileProtocol.Count(a,"count",4096) == fixture.Count && FileProtocol.Size(a,"size") == fixture.Size);
                fixture.Write(client.Send); FilePacket complete = client.Read(); Check(complete.Kind == 0x4a);
                Dictionary<string,object> result = FileProtocol.Object(complete.Payload,"name","size","sha256");
                Check(FileProtocol.Size(result,"size") == fixture.Size && FileProtocol.Text(result,"sha256") == FileProtocol.Hex(fixture.Hash)); return FileProtocol.Text(result,"name");
            }
        }
        private static void GetTree(FileServer server, string pin, Dictionary<string,object> entry)
        {
            using (FileTlsClient client = new FileTlsClient(server.Port,pin))
            using (SHA256 hash = SHA256.Create())
            {
                client.Authorize(server.Token); client.Send(0x46,FileProtocol.Json("{\"entry\":" + StrictJson.Quote(FileProtocol.Text(entry,"entry")) + "}"));
                FilePacket accepted = client.Read(); Check(accepted.Kind == 0x47);
                Dictionary<string,object> a = FileProtocol.Object(accepted.Payload,"name","size","kind","count");
                int count = FileProtocol.Count(a,"count",4096); long size = FileProtocol.Size(a,"size"); Check(FileProtocol.Kind(a) == "folder");
                FileTreeManifest manifest = new FileTreeManifest(count,size);
                for (int i = 0; i < count; ++i)
                {
                    FilePacket packet = client.Read(); Check(packet.Kind == 0x4c); FileTreeNode node = manifest.Add(packet.Payload); FileTreeManifest.HashNode(hash,packet.Payload);
                    if (node.Kind != "file") continue;
                    using (MemoryStream content = new MemoryStream())
                    {
                        for (;;)
                        {
                            packet = client.Read();
                            if (packet.Kind == 0x49)
                            {
                                byte[] digest = new byte[32]; Buffer.BlockCopy(packet.Payload,8,digest,0,32);
                                Check(content.Length == node.Size && FileProtocol.U64(packet.Payload,0) == (ulong)node.Size && NativeProtocol.Equal(digest,FileHash(content.ToArray()))); break;
                            }
                            Check(packet.Kind == 0x48 && FileProtocol.U64(packet.Payload,0) == (ulong)content.Length);
                            content.Write(packet.Payload,8,packet.Payload.Length-8); hash.TransformBlock(packet.Payload,8,packet.Payload.Length-8,packet.Payload,8);
                        }
                    }
                }
                manifest.Complete(); hash.TransformFinalBlock(new byte[0],0,0); FilePacket end = client.Read(); Check(end.Kind == 0x4d);
                Dictionary<string,object> result = FileProtocol.Object(end.Payload,"count","size","sha256");
                Check(FileProtocol.Count(result,"count",4096) == count && FileProtocol.Size(result,"size") == size && FileProtocol.Text(result,"sha256") == FileProtocol.Hex(hash.Hash));
                client.Send(0x4a,FileProtocol.Complete(FileProtocol.Text(entry,"name"),size,hash.Hash));
            }
        }
        private static void TreeTlsRoundtrip()
        {
            ++fileFixtures;
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            using (RunCertificate cert = new RunCertificate())
            using (FileServer server = NewFileServer(temp.PathValue,cert,new object(),delegate { return true; }))
            {
                foreach (TreeFixture fixture in FreshTrees())
                {
                    Check(PutTree(server,cert.Pin,fixture) == fixture.FolderName); Check(PutTree(server,cert.Pin,fixture) == fixture.FolderName + " (1)");
                    Dictionary<string,object> entry = FindFile(server,cert.Pin,fixture.FolderName); Check(entry != null && FileProtocol.Kind(entry) == "folder" && FileProtocol.Size(entry,"size") == 0);
                    GetTree(server,cert.Pin,entry);
                }
                Check(Directory.GetDirectories(temp.PathValue,".knot-*.part").Length == 0);
            }
        }
        private static void WaitNoTrees(string folder)
        {
            Stopwatch budget = Stopwatch.StartNew();
            while (Directory.GetDirectories(folder,".knot-*.part").Length != 0 && budget.ElapsedMilliseconds < 3000) Thread.Sleep(10);
            Check(Directory.GetDirectories(folder,".knot-*.part").Length == 0);
        }
        private static void TreeTlsCancelInvalid()
        {
            ++fileFixtures;
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            using (RunCertificate cert = new RunCertificate())
            using (FileServer server = NewFileServer(temp.PathValue,cert,new object(),delegate { return true; }))
            {
                using (FileTlsClient client = new FileTlsClient(server.Port,cert.Pin))
                { client.Authorize(server.Token); client.Send(0x4b,FileProtocol.TreeOffer("cancelled",0,1)); Check(client.Read().Kind == 0x47); client.Send(0x4c,FileTreeNode.Encode(1,0,"d","folder",0)); }
                WaitNoTrees(temp.PathValue);
                using (FileTlsClient client = new FileTlsClient(server.Port,cert.Pin))
                {
                    client.Authorize(server.Token); client.Send(0x4b,FileProtocol.TreeOffer("invalid",0,1)); Check(client.Read().Kind == 0x47);
                    client.Send(0x4c,FileTreeNode.Encode(1,1,"d","folder",0)); Check(client.Read().Kind == 0x7f);
                }
                WaitNoTrees(temp.PathValue);
                using (FileTlsClient client = new FileTlsClient(server.Port,cert.Pin))
                {
                    client.Authorize(server.Token); client.Send(0x4b,FileProtocol.TreeOffer("bad-hash",0,0)); Check(client.Read().Kind == 0x47);
                    client.Send(0x4d,FileProtocol.TreeEnd(0,0,new byte[32])); Check(client.Read().Kind == 0x7f);
                }
                WaitNoTrees(temp.PathValue); Check(Directory.GetFileSystemEntries(temp.PathValue).Length == 0 && server.ReservedNodes == 5);
            }
        }
        private static void TreeTlsLatePublication()
        {
            ++fileFixtures; object gate = new object(); bool active = true;
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            using (RunCertificate cert = new RunCertificate())
            using (ManualResetEvent reached = new ManualResetEvent(false))
            using (ManualResetEvent release = new ManualResetEvent(false))
            using (FileServer server = NewFileServer(temp.PathValue,cert,gate,delegate { return active; },delegate { reached.Set(); release.WaitOne(5000); }))
            {
                try
                {
                    using (FileTlsClient client = new FileTlsClient(server.Port,cert.Pin))
                    {
                        client.Authorize(server.Token); client.Send(0x4b,FileProtocol.TreeOffer("revoked",0,0)); Check(client.Read().Kind == 0x47);
                        client.Send(0x4d,FileProtocol.TreeEnd(0,0,FileHash(new byte[0]))); Check(reached.WaitOne(3000));
                        lock (gate) active = false; server.Stop(); release.Set();
                    }
                    WaitNoTrees(temp.PathValue); Check(!Directory.Exists(Path.Combine(temp.PathValue,"revoked")));
                }
                finally { release.Set(); }
            }
        }
        private static void TreeTlsNodeQuota()
        {
            ++fileFixtures;
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            using (RunCertificate cert = new RunCertificate())
            using (FileServer server = NewFileServer(temp.PathValue,cert,new object(),delegate { return true; }))
            {
                for (int i = 0; i < 2; ++i)
                {
                    using (FileTlsClient client = new FileTlsClient(server.Port,cert.Pin))
                    { client.Authorize(server.Token); client.Send(0x4b,FileProtocol.TreeOffer("cancel",0,4095)); Check(client.Read().Kind == 0x47); }
                    WaitNoTrees(temp.PathValue);
                }
                using (FileTlsClient client = new FileTlsClient(server.Port,cert.Pin))
                {
                    client.Authorize(server.Token); client.Send(0x45,FileProtocol.Metadata("over",0)); FilePacket error = client.Read();
                    Check(error.Kind == 0x7f && FileProtocol.Text(FileProtocol.Object(error.Payload,"code"),"code") == "quota");
                }
                Check(server.ReservedNodes == 8192 && Directory.GetFileSystemEntries(temp.PathValue).Length == 0);
            }
        }
        private static void TreeExportChecks()
        {
            ++fileFixtures; long now = 0; string nonce = new string('a',32);
            using (OwnedFileDirectory temp = new OwnedFileDirectory())
            using (FileExportRegistry exports = new FileExportRegistry(delegate { return now; }))
            {
                string chosen = Path.Combine(temp.PathValue,"chosen"), sibling = Path.Combine(temp.PathValue,"unselected"); File.WriteAllText(chosen,"fresh"); File.WriteAllText(sibling,"private synthetic sibling");
                List<FileEntrySnapshot> selected = exports.Add(nonce,new string[] { chosen }); Check(selected.Count == 1 && selected[0].Name == "chosen");
                using (FileExportSource source = exports.Claim(selected[0].Id)) Check(source != null && source.Entry.Name == "chosen"); Check(exports.Claim(selected[0].Id) == null);
                selected = exports.Add(nonce,new string[] { chosen }); exports.Revoke(new string('b',32));
                using (FileExportSource source = exports.Claim(selected[0].Id)) Check(source != null);
                selected = exports.Add(nonce,new string[] { chosen }); exports.Revoke(nonce); Check(exports.Claim(selected[0].Id) == null);
                selected = exports.Add(nonce,new string[] { chosen }); now = 60L * Stopwatch.Frequency; Check(exports.Claim(selected[0].Id) == null);
                FileReject(delegate { exports.Add(nonce,new string[0]); }); FileReject(delegate { exports.Add(nonce,new string[33]); });
                FileReject(delegate { exports.Add(nonce,new string[] { chosen, Path.Combine(temp.PathValue,"missing") }); });
                // Failure pins no earlier root and exposes no containing folder.
                File.WriteAllText(chosen,"unlocked after failed admission"); Check(File.ReadAllText(sibling) == "private synthetic sibling");
            }
        }
        private static Dictionary<string,object> CaptureOne(FileServer server,string pin,string nonce)
        {
            using (FileTlsClient client = new FileTlsClient(server.Port,pin))
            {
                client.Authorize(server.Token); client.Send(0x4e,FileProtocol.Json("{\"nonce\":" + StrictJson.Quote(nonce) + "}"));
                FilePacket entry = client.Read(); Check(entry.Kind == 0x43); Dictionary<string,object> result = FileProtocol.Object(entry.Payload,"entry","name","size","kind");
                FilePacket end = client.Read(); Check(end.Kind == 0x44); return result;
            }
        }
        private static void TreeExportTls()
        {
            ++fileFixtures; string nonce = new string('c',32); int captures = 0, cancellations = 0;
            using (OwnedFileDirectory shared = new OwnedFileDirectory())
            using (OwnedFileDirectory source = new OwnedFileDirectory())
            using (RunCertificate cert = new RunCertificate())
            {
                string selected = Path.Combine(source.PathValue,"selected.bin"); byte[] content = Bytes("synthetic selected bytes"); File.WriteAllBytes(selected,content);
                using (FileServer server = new FileServer(IPAddress.Loopback,IPAddress.Loopback,cert.Certificate,new FileSharingOptions(shared.PathValue),new object(),delegate { return true; },0,null,30000,
                    delegate(string value) { Check(value == nonce); ++captures; return new string[] { selected }; },delegate(string value) { Check(value == nonce); ++cancellations; }))
                {
                    server.Start(); Dictionary<string,object> entry = CaptureOne(server,cert.Pin,nonce); Check(FindFile(server,cert.Pin,"selected.bin") == null);
                    Check(NativeProtocol.Equal(GetFile(server,cert.Pin,entry),content));
                    using (FileTlsClient client = new FileTlsClient(server.Port,cert.Pin))
                    { client.Authorize(server.Token); client.Send(0x46,FileProtocol.Json("{\"entry\":" + StrictJson.Quote(FileProtocol.Text(entry,"entry")) + "}")); Check(client.Read().Kind == 0x7f); }
                    entry = CaptureOne(server,cert.Pin,nonce);
                    using (FileTlsClient client = new FileTlsClient(server.Port,cert.Pin))
                    { client.Authorize(server.Token); client.Send(0x4f,FileProtocol.Json("{\"nonce\":" + StrictJson.Quote(nonce) + "}")); }
                    using (FileTlsClient client = new FileTlsClient(server.Port,cert.Pin))
                    { client.Authorize(server.Token); client.Send(0x46,FileProtocol.Json("{\"entry\":" + StrictJson.Quote(FileProtocol.Text(entry,"entry")) + "}")); Check(client.Read().Kind == 0x7f); }
                    Check(captures == 2 && cancellations == 1);
                }
            }
        }
        private static void TreeWireVectors(Action<string,byte,byte[]> vector)
        {
            vector("tree-put",0x4b,FileProtocol.TreeOffer("빈 폴더😀",0,0)); vector("node",0x4c,FileTreeNode.Encode(1,0,"empty","folder",0));
            vector("tree-end",0x4d,FileProtocol.TreeEnd(0,0,FileHash(new byte[0])));
            byte[] nonce = FileProtocol.Json("{\"nonce\":\"0123456789abcdef0123456789abcdef\"}"); vector("capture",0x4e,nonce); vector("cancel",0x4f,nonce);
        }
        private static string TreeVectors()
        {
            List<string> values = new List<string>();
            foreach (TreeFixture fixture in FreshTrees())
            {
                List<string> nodes = new List<string>();
                for (int i = 0; i < fixture.Count; ++i) nodes.Add("{\"jsonBase64\":" + StrictJson.Quote(Convert.ToBase64String(fixture.Json[i])) + ",\"bytesBase64\":" + StrictJson.Quote(Convert.ToBase64String(fixture.Data[i])) + "}");
                using (MemoryStream stream = new MemoryStream())
                {
                    FileProtocol.Write(stream,0x47,FileProtocol.Accepted(fixture.FolderName,fixture.Size,"folder",fixture.Count));
                    fixture.Write(delegate(byte kind,byte[] bytes) { FileProtocol.Write(stream,kind,bytes); });
                    values.Add("{\"name\":" + StrictJson.Quote(fixture.Name) + ",\"folderName\":" + StrictJson.Quote(fixture.FolderName) + ",\"count\":" + fixture.Count +
                        ",\"size\":" + fixture.Size.ToString(CultureInfo.InvariantCulture) + ",\"sha256\":" + StrictJson.Quote(FileProtocol.Hex(fixture.Hash)) + ",\"nodes\":[" + string.Join(",",nodes) + "],\"encodedBase64\":" + StrictJson.Quote(Convert.ToBase64String(stream.ToArray())) + "}");
                }
            }
            return string.Join(",",values);
        }
    }
}
