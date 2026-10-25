// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using Knot.Updates;

namespace DeskBridge.Reverse
{
    // One updater for the unprivileged native-bootstrap lifetime. Broker processes never initialize it.
    internal static class KnotUpdates
    {
        private static readonly object Gate = new object();
        private static readonly object NativeCalls = new object();
        private static bool idle, accepting, stopped, started;
        private static IntPtr library, outerProcess;
        private static FileStream runtimeLock, pendingLock;
        private static string outerPath, payloadDirectory, pendingDirectory, pendingHash;
        private static int outerPid;
        private static long outerCreation;
        private static Action requestExit;
        private static bool portable;
        private static VoidCall cleanup, check;
        private static BoolCallback canShutdownRoot;
        private static VoidCallback shutdownRoot, errorRoot;
        private static InstallerCallback installerRoot;

        internal static bool Configured { get { return KnotUpdateConfiguration.Configured; } }
        internal static bool CanStartNewActivity { get { lock (Gate) return !accepting && !stopped; } }
        internal static string Status
        {
            get
            {
                lock (Gate)
                {
                    if (!Configured) return "이 프리뷰는 자동 업데이트가 아직 연결되지 않았습니다. 새 버전은 공식 배포 페이지에서 받으세요.";
                    if (portable) return "설치 프로그램으로 설치한 Knot에서 자동 업데이트를 사용할 수 있습니다. 실행 파일을 직접 연 경우 공식 설치 파일을 사용하세요.";
                    if (accepting) return "업데이트를 준비했습니다. 진행 중인 설정을 기다리고 연결을 정리한 뒤 Knot을 자동으로 다시 엽니다.";
                    if (!started) return "업데이트 확인을 시작하지 못했습니다. 공식 설치 파일로 업데이트하세요.";
                    return idle ? "새 버전을 자동으로 확인합니다. 설치를 선택하면 Knot을 자동 종료·업데이트·재실행하며 연결 정보는 유지됩니다."
                        : "사용 중에도 새 버전을 확인합니다. 설치를 선택하면 진행 중인 설정을 기다린 뒤 자동으로 다시 엽니다.";
                }
            }
        }

        // false is a refusal: the caller MUST NOT start a connection, setup, transfer or role
        // transition after an installer has atomically reserved the idle lifetime.
        internal static bool SetIdle(bool value)
        {
            lock (Gate)
            {
                if (!value && (accepting || stopped)) return false;
                idle = value; return true;
            }
        }

