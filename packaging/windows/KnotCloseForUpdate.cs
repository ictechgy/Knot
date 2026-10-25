// SPDX-License-Identifier: GPL-3.0-only
// Installer-only graceful close bridge for older native-bootstrap releases.
// No termination rights, taskkill, services, credentials or registry access.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;

internal sealed class KnotCloseProcess : IDisposable
{
    internal int Pid, Parent, Session; internal bool Elevated;
    internal long Created;
    internal string Image;
    internal IntPtr Handle;
    public void Dispose() { if (Handle != IntPtr.Zero) { KnotCloseForUpdate.CloseHandle(Handle); Handle = IntPtr.Zero; } }
}
internal static class KnotClosePolicy
{
    internal static bool Child(int parentPid, long parentCreated, int parentSession, int childParent, long childCreated, int childSession)
    { return parentPid == childParent && parentCreated < childCreated && parentSession == childSession; }
    internal static bool RootName(string name) { return String.Equals(name, "Knot.exe", StringComparison.OrdinalIgnoreCase) || String.Equals(name, "DeskBridge-Windows.exe", StringComparison.OrdinalIgnoreCase); }
    internal static bool ManagedName(string name) { return String.Equals(name, "Knot-Managed.exe", StringComparison.OrdinalIgnoreCase) || String.Equals(name, "DeskBridge-Managed.exe", StringComparison.OrdinalIgnoreCase); }
    internal static bool AllowedChild(string parent, string child, string systemPowerShell)
    {
        return RootName(Path.GetFileName(parent)) &&
                   ManagedName(Path.GetFileName(child)) ||
               ManagedName(Path.GetFileName(parent)) &&
                   String.Equals(child, systemPowerShell, StringComparison.OrdinalIgnoreCase);
    }
}
internal static class KnotCloseForUpdate
{
    private const uint Query = 0x1000, Synchronize = 0x100000, Timeout = 258;
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct Entry {
        internal uint Size, Usage, Pid; internal IntPtr Heap; internal uint Module, Threads, Parent; internal int Priority; internal uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] internal string Name;
    }
    [StructLayout(LayoutKind.Sequential)] private struct Times { internal uint Low, High; internal long Value { get { return ((long)High << 32) | Low; } } }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool Process32FirstW(IntPtr snapshot, ref Entry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool Process32NextW(IntPtr snapshot, ref Entry entry);
    [DllImport("kernel32.dll")] private static extern IntPtr OpenProcess(uint rights, bool inherit, int pid);
    [DllImport("kernel32.dll")] internal static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern uint WaitForSingleObject(IntPtr process, uint milliseconds);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder image, ref int size);
    [DllImport("kernel32.dll")] private static extern bool GetProcessTimes(IntPtr process, out Times created, out Times exited, out Times kernel, out Times user);
    [DllImport("kernel32.dll")] private static extern bool ProcessIdToSessionId(int pid, out int session);
    [DllImport("advapi32.dll")] private static extern bool OpenProcessToken(IntPtr process, uint rights, out IntPtr token);
    [DllImport("advapi32.dll")] private static extern bool GetTokenInformation(IntPtr token, int kind, out int elevation, int length, out int returned);
    private delegate bool WindowCallback(IntPtr window, IntPtr ignored);
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr ignored);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out int pid);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SendMessageTimeoutW(IntPtr window, uint message, IntPtr wparam, IntPtr lparam, uint flags, uint timeout, out IntPtr result);

    private static KnotCloseProcess Open(int pid, int parent)
    {
        IntPtr handle = OpenProcess(Query | Synchronize, false, pid);
        if (handle == IntPtr.Zero) return null;
        var result = new KnotCloseProcess { Pid = pid, Parent = parent, Handle = handle };
        try {
            Times created, exited, kernel, user; int size = 32768, session;
            var image = new StringBuilder(size);
            if (!QueryFullProcessImageNameW(handle, 0, image, ref size) || !GetProcessTimes(handle, out created, out exited, out kernel, out user) ||
                !ProcessIdToSessionId(pid, out session) || WaitForSingleObject(handle, 0) != Timeout) { result.Dispose(); return null; }
            result.Created = created.Value; result.Session = session; result.Image = image.ToString(); return result;
        } catch { result.Dispose(); throw; }
    }
    private static bool Elevated(KnotCloseProcess process)
    {
        IntPtr token;
        if (!OpenProcessToken(process.Handle, 8, out token)) throw new IOException();
        try { int elevation, returned; if (!GetTokenInformation(token, 20, out elevation, 4, out returned) || returned != 4) throw new IOException(); return elevation != 0; }
        finally { CloseHandle(token); }
    }
    private static List<KnotCloseProcess> Targets(string installed)
    {
        var entries = new List<Entry>(); IntPtr snapshot = CreateToolhelp32Snapshot(2, 0);
        if (snapshot == new IntPtr(-1)) throw new IOException();
        try { var entry = new Entry(); entry.Size = (uint)Marshal.SizeOf(typeof(Entry));
            if (!Process32FirstW(snapshot, ref entry)) throw new IOException();
            do { entries.Add(entry); if (entries.Count > 65536) throw new IOException(); } while (Process32NextW(snapshot, ref entry));
        } finally { CloseHandle(snapshot); }
        var owned = new List<KnotCloseProcess>(); int currentSession = Process.GetCurrentProcess().SessionId;
        try {
            foreach (var entry in entries) {
                if (!String.Equals(entry.Name, Path.GetFileName(installed), StringComparison.OrdinalIgnoreCase)) continue;
                var candidate = Open((int)entry.Pid, (int)entry.Parent);
                if (candidate == null) throw new IOException();
                if (!String.Equals(candidate.Image, installed, StringComparison.OrdinalIgnoreCase)) { candidate.Dispose(); continue; }
                if (candidate.Session != currentSession) { candidate.Dispose(); throw new IOException(); }
                candidate.Elevated = Elevated(candidate); owned.Add(candidate);
            }
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
            for (int at = 0; at < owned.Count; at++) {
                if (owned.Count > 64) throw new IOException(); var parent = owned[at];
                foreach (var entry in entries) {
                    if (entry.Parent != parent.Pid) continue;
                    var child = Open((int)entry.Pid, (int)entry.Parent); if (child == null) throw new IOException();
                    if (!KnotClosePolicy.Child(parent.Pid, parent.Created, parent.Session, child.Parent, child.Created, child.Session) ||
                        !KnotClosePolicy.AllowedChild(parent.Image, child.Image, powershell)) { child.Dispose(); throw new IOException(); }
                    child.Elevated = Elevated(child); owned.Add(child);
                }
            }
            return owned;
        } catch { foreach (var process in owned) process.Dispose(); throw; }
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessageW(string message);
    private static readonly uint SafeCloseMessage = RegisterWindowMessageW("Knot.SafeCloseForUpdate.v1");
    private static void CloseWindows(List<KnotCloseProcess> targets)
    {
        // Handle retention prevents PID reuse; match live windows to held identities.
        EnumWindows(delegate(IntPtr window, IntPtr ignored) {
            int pid; GetWindowThreadProcessId(window, out pid);
            foreach (var process in targets) if (process.Pid == pid && WaitForSingleObject(process.Handle, 0) == Timeout) {
                IntPtr result; SendMessageTimeoutW(window, process.Elevated ? SafeCloseMessage : 0x10, IntPtr.Zero, IntPtr.Zero, 2, 500, out result); break;
            }
            return true;
        }, IntPtr.Zero);
    }
    [STAThread] private static int Main(string[] args)
    {
        // The installer supplies only its exact target. Refuse redirected paths.
        try {
            if (args.Length != 1 || !Path.IsPathRooted(args[0]) || args[0].StartsWith(@"\\", StringComparison.Ordinal) ||
                !String.Equals(Path.GetFullPath(args[0]), args[0], StringComparison.OrdinalIgnoreCase) ||
                !KnotClosePolicy.RootName(Path.GetFileName(args[0]))) return 2;
            for (var directory = new DirectoryInfo(Path.GetDirectoryName(args[0])); directory != null; directory = directory.Parent)
                if ((directory.Attributes & FileAttributes.ReparsePoint) != 0) return 2;
            var timer = Stopwatch.StartNew();
            while (timer.ElapsedMilliseconds < 15000) {
                List<KnotCloseProcess> targets = Targets(args[0]);
                try {
                    if (targets.Count == 0) return 0;
                    CloseWindows(targets);
                    bool exited = true;
                    foreach (var process in targets) if (WaitForSingleObject(process.Handle, 0) == Timeout) exited = false;
                    if (!exited) Thread.Sleep(250);
                } finally { foreach (var process in targets) process.Dispose(); }
            }
        } catch { return 2; }
        return 1; // Busy or an unsupported child. Never fall back to killing it.
    }
}
