// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Knot.NativePreview
{
    internal sealed class FileTreeNode
    {
        internal readonly int Id, Parent, Depth;
        internal readonly string Name, Kind;
        internal readonly long Size;
        internal readonly byte[] Json;
        internal FileTreeNode(int id, int parent, string name, string kind, long size, int depth, byte[] json)
        { Id = id; Parent = parent; Name = name; Kind = kind; Size = size; Depth = depth; Json = json; }
        internal static byte[] Encode(int id, int parent, string name, string kind, long size)
        {
            return FileProtocol.Json("{\"id\":" + id.ToString(CultureInfo.InvariantCulture) + ",\"parent\":" + parent.ToString(CultureInfo.InvariantCulture) +
                ",\"name\":" + StrictJson.Quote(name) + ",\"kind\":" + StrictJson.Quote(kind) + ",\"size\":" + size.ToString(CultureInfo.InvariantCulture) + "}");
        }
    }
    internal sealed class FileTreeManifest
    {
        private readonly int expectedCount;
        private readonly long expectedSize;
        private int metadata;
        private long size;
        private readonly List<FileTreeNode> nodes = new List<FileTreeNode>();
        private readonly HashSet<string> siblings = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        internal int Count { get { return nodes.Count; } }
        internal long Size { get { return size; } }
        internal FileTreeManifest(int count, long size)
        {
            if (count < 0 || count > FileProtocol.TreeNodeLimit || size < 0 || size > FileProtocol.MaximumSize) throw new FileTransferException("quota");
            expectedCount = count; expectedSize = size;
        }
        internal FileTreeNode Add(byte[] bytes)
        {
            if (bytes == null || bytes.Length < 1 || bytes.Length > 4096 || nodes.Count == expectedCount || metadata > FileProtocol.TreeMetadataLimit - bytes.Length)
                throw new FileTransferException("quota");
            Dictionary<string, object> value = FileProtocol.Object(bytes, "id", "parent", "name", "kind", "size");
            int id = FileProtocol.Count(value, "id", FileProtocol.TreeNodeLimit), parent = FileProtocol.Count(value, "parent", FileProtocol.TreeNodeLimit);
            string name = FileProtocol.Text(value, "name"), kind = FileProtocol.Kind(value); FileProtocol.ValidName(name);
            FileExportSource.RejectPackage(name, kind == "folder");
            long length = FileProtocol.Size(value, "size");
            if (id != nodes.Count + 1 || parent >= id || parent > nodes.Count || parent > 0 && nodes[parent - 1].Kind != "folder" || kind == "folder" && length != 0)
                throw new FileTransferException("protocol");
            int depth = parent == 0 ? 1 : nodes[parent - 1].Depth + 1;
            if (depth > FileProtocol.TreeDepthLimit || size > expectedSize - length) throw new FileTransferException("quota");
            string key = parent.ToString(CultureInfo.InvariantCulture) + ":" + name.Normalize(NormalizationForm.FormC);
            if (!siblings.Add(key)) throw new FileTransferException("protocol");
            FileTreeNode node = new FileTreeNode(id, parent, name, kind, length, depth, bytes);
            nodes.Add(node); metadata += bytes.Length; size += length; return node;
        }
        internal void Complete() { if (Count != expectedCount || size != expectedSize) throw new FileTransferException("protocol"); }
        internal static void HashNode(HashAlgorithm hash, byte[] json)
        {
            byte[] length = new byte[4]; NativeProtocol.Put32(length, 0, (uint)json.Length);
            hash.TransformBlock(length, 0, length.Length, length, 0); hash.TransformBlock(json, 0, json.Length, json, 0);
        }
    }
    internal sealed class FileTreePartial : IDisposable
    {
        private sealed class Child
        {
            internal SafeFileHandle Handle;
            internal FileStream Stream;
            internal long Size;
            internal FileTreeNode Node;
            internal FileHandleInfo Identity;
        }
        private readonly FileSharedRoot root;
        private readonly string temporaryName;
        private readonly SafeFileHandle directory;
        private readonly FileTreeManifest manifest;
        private readonly List<Child> children = new List<Child>();
        private bool prepared, published, disposed;
        internal FileTreePartial(FileSharedRoot root, SafeFileHandle destination, int count, long size, Action<SafeFileHandle> firstHandle)
        {
            this.root = root; manifest = new FileTreeManifest(count, size); temporaryName = ".knot-" + Guid.NewGuid().ToString("N") + ".part";
            directory = FileNative.Relative(destination, temporaryName, FileNative.Read | FileNative.Write | FileNative.Delete,
                FileShare.ReadWrite, true, true, true, true);
            try { if (firstHandle != null) firstHandle(directory); root.Contained(directory, temporaryName); }
            catch { FileNative.DeleteOwned(directory); directory.Dispose(); throw; }
        }
        internal FileStream Add(byte[] json, out FileTreeNode node)
        {
            if (prepared || disposed) throw new FileTransferException("protocol"); node = manifest.Add(json);
            SafeFileHandle parent = node.Parent == 0 ? directory : children[node.Parent - 1].Handle;
            // The private root retains no-delete sharing. Descendants are
            // flushed and closed before the one directory rename, as required
            // by Windows; every later cleanup reopen verifies captured identity.
            SafeFileHandle handle = FileNative.Relative(parent, node.Name, FileNative.Read | FileNative.Write | FileNative.Delete,
                FileShare.ReadWrite | FileShare.Delete, true, node.Kind == "folder", true);
            Child child = new Child { Handle = handle, Size = node.Size, Node = node, Identity = new FileHandleInfo(FileNative.InfoAny(handle)) }; children.Add(child);
            try
            {
                if (node.Kind == "file")
                {
                    FileNative.MarkReceived(handle); child.Stream = new FileStream(handle, FileAccess.ReadWrite, 4096, false);
                }
                return child.Stream;
            }
            catch { throw; } // Dispose removes only the handles already owned.
        }
        internal void PreparePublication()
        {
            if (published || disposed) throw new FileTransferException("changed"); manifest.Complete();
            foreach (Child child in children)
            {
                if (child.Stream != null) { if (child.Stream.Length != child.Size) throw new FileTransferException("changed"); child.Stream.Flush(true); }
                FileHandleInfo actual = new FileHandleInfo(FileNative.InfoAny(child.Handle));
                if (!child.Identity.SameIdentity(actual) || !actual.Directory && actual.Size != child.Size) throw new FileTransferException("changed");
                child.Identity = actual;
                SafeFileHandle parent = child.Node.Parent == 0 ? directory : children[child.Node.Parent - 1].Handle;
                using (SafeFileHandle current = FileNative.Relative(parent, child.Node.Name, 0x80u, FileShare.ReadWrite | FileShare.Delete, false, actual.Directory, false))
                    if (!actual.SameIdentity(new FileHandleInfo(FileNative.InfoAny(current)))) throw new FileTransferException("changed");
            }
            // Retain only the pinned, receiver-private root across publication.
            // Other users cannot enter it. Hostile code running as this same
            // receiver remains outside FILES.md's in-process isolation scope.
            for (int i = children.Count - 1; i >= 0; --i) Close(children[i]);
            root.Contained(directory, temporaryName); FileNative.MakeVisible(directory); prepared = true;
        }
        internal string Publish(string name)
        {
            FileProtocol.ValidName(name);
            if (!prepared || published || disposed) throw new FileTransferException("changed"); root.Contained(directory, temporaryName);
            for (int i = 0; i < 32; ++i)
            {
                string candidate = FileTreeNames.Collision(name, i, true);
                if (root.Rename(directory, candidate)) { published = true; return candidate; }
            }
            throw new FileTransferException("io");
        }
        public void Dispose()
        {
            if (disposed) return; disposed = true;
            if (!published) ReopenOwnedChildren();
            for (int i = children.Count - 1; i >= 0; --i)
            {
                Child child = children[i]; if (!published) FileNative.DeleteOwned(child.Handle);
                Close(child);
            }
            if (!published) FileNative.DeleteOwned(directory); directory.Dispose();
        }
        private static void Close(Child child)
        {
            try { if (child.Stream != null) child.Stream.Dispose(); else if (child.Handle != null) child.Handle.Dispose(); }
            finally { child.Stream = null; child.Handle = null; }
        }
        private void ReopenOwnedChildren()
        {
            // Walk only names from this receiver's bounded manifest. A failed
            // identity check skips that node and its descendants; an unknown
            // replacement is never recursively removed or adopted as our own.
            foreach (Child child in children)
            {
                if (child.Handle != null && !child.Handle.IsClosed) continue;
                SafeFileHandle parent = child.Node.Parent == 0 ? directory : children[child.Node.Parent - 1].Handle;
                if (parent == null || parent.IsClosed || parent.IsInvalid) continue;
                SafeFileHandle reopened = null;
                try
                {
                    reopened = FileNative.Relative(parent, child.Node.Name, 0x80u | FileNative.Delete, FileShare.ReadWrite | FileShare.Delete,
                        false, child.Identity.Directory, false);
                    if (!child.Identity.SameIdentity(new FileHandleInfo(FileNative.InfoAny(reopened)))) continue;
                    child.Handle = reopened; reopened = null;
                }
                catch (FileTransferException) { }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
                finally { if (reopened != null) reopened.Dispose(); }
            }
        }
    }
    internal static class FileTreeNames
    {
        internal static string Collision(string name, int number, bool directory)
        {
            if (number == 0) return name;
            string extension = directory ? "" : Path.GetExtension(name), stem = directory ? name : Path.GetFileNameWithoutExtension(name);
            string suffix = " (" + (number < 11 ? number.ToString(CultureInfo.InvariantCulture) : Guid.NewGuid().ToString("N").Substring(0, 8)) + ")" + extension;
            while (stem.Length > 0 && StrictJson.Utf8.GetByteCount(stem + suffix) > 255)
            { stem = stem.Substring(0, stem.Length - (char.IsLowSurrogate(stem[stem.Length - 1]) ? 2 : 1)); }
            string result = stem + suffix; FileProtocol.ValidName(result); return result;
        }
    }
}