        internal static bool Start(string nativeOuterPath, string extractedPayloadDirectory, int nativeOuterPid, long nativeOuterCreation, Action exit)
        {
            lock (Gate)
            {
                if (started || stopped) return false;
                idle = true;
                if (!Configured) return false;
            }
            try
            {
                if (!Environment.Is64BitProcess || nativeOuterPid < 1 || exit == null) throw new InvalidDataException("Invalid updater bootstrap.");
                ushort processMachine, nativeMachine;
                if (!IsWow64Process2(Process.GetCurrentProcess().Handle, out processMachine, out nativeMachine) || nativeMachine != 0x8664 ||
                    Environment.OSVersion.Version.Build < 22000) throw new InvalidDataException("Unsupported updater platform.");
                BasicProcessInformation parent; int returned;
                if (NtQueryInformationProcess(Process.GetCurrentProcess().Handle, 0, out parent, Marshal.SizeOf(typeof(BasicProcessInformation)), out returned) != 0 ||
                    parent.ParentPid.ToInt64() != nativeOuterPid) throw new InvalidDataException("The updater requires the native parent.");
                UpdateSecurity.OrdinaryPath(nativeOuterPath); UpdateSecurity.AssertPrivateDirectory(extractedPayloadDirectory);
                if (!UpdateSecurity.IsRegisteredInstallation(nativeOuterPath))
                { lock (Gate) portable = true; return false; }
                outerProcess = UpdateSecurity.OpenProcess(UpdateSecurity.Synchronize | UpdateSecurity.QueryLimited, false, nativeOuterPid);
                UpdateSecurity.VerifyProcess(outerProcess, nativeOuterPid, nativeOuterCreation, nativeOuterPath);
                if (UpdateSecurity.WaitForSingleObject(outerProcess, 0) != UpdateSecurity.WaitTimeout) throw new InvalidDataException("The native parent has exited.");
                outerPath = nativeOuterPath; outerPid = nativeOuterPid; outerCreation = nativeOuterCreation;
                payloadDirectory = extractedPayloadDirectory; requestExit = exit;
                string runtime = Path.Combine(payloadDirectory, "WinSparkle.dll");
                runtimeLock = UpdateSecurity.OpenPinnedFile(runtime, KnotUpdateConfiguration.RuntimeSHA256);
                // No PATH, CWD or application-directory DLL probing. The archive pin is checked
                // before loading, and a no-write/no-delete handle stays open until cleanup.
                library = LoadLibraryEx(runtime, IntPtr.Zero, 0x00000100 | 0x00000800);
                if (library == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                cleanup = Bind<VoidCall>("win_sparkle_cleanup"); check = Bind<VoidCall>("win_sparkle_check_update_with_ui");
                canShutdownRoot = delegate { lock (Gate) return !stopped ? 1 : 0; };
                shutdownRoot = delegate { try { RequestExitSafely(); } catch (Exception) { /* Never unwind into native callbacks. */ } };
                errorRoot = delegate { /* WinSparkle owns its fixed native error UI. */ };
                installerRoot = HandleVerifiedInstaller;
                Bind<SetBoolCallback>("win_sparkle_set_can_shutdown_callback")(canShutdownRoot);
                Bind<SetVoidCallback>("win_sparkle_set_shutdown_request_callback")(shutdownRoot);
                Bind<SetVoidCallback>("win_sparkle_set_error_callback")(errorRoot);
                Bind<SetInstallerCallback>("win_sparkle_set_user_run_installer_callback")(installerRoot);
                WithUTF8(KnotUpdateConfiguration.FeedURL, Bind<SetString>("win_sparkle_set_appcast_url"));
                int keyResult = 0;
                WithUTF8(KnotUpdateConfiguration.PublicEDKey, delegate(IntPtr key) { keyResult = Bind<SetKey>("win_sparkle_set_eddsa_public_key")(key); });
                if (keyResult != 1) throw new InvalidDataException("Invalid update public key.");
                Bind<SetDetails>("win_sparkle_set_app_details")("Knot contributors", "Knot", KnotUpdateConfiguration.DisplayVersion);
                Bind<SetWideString>("win_sparkle_set_app_build_version")(KnotUpdateConfiguration.BuildNumber);
                Bind<SetInt>("win_sparkle_set_automatic_check_for_updates")(1);
                Bind<SetInt>("win_sparkle_set_update_check_interval")(86400);
                lock (Gate) started = true;
                Bind<VoidCall>("win_sparkle_init")();
                return true;
            }
            catch (Exception)
            {
                ReleaseNative();
                lock (Gate) started = false;
                return false;
            }
        }

        internal static bool CheckWithUI()
        {
            lock (NativeCalls)
            {
                VoidCall action;
                lock (Gate)
                {
                    if (!started || stopped || accepting || check == null) return false;
                    action = check;
                }
                action(); return true;
            }
        }

        internal static void AttachControls(TableLayoutPanel layout)
        {
            var row = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, FlowDirection = FlowDirection.TopDown, WrapContents = false };
            var status = new Label { AutoSize = true, MaximumSize = new System.Drawing.Size(560, 0), Text = Status, AccessibleName = "업데이트 상태" };
            var button = new Button { Text = "업데이트 확인", AutoSize = true, Enabled = started && Configured, AccessibleName = "Knot 업데이트 확인" };
            button.Click += delegate { if (!CheckWithUI()) status.Text = Status; };
            row.Controls.Add(status); row.Controls.Add(button); layout.Controls.Add(row);
        }

