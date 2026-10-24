// SPDX-License-Identifier: GPL-3.0-only
// Independently compiled helper. Never accepts an URL, publisher, key, command or installer name.
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Knot.Updates
{
    internal static class UpdateSecurity
    {
        internal const string InstallerName = "Knot-update.exe";
        internal const long MaximumInstallerBytes = 536870912;
        internal const uint Synchronize = 0x00100000, QueryLimited = 0x1000;
        internal const uint WaitObject = 0, WaitTimeout = 258;

        // Runtime-only OS registration lookup. Build/tests never read the host registry.
        // The stable Inno AppId preserves existing custom installation directories.
        internal static bool IsRegisteredInstallation(string bootstrap)
        {
            try
            {
                using (RegistryKey machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                using (RegistryKey uninstall = machine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{7BB82A17-E531-4D04-A1FA-E8912E9E8E99}_is1", false))
                {
                    if (uninstall == null || uninstall.GetValueKind("InstallLocation") != RegistryValueKind.String) return false;
                    string location = uninstall.GetValue("InstallLocation", null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
                    string expected = RegisteredExecutable(location);
                    if (expected == null || !String.Equals(expected, bootstrap, StringComparison.OrdinalIgnoreCase)) return false;
                    OrdinaryPath(expected); SafeAncestors(Path.GetDirectoryName(expected));
                    return true;
                }
            }
            catch (Exception) { return false; }
        }

        internal static string RegisteredExecutable(string location)
        {
            if (String.IsNullOrWhiteSpace(location) || location.IndexOf('\0') >= 0 || !Path.IsPathRooted(location) || location.StartsWith(@"\\", StringComparison.Ordinal)) return null;
            string directory = location.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            try
            {
                if (!String.Equals(Path.GetFullPath(directory), directory, StringComparison.OrdinalIgnoreCase)) return null;
                return Path.Combine(directory, "DeskBridge-Windows.exe");
            }
            catch (ArgumentException) { return null; } catch (NotSupportedException) { return null; } catch (PathTooLongException) { return null; }
        }

        internal static ulong VersionBuild(string version)
        {
            Match match = Regex.Match(version ?? "", @"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(preview|beta|rc)\.(0|[1-9][0-9]*))?\z", RegexOptions.CultureInvariant);
            if (!match.Success) throw new InvalidDataException("Invalid update version.");
            ulong major, minor, patch, revision = 0;
            if (!UInt64.TryParse(match.Groups[1].Value, out major) || !UInt64.TryParse(match.Groups[2].Value, out minor) ||
                !UInt64.TryParse(match.Groups[3].Value, out patch) || major > 999 || minor > 999 || patch > 999 ||
                (match.Groups[5].Success && (!UInt64.TryParse(match.Groups[5].Value, out revision) || revision > 99999)))
                throw new InvalidDataException("Invalid update version.");
            ulong phase = match.Groups[4].Value == "preview" ? 1UL : match.Groups[4].Value == "beta" ? 2UL : match.Groups[4].Value == "rc" ? 3UL : 4UL;
            return ((((major * 1000 + minor) * 1000 + patch) * 5 + phase) * 100000 + revision);
        }

        internal static bool AllowedInstallerMetadata(string product, string description, string version, string currentBuild)
        {
            try
            {
                ulong current;
                return product == "Knot" && description == "Knot Windows x64 Setup" &&
                    UInt64.TryParse(currentBuild, NumberStyles.None, CultureInfo.InvariantCulture, out current) && VersionBuild(version) > current;
            }
            catch (InvalidDataException) { return false; }
        }

        // Inno Setup's loader can retain ASCII-space resource placeholders after
        // these values. Normalize only bounded installer fields, never metadata
        // from the installed application or the semantic version policy itself.
        private static string InstallerResourceField(string value, int maximumCharacters)
        {
            if (value == null || value.Length > maximumCharacters) throw new InvalidDataException("Invalid installer metadata.");
            return value.TrimEnd(' ');
        }
        internal static bool AllowedInstallerResourceMetadata(string product, string description, string version, string currentBuild)
        {
            try
            {
                return AllowedInstallerMetadata(InstallerResourceField(product, 60), InstallerResourceField(description, 60),
                    InstallerResourceField(version, 50), currentBuild);
            }
            catch (InvalidDataException) { return false; }
        }
        internal static ulong InstallerVersionBuild(string version)
        { return VersionBuild(InstallerResourceField(version, 50)); }

        internal static string Hash(Stream input)
        {
            input.Position = 0;
            using (SHA256 algorithm = SHA256.Create())
            { string result = Hex(algorithm.ComputeHash(input)); input.Position = 0; return result; }
        }
        internal static string Hex(byte[] value) { return BitConverter.ToString(value).Replace("-", "").ToLowerInvariant(); }
        internal static bool Digest(string value) { return value != null && Regex.IsMatch(value, @"\A[0-9a-f]{64}\z", RegexOptions.CultureInvariant); }
        internal static bool PublisherMatches(bool authenticodeTrusted, string expected, string actual)
        { return authenticodeTrusted && Digest(expected) && Digest(actual) && String.Equals(expected, actual, StringComparison.Ordinal); }

        internal static void OrdinaryPath(string path)
        {
            if (String.IsNullOrWhiteSpace(path) || path.IndexOf('\0') >= 0 || path.Length > 32000 || !Path.IsPathRooted(path) ||
                !String.Equals(Path.GetFullPath(path), path, StringComparison.OrdinalIgnoreCase) || path.StartsWith(@"\\", StringComparison.Ordinal) ||
                new DriveInfo(Path.GetPathRoot(path)).DriveType != DriveType.Fixed)
                throw new InvalidDataException("Unsafe update path.");
            string current = path;
            while (!String.IsNullOrEmpty(current))
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Linked update path.");
                string parent = Path.GetDirectoryName(current);
                if (parent == current) break;
                current = parent;
            }
        }

        private static SecurityIdentifier[] Allowed(SecurityIdentifier user)
        { return new[] { user, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) }; }
        private static bool IsAllowed(SecurityIdentifier sid, SecurityIdentifier[] allowed)
        { foreach (SecurityIdentifier item in allowed) if (sid.Equals(item)) return true; return false; }

        internal static void SafeAncestors(string directory)
        {
            OrdinaryPath(directory);
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                SecurityIdentifier[] allowed = Allowed(identity.User);
                var trustedInstaller = new SecurityIdentifier("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464");
                string current = directory;
                while (!String.IsNullOrEmpty(current))
                {
                    DirectorySecurity acl = Directory.GetAccessControl(current, AccessControlSections.Owner | AccessControlSections.Access);
                    var owner = (SecurityIdentifier)acl.GetOwner(typeof(SecurityIdentifier));
                    if (!IsAllowed(owner, allowed) && !owner.Equals(trustedInstaller)) throw new InvalidDataException("Untrusted update ancestor owner.");
                    foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
                    {
                        if (rule.AccessControlType == AccessControlType.Allow && (rule.PropagationFlags & PropagationFlags.InheritOnly) == 0 &&
                            !IsAllowed((SecurityIdentifier)rule.IdentityReference, allowed) && !trustedInstaller.Equals(rule.IdentityReference) &&
                            (rule.FileSystemRights & (FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership)) != 0)
                            throw new InvalidDataException("Untrusted users can replace an update ancestor.");
                    }
                    string parent = Path.GetDirectoryName(current); if (parent == current) break; current = parent;
                }
            }
        }

        internal static void AssertPrivateDirectory(string directory)
        {
            SafeAncestors(directory);
            DirectorySecurity acl = Directory.GetAccessControl(directory, AccessControlSections.Owner | AccessControlSections.Access);
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                SecurityIdentifier[] allowed = Allowed(identity.User);
                if (!identity.User.Equals(acl.GetOwner(typeof(SecurityIdentifier))) || !acl.AreAccessRulesProtected)
                    throw new InvalidDataException("Unsafe update directory owner.");
                int rules = 0;
                foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
                {
                    if (rule.IsInherited || rule.AccessControlType != AccessControlType.Allow || !IsAllowed((SecurityIdentifier)rule.IdentityReference, allowed) ||
                        rule.FileSystemRights != FileSystemRights.FullControl || rule.InheritanceFlags != (InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit) ||
                        rule.PropagationFlags != PropagationFlags.None)
                        throw new InvalidDataException("Unsafe update directory access.");
                    rules++;
                }
                if (rules != 3) throw new InvalidDataException("Unexpected update directory access.");
            }
        }

        internal static string CreateHoldingDirectory()
        {
            string parent = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            SafeAncestors(parent);
            string directory = Path.Combine(parent, "Knot-update-" + Guid.NewGuid().ToString("N"));
            if (Directory.Exists(directory) || File.Exists(directory)) throw new IOException("Update directory already exists.");
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                DirectorySecurity acl = new DirectorySecurity();
                acl.SetOwner(identity.User); acl.SetAccessRuleProtection(true, false);
                foreach (SecurityIdentifier sid in Allowed(identity.User))
                    acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                        InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
                Directory.CreateDirectory(directory, acl);
            }
            AssertPrivateDirectory(directory);
            return directory;
        }

        internal static FileStream OpenPinnedFile(string path, string expected)
        {
            OrdinaryPath(path);
            var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            try
            {
                if (!Digest(expected) || Hash(stream) != expected) throw new InvalidDataException("Update file changed.");
                return stream;
            }
            catch { stream.Dispose(); throw; }
        }

        internal static void VerifyInstaller(FileStream lockedFile, string path, string expected)
        { VerifyInstaller(lockedFile, path, expected, KnotUpdateConfiguration.BuildNumber); }

        internal static void VerifyInstaller(FileStream lockedFile, string path, string expected, string minimumBuild)
        {
            if (lockedFile.Length < 1 || lockedFile.Length > MaximumInstallerBytes || !Digest(expected) || Hash(lockedFile) != expected)
                throw new InvalidDataException("Update file changed.");
            VerifyPublisher(lockedFile, path);
            FileVersionInfo version = FileVersionInfo.GetVersionInfo(path);
            if (!AllowedInstallerResourceMetadata(version.ProductName, version.FileDescription, version.ProductVersion, minimumBuild))
                throw new InvalidDataException("The update is not a newer Knot Windows x64 installer.");
        }

        // Read the signer selected by WinVerifyTrust, rather than independently extracting
        // a potentially different certificate from a multi-signature executable.
        internal static void VerifyPublisher(FileStream lockedFile, string path)
        {
            if (!KnotUpdateConfiguration.Configured || !Digest(KnotUpdateConfiguration.PublisherCertificateSHA256))
                throw new InvalidDataException("Update publisher is not configured.");
            IntPtr name = Marshal.StringToHGlobalUni(path), file = IntPtr.Zero;
            TrustData trust = new TrustData();
            try
            {
                TrustFile info = new TrustFile { Size = (uint)Marshal.SizeOf(typeof(TrustFile)), Path = name, File = lockedFile.SafeFileHandle.DangerousGetHandle() };
                file = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(TrustFile))); Marshal.StructureToPtr(info, file, false);
                trust.Size = (uint)Marshal.SizeOf(typeof(TrustData)); trust.UIChoice = 2; trust.RevocationChecks = 1;
                trust.UnionChoice = 1; trust.File = file; trust.StateAction = 1; trust.ProviderFlags = 0x80 | 0x2000;
                Guid action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
                if (WinVerifyTrust(new IntPtr(-1), ref action, ref trust) != 0) throw new InvalidDataException("The update signature is not trusted.");
                IntPtr provider = WTHelperProvDataFromStateData(trust.StateData);
                IntPtr signer = provider == IntPtr.Zero ? IntPtr.Zero : WTHelperGetProvSignerFromChain(provider, 0, false, 0);
                if (signer == IntPtr.Zero) throw new InvalidDataException("The update signer is unavailable.");
                ProviderSigner selected = (ProviderSigner)Marshal.PtrToStructure(signer, typeof(ProviderSigner));
                if (selected.CertificateCount < 1 || selected.Certificates == IntPtr.Zero) throw new InvalidDataException("The update signer is unavailable.");
                ProviderCertificate certificate = (ProviderCertificate)Marshal.PtrToStructure(selected.Certificates, typeof(ProviderCertificate));
                if (certificate.Certificate == IntPtr.Zero) throw new InvalidDataException("The update signer is unavailable.");
                using (var leaf = new X509Certificate2(certificate.Certificate))
                using (SHA256 algorithm = SHA256.Create())
                    if (!PublisherMatches(true, KnotUpdateConfiguration.PublisherCertificateSHA256, Hex(algorithm.ComputeHash(leaf.RawData))))
                        throw new InvalidDataException("The update publisher does not match Knot.");
            }
            finally
            {
                if (trust.StateData != IntPtr.Zero)
                { trust.StateAction = 2; Guid action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE"); WinVerifyTrust(new IntPtr(-1), ref action, ref trust); }
                if (file != IntPtr.Zero) Marshal.FreeHGlobal(file);
                Marshal.FreeHGlobal(name);
            }
        }

        internal static long CreationTime(IntPtr process)
        {
            long creation, exit, kernel, user;
            if (!GetProcessTimes(process, out creation, out exit, out kernel, out user)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return creation;
        }
        internal static void VerifyProcess(IntPtr process, int pid, long creation, string expectedPath)
        {
            if (process == IntPtr.Zero || process == new IntPtr(-1) || pid < 1 || creation < 1 || GetProcessId(process) != (uint)pid || CreationTime(process) != creation)
                throw new InvalidDataException("The original Knot process changed.");
            var path = new StringBuilder(32768); int length = path.Capacity;
            if (!QueryFullProcessImageName(process, 0, path, ref length) || !String.Equals(path.ToString(), expectedPath, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The original Knot image changed.");
        }
        internal static string Quote(string value)
        {
            if (value == null || value.IndexOf('\0') >= 0) throw new InvalidDataException("Invalid update argument.");
            var output = new StringBuilder("\""); int slashes = 0;
            foreach (char character in value)
            {
                if (character == '\\') { slashes++; continue; }
                if (character == '"') output.Append('\\', slashes * 2 + 1); else output.Append('\\', slashes);
                slashes = 0; output.Append(character);
            }
            output.Append('\\', slashes * 2); output.Append('"'); return output.ToString();
        }

        [StructLayout(LayoutKind.Sequential)] private struct TrustFile { internal uint Size; internal IntPtr Path, File, KnownSubject; }
        [StructLayout(LayoutKind.Sequential)] private struct TrustData
        { internal uint Size; internal IntPtr PolicyCallback, SIP; internal uint UIChoice, RevocationChecks, UnionChoice; internal IntPtr File; internal uint StateAction; internal IntPtr StateData, URLReference; internal uint ProviderFlags, UIContext; internal IntPtr SignatureSettings; }
        [StructLayout(LayoutKind.Sequential)] private struct ProviderSigner
        { internal uint Size; internal System.Runtime.InteropServices.ComTypes.FILETIME VerifyTime; internal uint CertificateCount; internal IntPtr Certificates; }
        [StructLayout(LayoutKind.Sequential)] private struct ProviderCertificate { internal uint Size; internal IntPtr Certificate; }
        [DllImport("wintrust.dll", ExactSpelling = true)] private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);
        [DllImport("wintrust.dll", ExactSpelling = true)] private static extern IntPtr WTHelperProvDataFromStateData(IntPtr data);
        [DllImport("wintrust.dll", ExactSpelling = true)] private static extern IntPtr WTHelperGetProvSignerFromChain(IntPtr provider, uint signer, [MarshalAs(UnmanagedType.Bool)] bool counterSigner, uint counterIndex);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CloseHandle(IntPtr value);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern uint WaitForSingleObject(IntPtr value, uint timeout);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint GetProcessId(IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref int length);
    }

    internal static class KnotUpdateHandoff
    {
        [STAThread]
        private static int Main(string[] args)
        {
            IntPtr original = IntPtr.Zero; string directory = null;
            try
            {
                long inherited, creation; int pid;
                if (!KnotUpdateConfiguration.Configured || !Environment.Is64BitProcess || args == null || args.Length != 7 || args[0] != "--knot-update-handoff-v1" ||
                    !Int64.TryParse(args[1], NumberStyles.None, CultureInfo.InvariantCulture, out inherited) || inherited <= 0 ||
                    !Int32.TryParse(args[2], NumberStyles.None, CultureInfo.InvariantCulture, out pid) ||
                    !Int64.TryParse(args[3], NumberStyles.None, CultureInfo.InvariantCulture, out creation) || !UpdateSecurity.Digest(args[6]))
                    throw new InvalidDataException("Invalid update handoff.");
                original = new IntPtr(inherited);
                using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                    if (new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator)) throw new InvalidDataException("The updater must run without administrator rights.");
                string outer = args[4]; directory = args[5];
                UpdateSecurity.AssertPrivateDirectory(directory);
                // The handle was inherited through an explicit one-handle allowlist. It remains
                // bound to the original process even after that PID exits or is reused.
                UpdateSecurity.VerifyProcess(original, pid, creation, outer);
                if (UpdateSecurity.WaitForSingleObject(original, 180000) != UpdateSecurity.WaitObject)
                    throw new InvalidOperationException("Knot did not close in time.");
                UpdateSecurity.CloseHandle(original); original = IntPtr.Zero;
                string installer = Path.Combine(directory, UpdateSecurity.InstallerName);
                UpdateSecurity.AssertPrivateDirectory(directory);
                if (!UpdateSecurity.IsRegisteredInstallation(outer)) throw new InvalidDataException("The Knot installation registration changed.");
                using (var file = UpdateSecurity.OpenPinnedFile(installer, args[6]))
                {
                    // A separate installer may have updated this registration while the old
                    // process was closing. Compare against the live signed installed version too.
                    using (var current = new FileStream(outer, FileMode.Open, FileAccess.Read, FileShare.Read))
                    {
                        UpdateSecurity.VerifyPublisher(current, outer);
                        FileVersionInfo installed = FileVersionInfo.GetVersionInfo(outer);
                        if (installed.ProductName != "Knot" || installed.FileDescription != "Knot Windows") throw new InvalidDataException("The installed Knot image changed.");
                        ulong minimum = Math.Max(UInt64.Parse(KnotUpdateConfiguration.BuildNumber, CultureInfo.InvariantCulture), UpdateSecurity.VersionBuild(installed.ProductVersion));
                        UpdateSecurity.VerifyInstaller(file, installer, args[6], minimum.ToString(CultureInfo.InvariantCulture));
                    }
                    var start = new ProcessStartInfo(installer, "/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART")
                    { UseShellExecute = true, Verb = "runas", WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System) };
                    using (Process setup = Process.Start(start))
                    {
                        if (setup == null) throw new InvalidOperationException("The update installer did not start.");
                        setup.WaitForExit();
                        if (setup.ExitCode != 0 && setup.ExitCode != 3010) throw new InvalidOperationException("The update installer did not finish successfully.");
                    }
                    // The installer must have actually advanced the registered application.
                    using (var current = new FileStream(outer, FileMode.Open, FileAccess.Read, FileShare.Read))
                    {
                        UpdateSecurity.VerifyPublisher(current, outer);
                        FileVersionInfo installed = FileVersionInfo.GetVersionInfo(outer);
                        if (installed.ProductName != "Knot" || installed.FileDescription != "Knot Windows" ||
                            UpdateSecurity.VersionBuild(installed.ProductVersion) < UpdateSecurity.InstallerVersionBuild(FileVersionInfo.GetVersionInfo(installer).ProductVersion))
                            throw new InvalidDataException("The installed Knot version was not advanced.");
                    }
                }
                // Restart the fixed original application only if its new Authenticode signer
                // still matches the compiled publisher. No pairing or identity is reset.
                UpdateSecurity.OrdinaryPath(outer);
                if (!UpdateSecurity.IsRegisteredInstallation(outer)) throw new InvalidDataException("The Knot installation registration changed.");
                using (var application = new FileStream(outer, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    UpdateSecurity.VerifyPublisher(application, outer);
                    Process.Start(new ProcessStartInfo(outer) { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(outer) });
                }
                return 0;
            }
            catch (Exception)
            {
                MessageBox.Show("Knot 업데이트를 완료하지 못했습니다. 기존 연결 정보는 유지됩니다. 공식 설치 파일로 다시 설치한 뒤 Knot을 실행하세요.", "Knot 업데이트", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return 2;
            }
            finally
            {
                if (original != IntPtr.Zero) UpdateSecurity.CloseHandle(original);
                if (directory != null)
                    try
                    {
                        UpdateSecurity.AssertPrivateDirectory(directory);
                        // Exact generated installer only; never recurse through a replaced path.
                        string installer = Path.Combine(directory, UpdateSecurity.InstallerName);
                        UpdateSecurity.OrdinaryPath(installer); File.Delete(installer);
                        // The helper image itself stays locked until process exit. Windows' temp
                        // cleanup can remove this tiny directory later; no self-delete shell runs.
                    }
                    catch (IOException) { } catch (UnauthorizedAccessException) { } catch (InvalidDataException) { }
            }
        }
    }
}
