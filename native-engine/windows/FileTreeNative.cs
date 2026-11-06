// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace Knot.NativePreview
{
    internal static partial class FileNative
    {
        [DllImport("ntdll.dll", ExactSpelling = true)]
        private static extern int NtCreateFile(out SafeFileHandle file, uint access, IntPtr attributes, IntPtr ioStatus,
            IntPtr allocation, uint fileAttributes, uint sharing, uint disposition, uint options, IntPtr ea, uint eaLength);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int kind, IntPtr data, uint size);
        internal static Information InfoAny(SafeFileHandle handle)
        {
            Information value;
            if (handle == null || handle.IsInvalid || !GetFileInformationByHandle(handle, out value))
                throw new FileTransferException("denied", "file-info", Marshal.GetLastWin32Error());
            return Info(handle, (value.FileAttributes & (uint)FileAttributes.Directory) != 0);
        }
        // OBJECT_ATTRIBUTES and UNICODE_STRING are explicitly laid out for the
        // x64 ABI. All pointed-to storage and the parent reference survive pending
        // native completion. A name is exactly one validated component.
        internal static SafeFileHandle Relative(SafeFileHandle parent, string name, uint access, FileShare sharing,
            bool create, bool? directory, bool receiverPrivate, bool staging = false)
        {
            if (IntPtr.Size != 8) throw new FileTransferException("denied");
            if (!staging) FileProtocol.ValidName(name);
            else if (name == null || !name.StartsWith(".knot-", StringComparison.Ordinal) || name.IndexOfAny(new char[] { '/', '\\', ':' }) >= 0)
                throw new FileTransferException("protocol");
            byte[] text = Encoding.Unicode.GetBytes(name);
            if (text.Length < 2 || text.Length > 510) throw new FileTransferException("protocol");
            IntPtr nameBuffer = IntPtr.Zero, unicode = IntPtr.Zero, attributes = IntPtr.Zero, iosb = IntPtr.Zero, acl = IntPtr.Zero;
            bool retained = false; SafeFileHandle result = null; SecurityIdentifier user = null;
            try
            {
                parent.DangerousAddRef(ref retained); Info(parent, true);
                nameBuffer = Marshal.AllocHGlobal(text.Length + 2); Marshal.Copy(text, 0, nameBuffer, text.Length); Marshal.WriteInt16(nameBuffer, text.Length, 0);
                unicode = Marshal.AllocHGlobal(16); Zero(unicode, 16);
                Marshal.WriteInt16(unicode, 0, (short)text.Length); Marshal.WriteInt16(unicode, 2, (short)(text.Length + 2)); Marshal.WriteIntPtr(unicode, 8, nameBuffer);
                if (receiverPrivate)
                {
                    using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) user = identity.User;
                    if (user == null) throw new FileTransferException("denied");
                    FileSecurity security = new FileSecurity(); security.SetOwner(user); security.SetAccessRuleProtection(true, false);
                    security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl, AccessControlType.Allow));
                    byte[] descriptor = security.GetSecurityDescriptorBinaryForm();
                    acl = Marshal.AllocHGlobal(descriptor.Length); Marshal.Copy(descriptor, 0, acl, descriptor.Length); Array.Clear(descriptor, 0, descriptor.Length);
                }
                attributes = Marshal.AllocHGlobal(48); Zero(attributes, 48);
                Marshal.WriteInt32(attributes, 0, 48); Marshal.WriteIntPtr(attributes, 8, parent.DangerousGetHandle());
                Marshal.WriteIntPtr(attributes, 16, unicode); Marshal.WriteInt32(attributes, 24, 0x40); Marshal.WriteIntPtr(attributes, 32, acl);
                iosb = Marshal.AllocHGlobal(16); Zero(iosb, 16); Marshal.WriteInt32(iosb, 0, 0x103);
                uint options = 0x00200020u | (directory.HasValue ? directory.Value ? 1u : 0x40u : 0u);
                int status = NtCreateFile(out result, access | 0x00120080u, attributes, iosb, IntPtr.Zero,
                    staging ? (uint)(FileAttributes.Hidden | (directory == true ? 0 : FileAttributes.Temporary)) : (uint)FileAttributes.Normal,
                    (uint)sharing, create ? 2u : 1u, options, IntPtr.Zero, 0);
                if (status == 0x103)
                {
                    // The handle is synchronous. Even a misbehaving driver may
                    // not cause us to free native request buffers while pending.
                    for (;;)
                    {
                        uint waited = result != null && !result.IsInvalid ? WaitForSingleObject(result, 1000) : 0x102;
                        Thread.MemoryBarrier(); int completed = Marshal.ReadInt32(iosb);
                        if (completed != 0x103 && (waited == 0 || result == null || result.IsInvalid)) { status = completed; break; }
                        if (waited == 0xffffffff && result != null && !result.IsInvalid) CancelIoEx(result, IntPtr.Zero);
                        if (waited != 0x102) Thread.Sleep(1);
                    }
                }
                if (status != 0)
                {
                    int error = unchecked((int)RtlNtStatusToDosError(status));
                    throw new FileTransferException(error == 2 || error == 3 ? "missing" : error == 5 || error == 32 ? "denied" : "io", "file-open", error);
                }
                Information info = InfoAny(result);
                if (directory.HasValue && ((info.FileAttributes & (uint)FileAttributes.Directory) != 0) != directory.Value) throw new FileTransferException("denied");
                if (receiverPrivate && !IsReceiverPrivate(ReadSecurityDescriptor(result), user)) throw new FileTransferException("denied");
                SafeFileHandle owned = result; result = null; return owned;
            }
            catch { if (result != null) { if (create) DeleteOwned(result); result.Dispose(); } throw; }
            finally
            {
                if (iosb != IntPtr.Zero) Marshal.FreeHGlobal(iosb);
                if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
                if (unicode != IntPtr.Zero) Marshal.FreeHGlobal(unicode);
                if (nameBuffer != IntPtr.Zero) Marshal.FreeHGlobal(nameBuffer);
                if (acl != IntPtr.Zero) Marshal.FreeHGlobal(acl);
                if (retained) parent.DangerousRelease();
            }
        }
        private static void Zero(IntPtr memory, int count) { for (int i = 0; i < count; ++i) Marshal.WriteByte(memory, i, 0); }
        internal static List<string> ChildNames(SafeFileHandle directory, int limit)
        {
            Info(directory, true); List<string> names = new List<string>();
            IntPtr memory = Marshal.AllocHGlobal(65536); bool restart = true, retained = false;
            try
            {
                directory.DangerousAddRef(ref retained);
                for (;;)
                {
                    if (!GetFileInformationByHandleEx(directory, restart ? 11 : 10, memory, 65536))
                    {
                        int error = Marshal.GetLastWin32Error(); if (error == 18) break;
                        throw new FileTransferException("denied", "file-info", error);
                    }
                    restart = false; int offset = 0;
                    for (;;)
                    {
                        if (offset < 0 || offset > 65536 - 104) throw new FileTransferException("io");
                        int next = Marshal.ReadInt32(memory, offset), length = Marshal.ReadInt32(memory, offset + 60);
                        if (length < 2 || length > 510 || length % 2 != 0 || offset + 104 > 65536 - length || next != 0 && (next < 104 + length || next > 65536 - offset))
                            throw new FileTransferException("io");
                        string name = Marshal.PtrToStringUni(IntPtr.Add(memory, offset + 104), length / 2);
                        if (name != "." && name != "..")
                        { if (names.Count == limit) throw new FileTransferException("quota"); names.Add(name); }
                        if (next == 0) break; offset += next;
                    }
                }
                return names;
            }
            finally { if (retained) directory.DangerousRelease(); Marshal.FreeHGlobal(memory); }
        }
        internal static void MarkReceived(SafeFileHandle handle)
        {
            using (SafeFileHandle zone = ZoneStream(handle, Write, true))
            using (FileStream marker = new FileStream(zone, FileAccess.Write, 1024, false))
            {
                byte[] bytes = Encoding.ASCII.GetBytes("[ZoneTransfer]\r\nZoneId=3\r\nHostUrl=knot-native://transfer\r\n");
                marker.Write(bytes, 0, bytes.Length); marker.Flush(true);
            }
        }
    }
}
