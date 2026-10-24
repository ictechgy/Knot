// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace DeskBridge.Reverse
{
    internal static class EngineCommands
    {
        internal static string[] Pair(string address)
        {
            // The upstream native pairing view generates/displays the PIN. No PIN enters wrapper logs or argv.
            return new[] { "pair", ConnectionPolicy.Address(address) };
        }
        internal static string[] Stream(string address, string resolution, int fps, int bitrate, bool fullscreen, bool macCommandKeys = false)
        {
            StreamQualityPolicy.Validate(resolution, fps, bitrate);
            if (macCommandKeys && !fullscreen) throw new ArgumentException("Mac Command 키 전달은 전체 화면에서만 선택하세요.");
            return new[] { "stream", ConnectionPolicy.Address(address), "Desktop", "--display-mode", fullscreen ? "fullscreen" : "windowed",
                "--resolution", resolution, "--fps", fps.ToString(System.Globalization.CultureInfo.InvariantCulture),
                "--bitrate", bitrate.ToString(System.Globalization.CultureInfo.InvariantCulture), "--absolute-mouse", "--no-quit-after",
                "--capture-system-keys", macCommandKeys ? "fullscreen" : "never", "--no-game-optimization", "--mute-on-focus-loss", "--no-background-gamepad",
                "--audio-config", "stereo", "--no-hdr", "--no-yuv444", "--video-decoder", "auto" };
        }

        // Windows CRT quoting: quotes/backslashes are data; shell execution is never used.
        internal static string Quote(string value)
        {
            if (value == null || value.IndexOf('\0') >= 0 || value.IndexOf('\r') >= 0 || value.IndexOf('\n') >= 0) throw new ArgumentException("잘못된 실행 인수입니다.");
            var result = new StringBuilder("\""); int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') slashes++;
                else
                {
                    if (c == '"') result.Append('\\', slashes * 2 + 1);
                    else result.Append('\\', slashes);
                    result.Append(c); slashes = 0;
                }
            }
            return result.Append('\\', slashes * 2).Append('"').ToString();
        }
        internal static string Join(string[] args)
        { var result = new List<string>(); foreach (string item in args) result.Add(Quote(item)); return String.Join(" ", result); }
    }

    internal sealed class ProfileLease : IDisposable
    {
        internal readonly string Path;
        private readonly FileStream ownership;
        internal ProfileLease(string path, FileStream file) { Path = path; ownership = file; }
        public void Dispose() { ownership.Dispose(); }
    }

    internal static class EngineProfile
    {
        internal static ProfileLease Prepare(string root, string address)
        {
            address = ConnectionPolicy.Address(address);
            PrivateFiles.AssertPrivate(root);
            string parent = Path.Combine(root, "profiles");
            if (!Directory.Exists(parent)) PrivateFiles.CreatePrivate(parent);
            PrivateFiles.AssertPrivate(parent);
            string path = Path.Combine(parent, address.Replace('.', '_'));
            if (!Directory.Exists(path))
            {
                PrivateFiles.CreatePrivate(path);
                PrivateFiles.WriteNew(Path.Combine(path, "owner.txt"), PrivateFiles.MarkerText);
                PrivateFiles.WriteNew(Path.Combine(path, "portable.dat"), "");
            }
            PrivateFiles.AssertPrivate(path);
            CheckMutableTree(path, 0, new int[1]);
            string marker = Path.Combine(path, "owner.txt");
            if (!File.Exists(marker) || new FileInfo(marker).Length != PrivateFiles.MarkerText.Length || File.ReadAllText(marker) != PrivateFiles.MarkerText || !File.Exists(Path.Combine(path, "portable.dat")))
                throw new ReverseUserException(ReverseFailure.ProfilePolicy);
            // Another DeskBridge instance must not edit or launch the same identity/settings while it is in use.
            FileStream ownership;
            try { ownership = new FileStream(Path.Combine(path, "in-use.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
            catch (IOException) { throw new ReverseUserException(ReverseFailure.ProfilePolicy); }
            catch (UnauthorizedAccessException) { throw new ReverseUserException(ReverseFailure.ProfilePolicy); }
            try
            {
                if (ownership.Length != 0) throw new ReverseUserException(ReverseFailure.ProfilePolicy);
            string settingsDirectory = Path.Combine(path, "Moonlight Game Streaming Project");
            if (!Directory.Exists(settingsDirectory)) PrivateFiles.CreatePrivate(settingsDirectory);
            PrivateFiles.AssertPrivate(settingsDirectory);
            string settings = Path.Combine(settingsDirectory, "Moonlight.ini");
            string text = "";
            if (File.Exists(settings))
            {
                if (new FileInfo(settings).Length > 1024 * 1024) throw new ReverseUserException(ReverseFailure.ProfilePolicy);
                text = File.ReadAllText(settings, new UTF8Encoding(false, true));
            }
            string updated = SetPrivacySettings(text);
            string temporary = settings + ".new-" + Guid.NewGuid().ToString("N");
            try
            {
                PrivateFiles.WriteNew(temporary, updated);
                if (File.Exists(settings)) File.Replace(temporary, settings, null);
                else File.Move(temporary, settings);
            }
            finally { if (File.Exists(temporary)) { PrivateFiles.OrdinaryAncestors(temporary); File.Delete(temporary); } }
            string temp = Path.Combine(path, "temp");
            if (!Directory.Exists(temp)) PrivateFiles.CreatePrivate(temp);
            PrivateFiles.AssertPrivate(temp);
                return new ProfileLease(path, ownership);
            }
            catch { ownership.Dispose(); throw; }
        }

        internal static string SetPrivacySettings(string original)
        {
            if (original.IndexOf('\0') >= 0) throw new ReverseUserException(ReverseFailure.ProfilePolicy);
            var forced = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                { "richpresence", "false" }, { "mdns", "false" }, { "detectnetblocking", "false" },
                { "quitAppAfter", "false" }, { "backgroundgamepad", "false" } };
            var result = new List<string>(); bool general = false, inserted = false;
            foreach (string raw in original.Replace("\r\n", "\n").Split('\n'))
            {
                string line = raw.Trim();
                if (line.StartsWith("[", StringComparison.Ordinal) && line.EndsWith("]", StringComparison.Ordinal))
                {
                    general = line.Equals("[General]", StringComparison.OrdinalIgnoreCase);
                    result.Add(raw);
                    if (general && !inserted) { foreach (var pair in forced) result.Add(pair.Key + "=" + pair.Value); inserted = true; }
                    continue;
                }
                int equals = line.IndexOf('=');
                if (general && equals >= 0 && forced.ContainsKey(line.Substring(0, equals).Trim())) continue;
                if (raw.Length != 0 || result.Count != 0) result.Add(raw);
            }
            if (!inserted) { result.Add("[General]"); foreach (var pair in forced) result.Add(pair.Key + "=" + pair.Value); }
            while (result.Count > 0 && result[result.Count - 1].Length == 0) result.RemoveAt(result.Count - 1);
            return String.Join("\r\n", result) + "\r\n";
        }

        private static void CheckMutableTree(string path, int depth, int[] count)
        {
            if (depth > 8) throw new ReverseUserException(ReverseFailure.ProfilePolicy);
            PrivateFiles.OrdinaryAncestors(path);
            foreach (string item in Directory.EnumerateFileSystemEntries(path))
            {
                if (++count[0] > 4096) throw new ReverseUserException(ReverseFailure.ProfilePolicy);
                FileAttributes attributes = File.GetAttributes(item);
                if ((attributes & FileAttributes.ReparsePoint) != 0) throw new ReverseUserException(ReverseFailure.ProfilePolicy);
                if ((attributes & FileAttributes.Directory) != 0) CheckMutableTree(item, depth + 1, count);
                else
                {
                    string extension = Path.GetExtension(item).ToLowerInvariant();
                    if (Array.IndexOf(new[] { ".exe", ".dll", ".com", ".bat", ".cmd", ".ps1", ".vbs", ".js", ".qml", ".rcc", ".qmlc", ".jsc" }, extension) >= 0)
                        throw new ReverseUserException(ReverseFailure.ProfilePolicy);
                }
            }
        }
    }

    internal sealed class EngineProcess : IDisposable
    {
        private readonly object gate = new object();
        private readonly Func<IntPtr, IntPtr, bool> assign;
        private readonly Func<IntPtr, uint> resume;
        private IntPtr process, job;
        private bool disposed, started;

        internal EngineProcess() : this(AssignProcessToJobObject, ResumeThread) { }
        // Narrow native-operation seams let offline Windows fixtures force assignment/resume failures.
        internal EngineProcess(Func<IntPtr, IntPtr, bool> assignProcess, Func<IntPtr, uint> resumePrimary)
        { assign = assignProcess; resume = resumePrimary; }

        internal Task<int> RunAsync(EngineLease engine, string profile, string[] arguments, CancellationToken cancel)
        {
            PrivateFiles.OrdinaryAncestors(profile);
            return RunExecutableAsync(engine.Executable, engine.Directory, profile, arguments, cancel);
        }

        // Shared with the inert lifecycle fixture; production callers always supply a verified EngineLease.
        internal async Task<int> RunExecutableAsync(string executable, string engineDirectory, string profile, string[] arguments, CancellationToken cancel)
        {
            var start = new ProcessStartInfo(executable, EngineCommands.Join(arguments));
            start.WorkingDirectory = profile;
            CleanEnvironment(start, engineDirectory, profile);
            IntPtr waitHandle;
            lock (gate)
            {
                if (started || disposed) throw new ReverseUserException(ReverseFailure.EngineBusy);
                started = true;
                cancel.ThrowIfCancellationRequested();
                IntPtr environment = IntPtr.Zero, thread = IntPtr.Zero;
                try
                {
                    job = CreateJobObject(IntPtr.Zero, null);
                    if (job == IntPtr.Zero) throw new ReverseUserException(ReverseFailure.EngineStart);
                    var information = new JobInformation();
                    information.BasicLimitInformation.LimitFlags = 0x2000; // KILL_ON_JOB_CLOSE
                    if (!SetInformationJobObject(job, 9, ref information, (uint)Marshal.SizeOf(information)))
                        throw new ReverseUserException(ReverseFailure.EngineStart);
                    environment = Marshal.StringToHGlobalUni(EnvironmentBlock(start));
                    var startup = new StartupInformation(); startup.Size = (uint)Marshal.SizeOf(startup);
                    ProcessInformation child;
                    // No user-mode engine code runs until containment is established. Never inherit handles.
                    var command = new StringBuilder(EngineCommands.Quote(executable) + " " + start.Arguments);
                    if (!CreateProcessW(executable, command, IntPtr.Zero, IntPtr.Zero, false, 0x00000004 | 0x00000400,
                        environment, profile, ref startup, out child))
                        throw new ReverseUserException(ReverseFailure.EngineStart);
                    process = child.Process; thread = child.Thread;
                    if (!assign(job, process)) throw new ReverseUserException(ReverseFailure.EngineStart);
                    cancel.ThrowIfCancellationRequested();
                    if (resume(thread) != 1) throw new ReverseUserException(ReverseFailure.EngineStart);
                    waitHandle = process;
                }
                catch
                {
                    StopLocked();
                    // Reap even an unassigned suspended child before releasing the process handle.
                    if (process != IntPtr.Zero) { WaitForSingleObject(process, 0xffffffff); CloseHandle(process); process = IntPtr.Zero; }
                    throw;
                }
                finally
                {
                    if (thread != IntPtr.Zero) CloseHandle(thread);
                    if (environment != IntPtr.Zero) Marshal.FreeHGlobal(environment);
                }
            }
            try
            {
                using (cancel.Register(Stop))
                {
                    int exit = await Task.Run(() =>
                    {
                        if (WaitForSingleObject(waitHandle, 0xffffffff) != 0) throw new ReverseUserException(ReverseFailure.EngineStart);
                        uint code;
                        if (!GetExitCodeProcess(waitHandle, out code)) throw new ReverseUserException(ReverseFailure.EngineStart);
                        return unchecked((int)code);
                    });
                    cancel.ThrowIfCancellationRequested();
                    return exit;
                }
            }
            finally
            {
                lock (gate)
                {
                    // Process exit also ends remaining descendants; the waiter exclusively owns handle closure.
                    StopLocked();
                    if (process != IntPtr.Zero) { CloseHandle(process); process = IntPtr.Zero; }
                }
            }
        }

        internal static string EnvironmentBlock(ProcessStartInfo start)
        {
            var names = new List<string>();
            foreach (string name in start.EnvironmentVariables.Keys) names.Add(name);
            names.Sort(StringComparer.OrdinalIgnoreCase);
            var block = new StringBuilder();
            foreach (string name in names)
            {
                string value = start.EnvironmentVariables[name];
                if (name.Length == 0 || name.IndexOf('=') >= 0 || name.IndexOf('\0') >= 0 || value == null || value.IndexOf('\0') >= 0)
                    throw new ArgumentException("Invalid child environment.");
                block.Append(name).Append('=').Append(value).Append('\0');
            }
            return block.Append('\0').ToString();
        }

        internal static void CleanEnvironment(ProcessStartInfo start, string engine, string profile)
        {
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string system = Path.Combine(windows, "System32");
            string userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            // An allowlist excludes inherited Qt/QML/SDL/COM/CLR hooks, proxy overrides and PATH injection.
            start.EnvironmentVariables.Clear();
            start.EnvironmentVariables["SystemRoot"] = windows;
            start.EnvironmentVariables["WINDIR"] = windows;
            start.EnvironmentVariables["PATH"] = system + ";" + windows;
            start.EnvironmentVariables["USERPROFILE"] = userProfile;
            start.EnvironmentVariables["LOCALAPPDATA"] = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            start.EnvironmentVariables["APPDATA"] = Path.Combine(profile, "roaming");
            start.EnvironmentVariables["TEMP"] = Path.Combine(profile, "temp");
            start.EnvironmentVariables["TMP"] = Path.Combine(profile, "temp");
            start.EnvironmentVariables["QT_PLUGIN_PATH"] = engine;
            start.EnvironmentVariables["QT_QPA_PLATFORM_PLUGIN_PATH"] = Path.Combine(engine, "platforms");
            start.EnvironmentVariables["QML2_IMPORT_PATH"] = Path.Combine(engine, "qml");
            start.EnvironmentVariables["QML_IMPORT_PATH"] = Path.Combine(engine, "qml");
            start.EnvironmentVariables["QML_DISABLE_DISK_CACHE"] = "1";
            start.EnvironmentVariables["QML_DISK_CACHE_PATH"] = Path.Combine(profile, "qmlcache");
        }

        internal void Stop()
        {
            lock (gate) { StopLocked(); }
        }
        private void StopLocked()
        {
            // Only exact owned handles are used, never a PID or name that could identify another process.
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
            if (process != IntPtr.Zero) TerminateProcess(process, 1);
        }
        public void Dispose()
        {
            lock (gate) { if (disposed) return; disposed = true; StopLocked(); }
            // RunExecutableAsync retains its process handle until its native wait finishes.
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct StartupInformation
        {
            internal uint Size;
            internal string Reserved, Desktop, Title;
            internal uint X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
            internal ushort ShowWindow, ReservedSize;
            internal IntPtr ReservedData, StandardInput, StandardOutput, StandardError;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ProcessInformation
        { internal IntPtr Process, Thread; internal uint ProcessId, ThreadId; }
        [StructLayout(LayoutKind.Sequential)] private struct BasicLimits
        { internal long PerProcessUserTimeLimit, PerJobUserTimeLimit; internal uint LimitFlags; internal UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; internal uint ActiveProcessLimit; internal UIntPtr Affinity; internal uint PriorityClass, SchedulingClass; }
        [StructLayout(LayoutKind.Sequential)] private struct IoCounters
        { internal ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
        [StructLayout(LayoutKind.Sequential)] private struct JobInformation
        { internal BasicLimits BasicLimitInformation; internal IoCounters IoInfo; internal UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetInformationJobObject(IntPtr job, int kind, ref JobInformation information, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint flags, IntPtr environment, string directory, ref StartupInformation startup, out ProcessInformation information);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetExitCodeProcess(IntPtr process, out uint code);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
    }
}
