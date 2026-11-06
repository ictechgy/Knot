// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace Knot.NativePreview
{
    // Only the OLE worker callback may construct an absolute-path export. Wire
    // requests address random IDs and can never select a path or a parent.
    internal sealed class FileExportSource : IDisposable
    {
        internal readonly SafeFileHandle Handle;
        internal readonly FileEntrySnapshot Entry;
        internal FileExportSource(SafeFileHandle handle, FileEntrySnapshot entry)
        {
            Handle = handle; Entry = entry;
            try
            {
                FileProtocol.ValidName(entry.Name);
                if (!entry.Info.Same(new FileHandleInfo(FileNative.InfoAny(handle)))) throw new FileTransferException("changed");
                RejectPackage(entry.Name, entry.Info.Directory);
            }
            catch { handle.Dispose(); throw; }
        }
        internal static FileExportSource Capture(string path)
        {
            if (string.IsNullOrEmpty(path) || !Path.IsPathRooted(path) || path.StartsWith("\\\\", StringComparison.Ordinal) || path.IndexOf('\0') >= 0 || path.Length > 32768)
                throw new FileTransferException("denied");
            string full = Path.GetFullPath(path).TrimEnd('\\', '/');
            string name = Path.GetFileName(full); FileProtocol.ValidName(name);
            string volume = Path.GetPathRoot(full);
            if (volume == null || volume.Length != 3 || volume[1] != ':') throw new FileTransferException("denied");
            SafeFileHandle handle = FileNative.CreateFile(volume, FileNative.Read, FileShare.ReadWrite, IntPtr.Zero, 3, FileNative.Backup | FileNative.OpenReparse, IntPtr.Zero);
            try
            {
                FileNative.Info(handle, true);
                string[] components = full.Substring(volume.Length).Split(new char[] { '\\', '/' });
                for (int i = 0; i < components.Length; ++i)
                {
                    SafeFileHandle next = FileNative.Relative(handle, components[i], FileNative.Read,
                        i == components.Length - 1 ? FileShare.Read : FileShare.ReadWrite, false,
                        i == components.Length - 1 ? (bool?)null : true, false);
                    handle.Dispose(); handle = next;
                }
                FileHandleInfo info = new FileHandleInfo(FileNative.InfoAny(handle));
                return new FileExportSource(handle, new FileEntrySnapshot(Guid.NewGuid().ToString("N"), name, info));
            }
            catch { handle.Dispose(); throw; }
        }
        internal static void RejectPackage(string name, bool directory)
        {
            if (!directory) return;
            foreach (string suffix in new string[] { ".app", ".bundle", ".framework", ".plugin", ".kext", ".appex" })
                if (name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) throw new FileTransferException("denied");
        }
        internal void Validate()
        { if (!Entry.Info.Same(new FileHandleInfo(FileNative.Info(Handle, Entry.Info.Directory)))) throw new FileTransferException("changed"); }
        public void Dispose() { Handle.Dispose(); }
    }
    internal sealed class FileTreeSource : IDisposable
    {
        internal sealed class Node
        {
            internal FileTreeNode Metadata;
            internal SafeFileHandle Handle;
            internal FileStream Stream;
            internal FileHandleInfo Info;
        }
        private readonly FileExportSource root;
        internal readonly List<Node> Nodes = new List<Node>();
        internal long Size { get; private set; }
        internal FileTreeSource(FileExportSource root)
        {
            this.root = root;
            try
            {
                if (!root.Entry.Info.Directory) throw new FileTransferException("protocol");
                FileTreeManifest bounded = new FileTreeManifest(FileProtocol.TreeNodeLimit, FileProtocol.MaximumSize);
                Scan(root.Handle, 0, bounded); Validate();
            }
            catch { Dispose(); throw; }
        }
        private void Scan(SafeFileHandle parent, int parentId, FileTreeManifest bounded)
        {
            List<string> names = FileNative.ChildNames(parent, FileProtocol.TreeNodeLimit - Nodes.Count);
            // Stable ordering makes freshly generated fixtures reproducible.
            names.Sort(StringComparer.Ordinal);
            foreach (string name in names)
            {
                FileProtocol.ValidName(name);
                if (Nodes.Count == FileProtocol.TreeNodeLimit) throw new FileTransferException("quota");
                SafeFileHandle child = FileNative.Relative(parent, name, FileNative.Read, FileShare.Read, false, null, false);
                Node item = null; bool added = false;
                try
                {
                    FileHandleInfo info = new FileHandleInfo(FileNative.InfoAny(child)); FileExportSource.RejectPackage(name, info.Directory);
                    byte[] json = FileTreeNode.Encode(Nodes.Count + 1, parentId, name, info.Directory ? "folder" : "file", info.Size);
                    FileTreeNode node = bounded.Add(json);
                    item = new Node { Metadata = node, Handle = child, Info = info };
                    if (!info.Directory) item.Stream = new FileStream(child, FileAccess.Read, 4096, false);
                    Nodes.Add(item); added = true; Size += info.Size;
                    if (info.Directory) Scan(child, node.Id, bounded);
                }
                catch { if (!added) { if (item != null && item.Stream != null) item.Stream.Dispose(); else child.Dispose(); } throw; }
            }
        }
        internal void Validate()
        {
            root.Validate();
            foreach (Node node in Nodes)
                if (!node.Info.Same(new FileHandleInfo(FileNative.Info(node.Handle, node.Info.Directory)))) throw new FileTransferException("changed");
        }
        public void Dispose() { for (int i = Nodes.Count - 1; i >= 0; --i) { if (Nodes[i].Stream != null) Nodes[i].Stream.Dispose(); else Nodes[i].Handle.Dispose(); } Nodes.Clear(); }
    }
    internal sealed class FileExportRegistry : IDisposable
    {
        private sealed class Export
        {
            internal string Nonce;
            internal long Expires;
            internal FileExportSource Source;
        }
        private readonly object gate = new object();
        private readonly Dictionary<string, Export> values = new Dictionary<string, Export>(StringComparer.Ordinal);
        private readonly Func<long> now;
        private readonly Timer expiry;
        private bool disposed;
        internal FileExportRegistry(Func<long> now = null)
        {
            this.now = now ?? Stopwatch.GetTimestamp;
            expiry = new Timer(delegate { lock (gate) { if (!disposed) Expire(); } }, null, 1000, 1000);
        }
        private void Expire()
        {
            long stamp = now(); List<string> stale = new List<string>();
            foreach (KeyValuePair<string, Export> pair in values) if (stamp >= pair.Value.Expires) stale.Add(pair.Key);
            foreach (string key in stale) { values[key].Source.Dispose(); values.Remove(key); }
        }
        internal List<FileEntrySnapshot> Add(string nonce, string[] paths)
        {
            if (!FileProtocol.Hex(nonce, 32) || paths == null || paths.Length < 1 || paths.Length > 32) throw new FileTransferException("denied");
            List<FileExportSource> opened = new List<FileExportSource>();
            try
            {
                foreach (string path in paths) opened.Add(FileExportSource.Capture(path));
                List<FileEntrySnapshot> entries = new List<FileEntrySnapshot>();
                lock (gate)
                {
                    if (disposed) throw new FileTransferException("auth"); Expire();
                    // One handoff can outlive its capture connection, but a new
                    // capture does not accumulate an unbounded set of handles.
                    if (values.Count + opened.Count > 32) throw new FileTransferException("busy");
                    long expires = now() + 60L * Stopwatch.Frequency;
                    foreach (FileExportSource source in opened)
                    { values.Add(source.Entry.Id, new Export { Nonce = nonce, Expires = expires, Source = source }); entries.Add(source.Entry); }
                    opened.Clear(); return entries;
                }
            }
            finally { foreach (FileExportSource source in opened) source.Dispose(); }
        }
        internal FileExportSource Claim(string id)
        {
            lock (gate)
            {
                if (disposed) throw new FileTransferException("auth"); Expire(); Export value;
                if (!values.TryGetValue(id, out value)) return null;
                values.Remove(id); return value.Source;
            }
        }
        internal void Revoke(string nonce)
        {
            lock (gate)
            {
                List<string> matching = new List<string>();
                foreach (KeyValuePair<string, Export> pair in values) if (pair.Value.Nonce == nonce) matching.Add(pair.Key);
                foreach (string key in matching) { values[key].Source.Dispose(); values.Remove(key); }
            }
        }
        public void Dispose()
        {
            lock (gate)
            {
                if (disposed) return; disposed = true;
                foreach (Export value in values.Values) value.Source.Dispose(); values.Clear(); expiry.Dispose();
            }
        }
    }
}