        private static int HandleVerifiedInstaller(string path)
        {
            string directory = null;
            lock (Gate)
            {
                if (!started || stopped || accepting) return -1;
                accepting = true; // One atomic admission; SetIdle(false) now refuses all new work.
            }
            try
            {
                if (String.IsNullOrWhiteSpace(path) || !path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Invalid update payload.");
                UpdateSecurity.OrdinaryPath(path);
                directory = UpdateSecurity.CreateHoldingDirectory();
                string copied = Path.Combine(directory, UpdateSecurity.InstallerName);
                string digest;
                // WinSparkle calls this only after its Ed25519 validation. Pin the source's
                // bytes throughout the copy, then bind the private copy with SHA-256.
                using (var source = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    if (source.Length < 1 || source.Length > UpdateSecurity.MaximumInstallerBytes) throw new InvalidDataException("Invalid update size.");
                    digest = UpdateSecurity.Hash(source);
                    using (var target = new FileStream(copied, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    { source.CopyTo(target); target.Flush(true); }
                    if (UpdateSecurity.Hash(source) != digest) throw new InvalidDataException("Update changed during copy.");
                }
                pendingLock = UpdateSecurity.OpenPinnedFile(copied, digest);
                UpdateSecurity.VerifyInstaller(pendingLock, copied, digest);
                string helper = Path.Combine(directory, "KnotUpdateHandoff.exe");
                using (var source = UpdateSecurity.OpenPinnedFile(Path.Combine(payloadDirectory, "KnotUpdateHandoff.exe"), KnotUpdateConfiguration.HandoffSHA256))
                using (var target = new FileStream(helper, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                { source.CopyTo(target); target.Flush(true); }
                lock (Gate) { pendingDirectory = directory; pendingHash = digest; }
                // WinSparkle calls the registered shutdown callback after this returns 1.
                // Do not race cleanup against its still-running installer callback.
                return 1; // Never permit WinSparkle's generic installer launch path.
            }
            catch (Exception)
            {
                if (pendingLock != null) { pendingLock.Dispose(); pendingLock = null; }
                CleanupUnlaunched(directory);
                lock (Gate) { accepting = false; pendingDirectory = null; pendingHash = null; }
                return -1;
            }
        }

        private static void RequestExitSafely()
        {
            Action exit = null;
            lock (Gate) if (pendingDirectory != null && !stopped) exit = requestExit;
            if (exit != null) exit(); // Integration must post to, rather than block on, the GUI thread.
        }

        // Call only after disposing the managed image lock. The inherited exact native
        // process handle lets the helper outlive both images without any PID reuse race.
        internal static bool ShutdownAndMaybeInstall()
        {
            string directory, digest;
            lock (Gate) { stopped = true; idle = false; directory = pendingDirectory; digest = pendingHash; }
            bool launched = false;
            try
            {
                // Joins native callback threads before releasing delegate roots or the DLL.
                lock (NativeCalls) if (started && cleanup != null) cleanup();
                lock (Gate) started = false;
                if (directory == null) return true;
                UpdateSecurity.AssertPrivateDirectory(directory);
                if (pendingLock == null || UpdateSecurity.Hash(pendingLock) != digest) throw new InvalidDataException("Update file changed.");
                UpdateSecurity.VerifyInstaller(pendingLock, Path.Combine(directory, UpdateSecurity.InstallerName), digest);
                string helper = Path.Combine(directory, "KnotUpdateHandoff.exe");
                using (var helperLock = UpdateSecurity.OpenPinnedFile(helper, KnotUpdateConfiguration.HandoffSHA256))
                    StartHandoff(helper, directory, digest);
                launched = true; return true;
            }
            catch (Exception) { return false; }
            finally
            {
                if (pendingLock != null) { pendingLock.Dispose(); pendingLock = null; }
                ReleaseNative();
                if (!launched) CleanupUnlaunched(directory);
            }
        }

        private static void CleanupUnlaunched(string directory)
        {
            if (directory == null) return;
            try
            {
                UpdateSecurity.AssertPrivateDirectory(directory);
                foreach (string name in new[] { UpdateSecurity.InstallerName, "KnotUpdateHandoff.exe" })
                {
                    string file = Path.Combine(directory, name);
                    if (File.Exists(file)) { UpdateSecurity.OrdinaryPath(file); File.Delete(file); }
                }
                Directory.Delete(directory, false);
            }
            catch (IOException) { } catch (UnauthorizedAccessException) { } catch (InvalidDataException) { }
        }

        private static void ReleaseNative()
        {
            lock (NativeCalls)
            {
                if (library != IntPtr.Zero) { FreeLibrary(library); library = IntPtr.Zero; }
                if (runtimeLock != null) { runtimeLock.Dispose(); runtimeLock = null; }
                if (outerProcess != IntPtr.Zero) { UpdateSecurity.CloseHandle(outerProcess); outerProcess = IntPtr.Zero; }
                canShutdownRoot = null; shutdownRoot = null; errorRoot = null; installerRoot = null; cleanup = null; check = null; requestExit = null;
            }
        }

        private static void StartHandoff(string helper, string directory, string digest)
        {
            UpdateSecurity.VerifyProcess(outerProcess, outerPid, outerCreation, outerPath);
            IntPtr inherited = IntPtr.Zero, list = IntPtr.Zero, handles = IntPtr.Zero;
            ProcessInformation child = new ProcessInformation();
            bool initialized = false;
            try
            {
                IntPtr current = Process.GetCurrentProcess().Handle;
                if (!DuplicateHandle(current, outerProcess, current, out inherited, 0, true, 2)) throw new Win32Exception(Marshal.GetLastWin32Error());
                IntPtr bytes = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref bytes);
                if (bytes == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                list = Marshal.AllocHGlobal(bytes);
                if (!InitializeProcThreadAttributeList(list, 1, 0, ref bytes)) throw new Win32Exception(Marshal.GetLastWin32Error());
                initialized = true; handles = Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(handles, inherited);
                if (!UpdateProcThreadAttribute(list, 0, new IntPtr(0x00020002), handles, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                var startup = new StartupInformationEx(); startup.Startup.Size = Marshal.SizeOf(typeof(StartupInformationEx)); startup.Attributes = list;
                string arguments = UpdateSecurity.Quote(helper) + " --knot-update-handoff-v1 " + inherited.ToInt64().ToString(CultureInfo.InvariantCulture) + " " +
                    outerPid.ToString(CultureInfo.InvariantCulture) + " " + outerCreation.ToString(CultureInfo.InvariantCulture) + " " +
                    UpdateSecurity.Quote(outerPath) + " " + UpdateSecurity.Quote(directory) + " " + digest;
                if (!CreateProcess(helper, new StringBuilder(arguments), IntPtr.Zero, IntPtr.Zero, true, 0x00080000 | 0x08000000,
                    IntPtr.Zero, directory, ref startup, out child)) throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally
            {
                if (child.Thread != IntPtr.Zero) UpdateSecurity.CloseHandle(child.Thread);
                if (child.Process != IntPtr.Zero) UpdateSecurity.CloseHandle(child.Process);
                if (initialized) DeleteProcThreadAttributeList(list);
                if (list != IntPtr.Zero) Marshal.FreeHGlobal(list);
                if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
                if (inherited != IntPtr.Zero) UpdateSecurity.CloseHandle(inherited);
            }
        }

        private static T Bind<T>(string name) where T : class
        {
            IntPtr address = GetProcAddress(library, name);
            if (address == IntPtr.Zero) throw new EntryPointNotFoundException(name);
            return (T)(object)Marshal.GetDelegateForFunctionPointer(address, typeof(T));
        }
        private static void WithUTF8(string value, SetString action)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(value + "\0"); IntPtr memory = Marshal.AllocHGlobal(bytes.Length);
            try { Marshal.Copy(bytes, 0, memory, bytes.Length); action(memory); } finally { Marshal.FreeHGlobal(memory); }
        }
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void VoidCall();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void SetString(IntPtr text);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int SetKey(IntPtr text);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Unicode)] private delegate void SetWideString([MarshalAs(UnmanagedType.LPWStr)] string text);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Unicode)] private delegate void SetDetails([MarshalAs(UnmanagedType.LPWStr)] string company, [MarshalAs(UnmanagedType.LPWStr)] string app, [MarshalAs(UnmanagedType.LPWStr)] string version);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void SetInt(int value);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int BoolCallback();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void VoidCallback();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Unicode)] private delegate int InstallerCallback([MarshalAs(UnmanagedType.LPWStr)] string path);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void SetBoolCallback(BoolCallback callback);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void SetVoidCallback(VoidCallback callback);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void SetInstallerCallback(InstallerCallback callback);
        [StructLayout(LayoutKind.Sequential)] private struct BasicProcessInformation { internal IntPtr Reserved, Peb, Reserved2, Reserved3, Pid, ParentPid; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct StartupInformation
        { internal int Size; internal string Reserved, Desktop, Title; internal int X, Y, Width, Height, XChars, YChars, Fill, Flags; internal ushort Show, ReservedBytes; internal IntPtr Reserved2, Input, Output, Error; }
        [StructLayout(LayoutKind.Sequential)] private struct StartupInformationEx { internal StartupInformation Startup; internal IntPtr Attributes; }
        [StructLayout(LayoutKind.Sequential)] private struct ProcessInformation { internal IntPtr Process, Thread; internal uint Pid, Tid; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true, SetLastError = true)] private static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool FreeLibrary(IntPtr module);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
        [DllImport("ntdll.dll")] private static extern int NtQueryInformationProcess(IntPtr process, int type, out BasicProcessInformation info, int length, out int returned);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DuplicateHandle(IntPtr source, IntPtr handle, IntPtr destination, out IntPtr copy, uint access, bool inherit, uint options);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")] private static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateProcess(string application, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity, bool inherit, uint flags, IntPtr environment, string directory, ref StartupInformationEx startup, out ProcessInformation process);
    }
}
