// SPDX-License-Identifier: GPL-3.0-only
// Windows 11's .NET Framework 4.8; no separately installed runtime or shell console.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

internal sealed class PayloadEntry
{
    internal readonly string Name, Resource, Sha256;
    internal PayloadEntry(string name, string resource, string sha256)
    { Name = name; Resource = resource; Sha256 = sha256; }
}

internal sealed class BrokerRequest
{
    internal string Operation, RequestJson, WindowsAddress, DesktopUserSid, MsiPath, ZipPath;
    internal bool Silent;
}

internal sealed class SunshinePin
{
    internal string Sha256;
    internal long Bytes;
}

internal static class Launcher
{
    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        internal int Length;
        internal IntPtr Descriptor;
        [MarshalAs(UnmanagedType.Bool)] internal bool Inherit;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateDirectory(string path, ref SecurityAttributes attributes);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);

    [STAThread]
    private static int Main(string[] args)
    {
        string directory = null;
        bool silent = false;
        WindowsFormsSynchronizationContext updateContext = null;
        var written = new List<string>();
        try
        {
            // No caller-controlled script, executable, URL, hash or result path enters the broker.
            string bootstrap = ParseBootstrapArguments(args);
            BrokerRequest request = bootstrap == null ? ParseBrokerArguments(args) : null;
            silent = request != null && request.Silent;
            Application.EnableVisualStyles();
            if (request == null && bootstrap == null)
                throw new InvalidOperationException("배포용 Knot EXE를 실행하세요. 내부 관리 도우미는 직접 실행하지 않습니다.");
            ushort processMachine, nativeMachine;
            if (!Environment.Is64BitProcess || !IsWow64Process2(Process.GetCurrentProcess().Handle, out processMachine, out nativeMachine) ||
                nativeMachine != 0x8664 || Environment.OSVersion.Version.Build < 22000)
                throw new InvalidOperationException("Windows 11 x64에서 실행하세요.");
            string launcher = Assembly.GetExecutingAssembly().Location;
            // The native bootstrap holds the original image/path locks; retain this exact extracted helper too.
            using (var imageLock = new FileStream(launcher, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                bool elevated = new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
                if (request == null)
                {
                    if (elevated)
                        throw new InvalidOperationException("관리자 창을 닫고 Knot EXE를 평소처럼 두 번 클릭하세요. 필요한 단계에서 관리자 확인을 요청합니다.");
                    directory = CreatePrivateDirectory(Path.GetTempPath(), identity.User, false);
                }
                else
                {
                    if (!elevated) throw new InvalidOperationException("이 작업은 Knot 설정 창의 관리자 확인으로 실행하세요.");
                    // A protected child of Program Files cannot be renamed via a user's writable temp parent.
                    string parent = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
                    AssertProtectedAncestors(parent);
                    directory = CreatePrivateDirectory(parent, new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), true);
                }
                ExtractPayload(directory, written);
                if (request != null)
                    return RunElevatedOperation(request, directory, written);
                DeskBridge.Reverse.ReverseQrLibrary.Initialize();
                if (BootstrapParentID > 0)
                {
                    updateContext = new WindowsFormsSynchronizationContext();
                    DeskBridge.Reverse.KnotUpdates.Start(bootstrap, directory, BootstrapParentID, BootstrapCreationFileTime,
                        delegate {
                            updateContext.Post(delegate(object ignored) {
                                var forms = new List<Form>();
                                foreach (Form form in Application.OpenForms) forms.Add(form);
                                foreach (Form form in forms) if (!form.IsDisposed) form.Close();
                            }, null);
                        });
                }
                if (!DeskBridge.Reverse.KnotUpdates.SetIdle(false)) return 0;
                string powershell = WindowsPowerShell();
                var start = new ProcessStartInfo(powershell,
                    "-NoLogo -NoProfile -STA -ExecutionPolicy RemoteSigned -File " + Quote(Path.Combine(directory, "Setup-DeskBridge.ps1")) +
                    " -LauncherPath " + Quote(bootstrap));
                start.WorkingDirectory = directory;
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                int hostResult = InterpretSetupHostResult(RunAndWait(start));
                if (hostResult == 12)
                {
                    DeskBridge.Reverse.KnotUpdates.SetIdle(true);
                    DeskBridge.Reverse.WindowsRoleChooser.ShowUpdates(); return 0;
                }
                if (hostResult == 10 || hostResult == 11)
                {
                    DeskBridge.Reverse.ClientMain.RunEmbedded(bootstrap, hostResult == 11 ? DeskBridge.Reverse.HostPlatform.Linux : DeskBridge.Reverse.HostPlatform.Mac);
                    return 0;
                }
            }
            return 0;
        }
        catch (Exception error)
        {
            if (!silent) MessageBox.Show(error.Message, "Knot", MessageBoxButtons.OK, MessageBoxIcon.Error);
            // Native outer preserves failure, but does not duplicate an already-shown managed error.
            return silent ? 1 : 2;
        }
        finally
        {
            // Managed GUI/image locks have unwound. The independent updater waits
            // the exact native parent's termination before replacing its EXE.
            if (!DeskBridge.Reverse.KnotUpdates.ShutdownAndMaybeInstall() && !silent)
                MessageBox.Show("업데이트를 시작하지 못했습니다. 현재 버전과 연결 설정은 유지됩니다.", "Knot", MessageBoxButtons.OK, MessageBoxIcon.Information);
            if (updateContext != null) updateContext.Dispose();
            // Delete only our exact generated files. Never recursively follow a replacement link.
            if (directory != null)
            {
                try
                {
                    AssertOrdinaryAncestors(directory);
                    foreach (string path in written)
                    {
                        if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0)
                            File.Delete(path);
                    }
                    Directory.Delete(directory, false);
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
    }

    private static void ExtractPayload(string directory, List<string> written)
    {
        foreach (PayloadEntry entry in Payload.Entries)
        {
            ValidateName(entry.Name);
            string destination = Path.Combine(directory, entry.Name);
            using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(entry.Resource))
            {
                if (resource == null) throw new InvalidDataException("설정 파일이 없습니다. EXE를 다시 받으세요.");
                using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                { written.Add(destination); resource.CopyTo(output); }
            }
            using (var input = File.OpenRead(destination))
                VerifyHash(input, entry.Sha256);
        }
    }

    internal static void CopyPinnedInstaller(Stream source, Stream output, long expectedBytes)
    {
        if (expectedBytes < 1 || expectedBytes > 268435456) throw new InvalidDataException("Sunshine 설치 파일 크기가 다릅니다.");
        byte[] buffer = new byte[65536];
        long remaining = expectedBytes;
        while (remaining > 0)
        {
            int read = source.Read(buffer, 0, (int)Math.Min(buffer.Length, remaining));
            if (read == 0) throw new InvalidDataException("Sunshine 설치 파일 크기가 다릅니다.");
            output.Write(buffer, 0, read);
            remaining -= read;
        }
        if (source.ReadByte() != -1) throw new InvalidDataException("Sunshine 설치 파일 크기가 다릅니다.");
    }

    private static int InterpretSunshineInstallerResult(int result)
    {
        // Preserve only documented installer outcomes consumed by the setup UI.
        if (result == 0 || result == 3010 || result == 1641 || result == 1618 || result == 1602) return result;
        throw new InvalidOperationException("Sunshine 설치를 완료하지 못했습니다. 설치 상태를 확인한 뒤 다시 시도하세요.");
    }

    private static int RunElevatedOperation(BrokerRequest request, string directory, List<string> written)
    {
        if (request.Operation == "InstallVirtualDisplay" || request.Operation == "RemoveVirtualDisplay")
            return RunHeadlessOperation(request, directory, written);
        if (request.Operation == "QuickSetupSunshine") return SunshineQuickSetup.Run(directory);
        if (request.Operation == "InstallSunshine" || request.Operation == "InstallSunshineAndSetup")
        {
            SunshinePin pin = ParseSunshinePin(File.ReadAllText(Path.Combine(directory, "SunshineDependency.json")));
            if (new DriveInfo(Path.GetPathRoot(request.MsiPath)).DriveType == DriveType.Network)
                throw new InvalidDataException("설치 파일을 로컬 드라이브로 복사하세요.");
            AssertOrdinaryAncestors(Path.GetDirectoryName(request.MsiPath));
            if ((File.GetAttributes(request.MsiPath) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("설치 파일에 연결 경로를 사용할 수 없습니다.");
            string msi = Path.Combine(directory, "Sunshine.msi");
            using (var source = new FileStream(request.MsiPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (source.Length != pin.Bytes) throw new InvalidDataException("Sunshine 설치 파일 크기가 다릅니다.");
                using (var output = new FileStream(msi, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                { written.Add(msi); CopyPinnedInstaller(source, output, pin.Bytes); }
            }
            // The hash authority is the embedded pin. The installer consumes only this protected copy.
            using (var verified = new FileStream(msi, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (verified.Length != pin.Bytes) throw new InvalidDataException("Sunshine 설치 파일 크기가 다릅니다.");
                VerifyHash(verified, pin.Sha256);
                var install = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "msiexec.exe"), "/i " + Quote(msi) + (request.Operation == "InstallSunshineAndSetup" ? " /passive /norestart" : ""));
                install.UseShellExecute = false;
                install.WorkingDirectory = directory;
                int result = InterpretSunshineInstallerResult(RunAndWait(install));
                return result == 0 && request.Operation == "InstallSunshineAndSetup" ? SunshineQuickSetup.Run(directory) : result;
            }
        }
        if (request.Operation != "EnableFiles" && request.Operation != "Export" && request.Operation != "DisableFiles")
            throw new InvalidDataException("지원하지 않는 관리자 작업입니다.");
        string arguments = "-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File " + Quote(Path.Combine(directory, "Invoke-DeskBridgeSetup.ps1")) +
            " -SuccessReceipt -Operation " + request.Operation;
        if (request.Silent) arguments += " -NoPause";
        if (request.Operation != "DisableFiles")
        {
            string requestPath = Path.Combine(directory, "request.json");
            using (var output = new FileStream(requestPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (var writer = new StreamWriter(output, new UTF8Encoding(false, true)))
            { written.Add(requestPath); writer.Write(request.RequestJson); }
            arguments += " -RequestPath " + Quote(requestPath) + " -WindowsAddress " + Quote(request.WindowsAddress);
        }
        if (request.DesktopUserSid != null) arguments += " -DesktopUserSid " + Quote(request.DesktopUserSid);
        string receipt = Path.Combine(directory, "operation-success");
        if (File.Exists(receipt) || Directory.Exists(receipt))
            throw new InvalidDataException("설정 완료 확인 파일이 이미 있습니다. 새 설정 창에서 다시 시도하세요.");
        written.Add(receipt);
        var start = new ProcessStartInfo(WindowsPowerShell(), arguments);
        start.UseShellExecute = false;
        start.CreateNoWindow = request.Silent;
        start.WorkingDirectory = directory;
        return InterpretSetupResult(RunAndWait(start), request.Silent, HasSetupSuccessReceipt(directory));
    }

    private static int RunHeadlessOperation(BrokerRequest request, string directory, List<string> written)
    {
        if (request.Operation == "InstallVirtualDisplay")
        {
            AssertVirtualDisplayInstallAllowed();
            SunshinePin pin = ParseSunshinePin(File.ReadAllText(Path.Combine(directory, "VirtualDisplayDependency.json")));
            if (new DriveInfo(Path.GetPathRoot(request.ZipPath)).DriveType == DriveType.Network)
                throw new InvalidDataException("드라이버 설치 파일을 로컬 드라이브로 복사하세요.");
            AssertOrdinaryAncestors(Path.GetDirectoryName(request.ZipPath));
            if ((File.GetAttributes(request.ZipPath) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("드라이버 설치 파일에 연결 경로를 사용할 수 없습니다.");
            string archive = Path.Combine(directory, "VirtualDisplayDriver.zip");
            using (var source = new FileStream(request.ZipPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (source.Length != pin.Bytes) throw new InvalidDataException("드라이버 설치 파일 크기가 다릅니다.");
                using (var output = new FileStream(archive, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                { written.Add(archive); CopyPinnedInstaller(source, output, pin.Bytes); }
            }
            using (var verified = new FileStream(archive, FileMode.Open, FileAccess.Read, FileShare.Read))
                VerifyHash(verified, pin.Sha256);
        }
        foreach (string name in new[] { "operation-success", "reboot-required", "recovery-blocked" })
        {
            string path = Path.Combine(directory, name);
            if (File.Exists(path) || Directory.Exists(path))
                throw new InvalidDataException("가상 화면 작업 확인 파일이 이미 있습니다. 새 설정 창에서 다시 시도하세요.");
            written.Add(path);
        }
        var start = new ProcessStartInfo(WindowsPowerShell(),
            "-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File " + Quote(Path.Combine(directory, "Invoke-DeskBridgeHeadless.ps1")) +
            " -SuccessReceipt -Operation " + request.Operation);
        start.UseShellExecute = false;
        start.WorkingDirectory = directory;
        int result = RunAndWait(start);
        return InterpretHeadlessResult(result, HasSetupSuccessReceipt(directory), HasZeroLengthReceipt(directory, "reboot-required"), HasZeroLengthReceipt(directory, "recovery-blocked"));
    }

    internal static void AssertVirtualDisplayInstallAllowed()
    {
        // No accepted candidate exists in this release. This compiled gate denies
        // installation before reading/copying the ZIP or starting PowerShell,
        // independently of mutable UI metadata. Removal remains available.
        throw new InvalidOperationException("외부 드라이버의 보안 검토가 끝날 때까지 가상 화면 설치를 보류했습니다.");
    }

    internal static int InterpretHeadlessResult(int result, bool completed, bool rebootRequired, bool recoveryBlocked)
    {
        if (result == 13 && !completed && !rebootRequired && recoveryBlocked) return 13;
        if (recoveryBlocked) throw new InvalidOperationException("가상 화면 복구 확인 정보가 일치하지 않습니다.");
        if (result == 0 && completed && !rebootRequired) return 0;
        // Receipts distinguish completed installation from incomplete rollback/removal.
        if (result == 3010 && completed && rebootRequired) return 3010;
        if (result == 12 && !completed && rebootRequired) return 12;
        if (result == 2 && !completed && !rebootRequired) return 2;
        throw new InvalidOperationException("가상 화면 작업을 완료하지 못했습니다. 상태를 다시 확인한 뒤 복구 안내를 따르세요.");
    }

    internal static bool HasSetupSuccessReceipt(string directory)
    {
        return HasZeroLengthReceipt(directory, "operation-success");
    }

    private static bool HasZeroLengthReceipt(string directory, string name)
    {
        string path = Path.Combine(directory, name);
        try
        {
            if ((File.GetAttributes(path) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0) return false;
            using (var receipt = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                return receipt.Length == 0;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    internal static int InterpretSetupResult(int result, bool silent, bool hasSuccessReceipt)
    {
        // powershell.exe -File may exit zero on Ctrl+C; zero alone does not attest completion.
        if (result == 0 && hasSuccessReceipt) return 0;
        if (result == 2 && !silent) return 2; // The fixed script printed and acknowledged this error.
        throw new InvalidOperationException("파일 설정을 시작하거나 완료하지 못했습니다. 조직의 스크립트 실행 정책과 설치 안내를 확인하세요.");
    }

    private static int InterpretSetupHostResult(int result)
    {
        // These role choices belong only to the normal setup UI, not broker results.
        if (result == 0 || result == 10 || result == 11 || result == 12) return result;
        throw new InvalidOperationException("설정 창을 열지 못했거나 정상 종료하지 못했습니다. Knot을 다시 열고, 계속 실패하면 Windows 관리자에게 아래 진단을 전달하세요.\n\n진단: setup-ui.child-exit / code " + DiagnosticCode(result));
    }

    private static string DiagnosticCode(int code)
    {
        return unchecked((uint)code).ToString(CultureInfo.InvariantCulture);
    }

    private static string ProcessStartFailureMessage(int code)
    {
        // NativeErrorCode is evidence about Process.Start only. A child exit
        // with the same number must never be classified as a Windows block.
        string guidance;
        switch (code)
        {
            case 577:
                guidance = "Windows가 설정 프로세스의 이미지 서명을 확인하지 못해 실행을 거부했습니다. 새 Knot 배포 파일을 사용하고 Windows 보안 및 조직의 앱 실행 정책을 관리자와 확인하세요."; break;
            case 1260:
                guidance = "Windows가 그룹 정책에 따라 설정 프로세스의 실행을 차단했습니다. Windows 관리자에게 실행 승인을 확인하세요."; break;
            case 225: case 226:
                guidance = "Windows가 악성 소프트웨어 또는 원치 않는 소프트웨어 감지를 보고하며 설정 프로세스를 실행하지 못했습니다. Windows 보안의 보호 기록과 배포 파일을 관리자와 확인하세요."; break;
            case 193: case 216:
                guidance = "Windows가 설정 프로세스의 실행 파일 형식 또는 시스템 종류 문제를 보고했습니다. Windows 11 x64용 Knot 배포 파일을 다시 받아 실행하세요."; break;
            default:
                guidance = "설정 프로세스를 시작하지 못했습니다. Knot을 다시 열고, 계속 실패하면 Windows 관리자에게 아래 진단을 전달하세요."; break;
        }
        return guidance + "\n\n진단: process.start / Win32 " + DiagnosticCode(code);
    }

    private static int RunAndWait(ProcessStartInfo start)
    {
        Process child;
        try { child = Process.Start(start); }
        catch (Win32Exception error) { throw new InvalidOperationException(ProcessStartFailureMessage(error.NativeErrorCode)); }
        if (child == null) throw new InvalidOperationException(ProcessStartFailureMessage(0));
        using (child)
        {
            try { child.WaitForExit(); }
            catch (Win32Exception error)
            {
                throw new InvalidOperationException("설정 프로세스의 종료를 확인하지 못했습니다. 작업 완료 여부를 확인한 뒤 다시 시도하세요.\n\n진단: process.wait / Win32 " + DiagnosticCode(error.NativeErrorCode));
            }
            try { return child.ExitCode; }
            catch (Win32Exception error)
            {
                throw new InvalidOperationException("설정 프로세스의 종료 결과를 읽지 못했습니다. 작업 완료 여부를 확인한 뒤 다시 시도하세요.\n\n진단: process.exit-query / Win32 " + DiagnosticCode(error.NativeErrorCode));
            }
        }
    }

    private static string WindowsPowerShell()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
    }

    private static void VerifyHash(Stream stream, string expected)
    {
        using (var hash = SHA256.Create())
            if (!String.Equals(BitConverter.ToString(hash.ComputeHash(stream)).Replace("-", "").ToLowerInvariant(), expected, StringComparison.Ordinal))
                throw new InvalidDataException("설정 파일 검증에 실패했습니다. 실행하지 않았습니다.");
    }

    private static int BootstrapParentID;
    private static long BootstrapCreationFileTime;
    internal static string ParseBootstrapArguments(string[] args)
    {
        BootstrapParentID = 0; BootstrapCreationFileTime = 0;
        if (args == null || (args.Length != 2 && args.Length != 6) || args[0] != "--bootstrap-path") return null;
        if (args.Length == 6 && (args[2] != "--bootstrap-pid" || args[4] != "--bootstrap-created" ||
            !Int32.TryParse(args[3], NumberStyles.None, CultureInfo.InvariantCulture, out BootstrapParentID) || BootstrapParentID <= 0 ||
            !Int64.TryParse(args[5], NumberStyles.None, CultureInfo.InvariantCulture, out BootstrapCreationFileTime) || BootstrapCreationFileTime <= 0))
            throw new InvalidDataException("올바르지 않은 업데이트 실행 경계입니다.");
        string path = args[1];
        if (String.IsNullOrEmpty(path) || path.Length > 1024 || !Regex.IsMatch(path, @"\A[A-Za-z]:\\") ||
            path.IndexOfAny(new char[] { '"', '\r', '\n', '\0', '/' }) >= 0 || path.IndexOf(':', 2) >= 0 ||
            !path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("올바르지 않은 기본 설정 실행 파일입니다.");
        foreach (string part in path.Substring(3).Split('\\'))
            if (part.Length == 0 || part == "." || part == ".." || part.EndsWith(".", StringComparison.Ordinal) || part.EndsWith(" ", StringComparison.Ordinal))
                throw new InvalidDataException("올바르지 않은 기본 설정 실행 파일 경로입니다.");
        return path;
    }

    internal static BrokerRequest ParseBrokerArguments(string[] args)
    {
        if (args == null) throw new InvalidDataException("올바르지 않은 관리자 작업입니다.");
        if (args.Length == 0) return null;
        if (args.Length < 2 || args[0] != "--elevated-operation") throw new InvalidDataException("올바르지 않은 관리자 작업입니다.");
        var request = new BrokerRequest(); request.Operation = args[1];
        if (request.Operation == "DisableFiles")
        {
            if (args.Length != 2 && !(args.Length == 3 && args[2] == "--silent"))
                throw new InvalidDataException("올바르지 않은 관리자 작업입니다.");
            request.Silent = args.Length == 3;
            return request;
        }
        if (request.Operation == "QuickSetupSunshine")
        {
            if (args.Length != 2) throw new InvalidDataException("올바르지 않은 빠른 설정 요청입니다.");
            return request;
        }
        if (request.Operation == "InstallSunshine" || request.Operation == "InstallSunshineAndSetup")
        {
            if (args.Length != 4 || args[2] != "--msi-path") throw new InvalidDataException("올바르지 않은 설치 요청입니다.");
            ValidateMsiPath(args[3]); request.MsiPath = args[3]; return request;
        }
        if (request.Operation == "InstallVirtualDisplay")
        {
            if (args.Length != 4 || args[2] != "--zip-path") throw new InvalidDataException("올바르지 않은 가상 화면 설치 요청입니다.");
            ValidatePackagePath(args[3], ".zip"); request.ZipPath = args[3]; return request;
        }
        if (request.Operation == "RemoveVirtualDisplay")
        {
            if (args.Length != 2) throw new InvalidDataException("올바르지 않은 가상 화면 제거 요청입니다.");
            return request;
        }
        bool enable = request.Operation == "EnableFiles";
        if ((!enable && request.Operation != "Export") || args.Length != (enable ? 8 : 6) ||
            args[2] != "--request-base64" || args[4] != "--windows-address" || (enable && args[6] != "--desktop-user-sid"))
            throw new InvalidDataException("올바르지 않은 관리자 작업입니다.");
        string encoded = args[3];
        if (String.IsNullOrEmpty(encoded) || encoded.Length > 21848 || !Regex.IsMatch(encoded, @"\A[A-Za-z0-9+/]*={0,2}\z"))
            throw new InvalidDataException("설정 요청이 너무 크거나 올바르지 않습니다.");
        try
        {
            byte[] bytes = Convert.FromBase64String(encoded);
            if (bytes.Length == 0 || bytes.Length > 16384 || Convert.ToBase64String(bytes) != encoded)
                throw new InvalidDataException("설정 요청이 너무 크거나 올바르지 않습니다.");
            request.RequestJson = new UTF8Encoding(false, true).GetString(bytes);
            // Full public-request schema validation is performed again by the fixed protected script.
            if (request.RequestJson.IndexOf('\0') >= 0) throw new InvalidDataException("올바르지 않은 설정 요청입니다.");
        }
        catch (FormatException) { throw new InvalidDataException("올바르지 않은 설정 요청입니다."); }
        catch (DecoderFallbackException) { throw new InvalidDataException("올바르지 않은 설정 요청입니다."); }
        ValidatePrivateIPv4(args[5]); request.WindowsAddress = args[5];
        if (enable)
        {
            if (args[7] == null || args[7].Length > 80 || !Regex.IsMatch(args[7], @"\AS-1-5-21-[0-9]{1,10}-[0-9]{1,10}-[0-9]{1,10}-[0-9]{1,10}\z"))
                throw new InvalidDataException("올바르지 않은 Windows 사용자입니다.");
            foreach (string part in args[7].Substring(9).Split('-'))
            {
                uint value;
                if (!UInt32.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out value) || value.ToString(CultureInfo.InvariantCulture) != part)
                    throw new InvalidDataException("올바르지 않은 Windows 사용자입니다.");
            }
            request.DesktopUserSid = args[7];
        }
        return request;
    }

    internal static void ValidateMsiPath(string path)
    {
        ValidatePackagePath(path, ".msi");
    }

    private static void ValidatePackagePath(string path, string extension)
    {
        if (String.IsNullOrEmpty(path) || path.Length > 1024 || !Regex.IsMatch(path, @"\A[A-Za-z]:\\") ||
            path.IndexOfAny(new char[] { '"', '\r', '\n', '\0', '/', '<', '>', '|', '?', '*' }) >= 0 || path.IndexOf(':', 2) >= 0 ||
            !path.EndsWith(extension, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("올바른 로컬 설치 파일이 필요합니다.");
        foreach (char value in path)
            if (value < 32) throw new InvalidDataException("올바른 로컬 설치 파일이 필요합니다.");
        foreach (string part in path.Substring(3).Split('\\'))
            if (part.Length == 0 || part == "." || part == ".." || part.EndsWith(".", StringComparison.Ordinal) || part.EndsWith(" ", StringComparison.Ordinal))
                throw new InvalidDataException("올바르지 않은 설치 경로입니다.");
    }

    internal static SunshinePin ParseSunshinePin(string metadata)
    {
        if (metadata == null || metadata.Length > 8192) throw new InvalidDataException("올바르지 않은 Sunshine 고정 정보입니다.");
        MatchCollection hashes = Regex.Matches(metadata, "\"sha256\"\\s*:\\s*\"([0-9a-f]{64})\"");
        MatchCollection sizes = Regex.Matches(metadata, "\"bytes\"\\s*:\\s*([0-9]+)");
        long bytes;
        if (hashes.Count != 1 || sizes.Count != 1 || !Int64.TryParse(sizes[0].Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out bytes) || bytes < 1 || bytes > 268435456)
            throw new InvalidDataException("올바르지 않은 Sunshine 고정 정보입니다.");
        return new SunshinePin { Sha256 = hashes[0].Groups[1].Value, Bytes = bytes };
    }

    private static void ValidatePrivateIPv4(string address)
    {
        IPAddress parsed;
        if (!IPAddress.TryParse(address, out parsed) || parsed.AddressFamily != AddressFamily.InterNetwork || parsed.ToString() != address)
            throw new InvalidDataException("LAN 또는 Tailscale IPv4 주소가 필요합니다.");
        byte[] b = parsed.GetAddressBytes();
        if (!(b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) ||
            (b[0] == 100 && b[1] >= 64 && b[1] <= 127) || (b[0] == 169 && b[1] == 254)))
            throw new InvalidDataException("LAN 또는 Tailscale IPv4 주소가 필요합니다.");
    }

    internal static string Quote(string path)
    {
        if (String.IsNullOrEmpty(path) || path.IndexOfAny(new char[] { '"', '\r', '\n', '\0' }) >= 0 || path.EndsWith("\\", StringComparison.Ordinal))
            throw new InvalidDataException("올바르지 않은 설정 경로입니다.");
        return "\"" + path + "\"";
    }

    internal static void ValidateName(string name)
    {
        if (String.IsNullOrEmpty(name) || name == "." || name == ".." || name.IndexOfAny(new char[] { '/', '\\', ':', '\0' }) >= 0 || Path.GetFileName(name) != name)
            throw new InvalidDataException("올바르지 않은 설정 파일 이름입니다.");
    }

    private static void AssertOrdinaryAncestors(string path)
    {
        for (var current = new DirectoryInfo(path); current != null; current = current.Parent)
            if (!current.Exists || (current.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("설정 임시 폴더에 연결 경로를 사용할 수 없습니다.");
    }

    private static bool TrustedOwner(string sid)
    {
        return sid == "S-1-5-18" || sid == "S-1-5-32-544" || sid == "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";
    }

    internal static void AssertProtectedAncestors(string path)
    {
        AssertOrdinaryAncestors(path);
        var unsafeRights = FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership | (FileSystemRights)0x50000000;
        for (var current = new DirectoryInfo(path); current != null; current = current.Parent)
        {
            DirectorySecurity acl = current.GetAccessControl();
            if (!TrustedOwner(acl.GetOwner(typeof(SecurityIdentifier)).Value)) throw new IOException("관리자 전용 설치 경로가 필요합니다.");
            foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
                if (rule.AccessControlType == AccessControlType.Allow && (rule.PropagationFlags & PropagationFlags.InheritOnly) == 0 &&
                    !TrustedOwner(rule.IdentityReference.Value) && (rule.FileSystemRights & unsafeRights) != 0)
                    throw new IOException("관리자 전용 설치 경로가 필요합니다.");
        }
    }

    private static string CreatePrivateDirectory(string parent, SecurityIdentifier owner, bool elevated)
    {
        parent = Path.GetFullPath(parent);
        if (parent.StartsWith("\\\\", StringComparison.Ordinal)) throw new IOException("로컬 임시 폴더가 필요합니다.");
        AssertOrdinaryAncestors(parent);
        var acl = new DirectorySecurity();
        acl.SetOwner(owner);
        acl.SetAccessRuleProtection(true, false);
        var allowed = new List<SecurityIdentifier>();
        if (!elevated) allowed.Add(owner);
        allowed.Add(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null));
        allowed.Add(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
        foreach (SecurityIdentifier sid in allowed)
            acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        byte[] descriptor = acl.GetSecurityDescriptorBinaryForm();
        GCHandle pinned = GCHandle.Alloc(descriptor, GCHandleType.Pinned);
        try
        {
            string path = Path.Combine(parent, (elevated ? "DeskBridgeElevated-" : "DeskBridgeSetup-") + Guid.NewGuid().ToString("N"));
            var attributes = new SecurityAttributes();
            attributes.Length = Marshal.SizeOf(typeof(SecurityAttributes));
            attributes.Descriptor = pinned.AddrOfPinnedObject();
            if (!CreateDirectory(path, ref attributes)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return path;
        }
        finally { pinned.Free(); }
    }
}
