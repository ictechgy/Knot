// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Knot.NativePreview
{
    internal sealed class FileSharingOptions
    {
        internal readonly string RootPath, RootName;
        internal static string DefaultRootPath
        { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "Knot Files"); } }
        internal FileSharingOptions(string rootPath)
        {
            if (string.IsNullOrWhiteSpace(rootPath)) throw new ArgumentException("Choose a local shared folder.");
            string full = Path.GetFullPath(rootPath);
            if (full.StartsWith("\\\\", StringComparison.Ordinal) || full.IndexOf('\0') >= 0) throw new ArgumentException("Choose a local shared folder.");
            RootPath = full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (RootPath.Length < 3) throw new ArgumentException("Choose a local shared folder.");
            string name = Path.GetFileName(RootPath);
            try { EnrollmentProtocol.ValidName(name); RootName = name; }
            catch (ProtocolException) { RootName = "공유 폴더"; }
        }
    }

    internal struct FileHandleInfo
    {
        internal readonly uint Volume, IndexHigh, IndexLow;
        internal readonly long Size;
        internal readonly ulong Modified;
        internal FileHandleInfo(FileNative.Information value)
        {
            Volume = value.VolumeSerialNumber; IndexHigh = value.FileIndexHigh; IndexLow = value.FileIndexLow;
            ulong size = ((ulong)value.FileSizeHigh << 32) | value.FileSizeLow;
            if (size > (ulong)FileProtocol.MaximumSize) throw new FileTransferException("quota");
            Size = (long)size; Modified = ((ulong)(uint)value.LastWriteTime.dwHighDateTime << 32) | (uint)value.LastWriteTime.dwLowDateTime;
        }
        internal bool Same(FileHandleInfo other)
        { return Volume == other.Volume && IndexHigh == other.IndexHigh && IndexLow == other.IndexLow && Size == other.Size && Modified == other.Modified; }
    }

    internal sealed class FileEntrySnapshot
    {
        internal readonly string Id, Name;
        internal readonly FileHandleInfo Info;
        internal long Size { get { return Info.Size; } }
        internal FileEntrySnapshot(string id, string name, FileHandleInfo info) { Id = id; Name = name; Info = info; }
    }

    internal static class FileNative
    {
        internal const uint Read = 0x80000000, Write = 0x40000000, Delete = 0x00010000;
        internal const uint OpenReparse = 0x00200000, Backup = 0x02000000;
        [StructLayout(LayoutKind.Sequential)]
        internal struct Information
        {
            internal uint FileAttributes;
            internal System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, LastAccessTime, LastWriteTime;
            internal uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern SafeFileHandle CreateFile(string name, uint access, FileShare share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            internal int Length;
            internal IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] internal bool InheritHandle;
        }
        // Supply a protected receiver-only DACL to CREATE_NEW itself. Tightening
        // an inherited DACL after creation cannot revoke an already opened handle.
        internal static SafeFileHandle CreatePrivate(string name, uint access, FileShare share, uint flags)
        {
            SecurityIdentifier user;
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) user = identity.User;
            if (user == null) throw new FileTransferException("denied");
            FileSecurity security = new FileSecurity(); security.SetOwner(user);
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl, AccessControlType.Allow));
            byte[] descriptor = security.GetSecurityDescriptorBinaryForm();
            GCHandle pinned = GCHandle.Alloc(descriptor, GCHandleType.Pinned);
            IntPtr attributes = IntPtr.Zero;
            try
            {
                SecurityAttributes value = new SecurityAttributes {
                    Length = Marshal.SizeOf(typeof(SecurityAttributes)),
                    SecurityDescriptor = pinned.AddrOfPinnedObject(), InheritHandle = false
                };
                attributes = Marshal.AllocHGlobal(value.Length);
                Marshal.StructureToPtr(value, attributes, false);
                SafeFileHandle result = CreateFile(name, access, share, attributes, 1, flags, IntPtr.Zero);
                if (result.IsInvalid)
                {
                    int error = Marshal.GetLastWin32Error(); result.Dispose();
                    throw new FileTransferException("denied", "file-open", error);
                }
                return result;
            }
            finally
            {
                if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
                pinned.Free(); Array.Clear(descriptor, 0, descriptor.Length);
            }
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Information info);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint GetFileType(SafeFileHandle handle);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int kind, IntPtr data, uint length);
        internal static string FinalPath(SafeFileHandle handle)
        {
            StringBuilder result = new StringBuilder(1024);
            uint size = GetFinalPathNameByHandle(handle, result, (uint)result.Capacity, 0);
            if (size >= result.Capacity)
            {
                if (size > 32768) throw new FileTransferException("denied");
                result = new StringBuilder((int)size + 1); size = GetFinalPathNameByHandle(handle, result, (uint)result.Capacity, 0);
            }
            if (size == 0 || size >= result.Capacity) throw new FileTransferException("denied", "file-path", Marshal.GetLastWin32Error());
            return result.ToString().TrimEnd('\\');
        }
        internal static Information Info(SafeFileHandle handle, bool directory)
        {
            Information result;
            if (handle.IsInvalid) throw new FileTransferException("denied", "file-open", Marshal.GetLastWin32Error());
            if (!GetFileInformationByHandle(handle, out result)) throw new FileTransferException("denied", "file-info", Marshal.GetLastWin32Error());
            if (GetFileType(handle) != 1 ||
                (result.FileAttributes & (uint)FileAttributes.ReparsePoint) != 0 ||
                ((result.FileAttributes & (uint)FileAttributes.Directory) != 0) != directory ||
                !directory && result.NumberOfLinks != 1) throw new FileTransferException("denied");
            return result;
        }
        internal static bool Rename(SafeFileHandle source, SafeFileHandle directory, string name)
        {
            FileProtocol.ValidName(name);
            if (IntPtr.Size != 8) throw new FileTransferException("denied");
            byte[] text = Encoding.Unicode.GetBytes(name);
            IntPtr memory = Marshal.AllocHGlobal(22 + text.Length);
            bool directoryReference = false;
            try
            {
                directory.DangerousAddRef(ref directoryReference);
                for (int i = 0; i < 22 + text.Length; ++i) Marshal.WriteByte(memory, i, 0);
                Marshal.WriteIntPtr(memory, 8, directory.DangerousGetHandle());
                Marshal.WriteInt32(memory, 16, text.Length); Marshal.Copy(text, 0, IntPtr.Add(memory, 20), text.Length);
                if (SetFileInformationByHandle(source, 3, memory, (uint)(22 + text.Length))) return true;
                int error = Marshal.GetLastWin32Error();
                if (error == 80 || error == 183) return false;
                throw new FileTransferException(error == 5 ? "denied" : "io", "file-rename", error);
            }
            finally { if (directoryReference) directory.DangerousRelease(); Marshal.FreeHGlobal(memory); }
        }
        internal static void DeleteOwned(SafeFileHandle file)
        {
            if (file == null || file.IsInvalid || file.IsClosed) return;
            IntPtr memory = Marshal.AllocHGlobal(1);
            try { Marshal.WriteByte(memory, 1); SetFileInformationByHandle(file, 4, memory, 1); }
            finally { Marshal.FreeHGlobal(memory); }
        }
        internal static void MakeVisible(SafeFileHandle file)
        {
            IntPtr memory = Marshal.AllocHGlobal(40);
            try
            {
                for (int i = 0; i < 40; ++i) Marshal.WriteByte(memory, i, 0);
                Marshal.WriteInt32(memory, 32, (int)FileAttributes.Normal);
                if (!SetFileInformationByHandle(file, 0, memory, 40)) throw new FileTransferException("io", "file-basic", Marshal.GetLastWin32Error());
            }
            finally { Marshal.FreeHGlobal(memory); }
        }
    }

    // A selected root is kept open without delete sharing. Every child is checked
    // against the root's actual handle path, not just a lexical string prefix.
    internal sealed class FileSharedRoot : IDisposable
    {
        private readonly FileSharingOptions options;
        private readonly SafeFileHandle directory;
        internal FileSharedRoot(FileSharingOptions options)
        {
            if (options == null) throw new ArgumentNullException("options");
            this.options = options;
            if (!Directory.Exists(options.RootPath))
            {
                DirectorySecurity acl = new DirectorySecurity();
                SecurityIdentifier user = WindowsIdentity.GetCurrent().User;
                if (user == null) throw new FileTransferException("denied");
                acl.SetAccessRuleProtection(true, false);
                acl.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
                Directory.CreateDirectory(options.RootPath, acl);
            }
            directory = FileNative.CreateFile(options.RootPath, 0x100083, FileShare.ReadWrite, IntPtr.Zero, 3, FileNative.Backup | FileNative.OpenReparse, IntPtr.Zero);
            try { FileNative.Info(directory, true); FileNative.FinalPath(directory); }
            catch { directory.Dispose(); throw; }
        }
        internal FileStream OpenRead(string name, out FileHandleInfo info)
        {
            FileProtocol.ValidName(name);
            SafeFileHandle handle = FileNative.CreateFile(Path.Combine(options.RootPath, name), FileNative.Read, FileShare.Read,
                IntPtr.Zero, 3, FileNative.OpenReparse, IntPtr.Zero);
            try
            {
                FileNative.Information native = FileNative.Info(handle, false); Contained(handle, name);
                info = new FileHandleInfo(native); return new FileStream(handle, FileAccess.Read, FileProtocol.ChunkSize, false);
            }
            catch { handle.Dispose(); throw; }
        }
        internal FileHandleInfo Info(FileStream stream, string name)
        { Contained(stream.SafeFileHandle, name); return new FileHandleInfo(FileNative.Info(stream.SafeFileHandle, false)); }
        internal List<FileEntrySnapshot> List(out bool truncated)
        {
            List<FileEntrySnapshot> result = new List<FileEntrySnapshot>(); truncated = false; int scanned = 0;
            foreach (string path in Directory.EnumerateFileSystemEntries(options.RootPath))
            {
                if (++scanned > 512) { truncated = true; break; }
                string name = Path.GetFileName(path);
                if (name.StartsWith(".knot-", StringComparison.OrdinalIgnoreCase)) continue;
                try
                {
                    FileHandleInfo info;
                    using (FileStream file = OpenRead(name, out info)) { }
                    if (result.Count == FileProtocol.EntryLimit) { truncated = true; break; }
                    result.Add(new FileEntrySnapshot(Guid.NewGuid().ToString("N"), name, info));
                }
                catch (FileTransferException) { }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            return result;
        }
        internal void Contained(SafeFileHandle file, string name)
        {
            FileNative.Info(directory, true);
            string expected = FileNative.FinalPath(directory) + "\\" + name;
            if (!string.Equals(FileNative.FinalPath(file), expected, StringComparison.OrdinalIgnoreCase)) throw new FileTransferException("denied");
        }
        internal FilePartial CreatePartial(long size, Action<SafeFileHandle> firstHandle = null)
        {
            if (size < 0 || size > FileProtocol.MaximumSize) throw new FileTransferException("quota");
            try
            {
                DriveInfo drive = new DriveInfo(Path.GetPathRoot(options.RootPath));
                if (drive.AvailableFreeSpace < size + 67108864L) throw new FileTransferException("quota");
            }
            catch (ArgumentException) { throw new FileTransferException("denied"); }
            return new FilePartial(this, options.RootPath, size, firstHandle);
        }
        internal bool Rename(SafeFileHandle source, string name) { FileNative.Info(directory, true); return FileNative.Rename(source, directory, name); }
        public void Dispose() { directory.Dispose(); }
    }

    internal sealed class FilePartial : IDisposable
    {
        private readonly FileSharedRoot root;
        private readonly string temporaryName;
        private readonly long size;
        private bool published, prepared;
        internal readonly FileStream Stream;
        internal FilePartial(FileSharedRoot root, string path, long size, Action<SafeFileHandle> firstHandle)
        {
            this.root = root; this.size = size; temporaryName = ".knot-" + Guid.NewGuid().ToString("N") + ".part";
            string temporary = Path.Combine(path, temporaryName);
            SafeFileHandle handle = FileNative.CreatePrivate(temporary, FileNative.Read | FileNative.Write | FileNative.Delete,
                FileShare.ReadWrite, FileNative.OpenReparse | (uint)FileAttributes.Hidden | (uint)FileAttributes.Temporary);
            try
            {
                // Inert regression fixtures may inspect the earliest native handle
                // before any stream, marker or later filesystem action exists.
                if (firstHandle != null) firstHandle(handle);
                FileNative.Info(handle, false); root.Contained(handle, temporaryName);
                Stream = new FileStream(handle, FileAccess.ReadWrite, FileProtocol.ChunkSize, false);
                // ADS belongs to our fresh exclusive partial, not a peer-supplied path.
                using (FileStream marker = new FileStream(temporary + ":Zone.Identifier", FileMode.CreateNew, FileAccess.Write, FileShare.ReadWrite))
                {
                    byte[] bytes = Encoding.ASCII.GetBytes("[ZoneTransfer]\r\nZoneId=3\r\nHostUrl=knot-native://transfer\r\n");
                    marker.Write(bytes, 0, bytes.Length); marker.Flush(true);
                }
            }
            catch
            {
                FileNative.DeleteOwned(handle); if (Stream != null) Stream.Dispose(); else handle.Dispose(); throw;
            }
        }
        internal void PreparePublication()
        {
            if (published || Stream.Length != size) throw new FileTransferException("changed");
            Stream.Flush(true); root.Contained(Stream.SafeFileHandle, temporaryName); FileNative.MakeVisible(Stream.SafeFileHandle);
            prepared = true;
        }
        internal string Publish(string name)
        {
            FileProtocol.ValidName(name);
            if (published || !prepared || Stream.Length != size) throw new FileTransferException("changed");
            root.Contained(Stream.SafeFileHandle, temporaryName);
            // No replacement flag is ever set; rename is relative to the pinned
            // directory handle and retains ownership of the open partial inode.
            for (int number = 0; number < 32; ++number)
            {
                string candidate = name;
                if (number > 0)
                {
                    string extension = Path.GetExtension(name), stem = Path.GetFileNameWithoutExtension(name);
                    string label = number < 11 ? number.ToString(System.Globalization.CultureInfo.InvariantCulture) : Guid.NewGuid().ToString("N").Substring(0, 8);
                    string suffix = " (" + label + ")" + extension;
                    while (stem.Length > 0 && StrictJson.Utf8.GetByteCount(stem + suffix) > 255)
                    {
                        int remove = char.IsLowSurrogate(stem[stem.Length - 1]) ? 2 : 1;
                        stem = stem.Substring(0, stem.Length - remove);
                    }
                    candidate = stem + suffix; FileProtocol.ValidName(candidate);
                }
                if (root.Rename(Stream.SafeFileHandle, candidate)) { published = true; return candidate; }
            }
            throw new FileTransferException("io");
        }
        public void Dispose()
        {
            if (Stream == null) return;
            if (!published) FileNative.DeleteOwned(Stream.SafeFileHandle);
            Stream.Dispose();
        }
    }
}
