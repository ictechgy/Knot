// SPDX-License-Identifier: GPL-3.0-only
// Loads metadata/resources and invokes pure path validators only; never calls Main.
using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Reflection.PortableExecutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

internal static class Checks
{
    private static int count;
    private static void Expect(bool value, string message)
    { if (!value) throw new Exception(message); count++; }
    private static void Main(string[] args)
    {
        if (args.Length < 1 || args.Length > 3) throw new ArgumentException("Expected managed payload, optional fresh BMP output and optional fresh Mac QR fixture");
        var executable = Path.GetFullPath(args[0]);
        using var pe = new PEReader(File.OpenRead(executable));
        Expect(pe.PEHeaders.PEHeader!.Subsystem == Subsystem.WindowsGui, "Console subsystem would expose a terminal");
        var flags = pe.PEHeaders.CorHeader!.Flags;
        Expect((flags & CorFlags.ILOnly) != 0 && (flags & (CorFlags.Requires32Bit | CorFlags.Prefers32Bit)) == 0,
            "The launcher must use the 64-bit CLR on supported x64 Windows");
        var assembly = Assembly.LoadFile(executable);
        Expect(!File.Exists(Path.Combine(Path.GetDirectoryName(executable)!, "DeskBridge.QrDecoder.dll")),
            "Packaged binding fixture must not have an adjacent decoder DLL");
        using var manifest = JsonDocument.Parse(File.ReadAllText(Path.ChangeExtension(executable, ".build.json")));
        var resources = assembly.GetManifestResourceNames();
        foreach (var entry in manifest.RootElement.GetProperty("payloadSha256").EnumerateObject())
        {
            var name = "DeskBridge.Payload." + entry.Name;
            Expect(resources.Contains(name), "Missing embedded resource");
            using var stream = assembly.GetManifestResourceStream(name)!;
            Expect(Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant() == entry.Value.GetString(), "Embedded resource differs from exact build input");
        }
        var extraResources = manifest.RootElement.GetProperty("extraResources");
        foreach (var entry in extraResources.EnumerateObject())
        {
            Expect(resources.Contains(entry.Name), "Missing embedded reverse client resource");
            using var stream = assembly.GetManifestResourceStream(entry.Name)!;
            Expect(Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant() == entry.Value.GetString(), "Reverse resource differs from exact build input");
        }
        Expect(resources.Length == manifest.RootElement.GetProperty("payloadSha256").EnumerateObject().Count() + extraResources.EnumerateObject().Count(), "Unexpected embedded payload");
        var decoderLoader = assembly.GetType("DeskBridge.Reverse.ReverseQrLibrary", true)!;
        var initializeDecoder = decoderLoader.GetMethod("Initialize", BindingFlags.Static | BindingFlags.NonPublic)!;
        initializeDecoder.Invoke(null, null);
        Expect(AppDomain.CurrentDomain.GetAssemblies().Any(a => a.GetName().Name == "DeskBridge.QrDecoder"), "Compiled decoder resource did not load");
        // This call must precede resolver-shape assertions: the old loader can load
        // resource bytes while the adapter's real external reference remains unresolved.
        var adapter = assembly.GetType("DeskBridge.Reverse.ReverseQrReader", true)!;
        var readLuminance = adapter.GetMethod("ReadLuminance", BindingFlags.Static | BindingFlags.NonPublic)!;
        bool blankRejected = false;
        try { readLuminance.Invoke(null, new object[] { Enumerable.Repeat((byte)255, 64 * 64).ToArray(), 64, 64 }); }
        catch (TargetInvocationException error) when (error.InnerException is InvalidDataException) { blankRejected = true; }
        Expect(blankRejected, "Packaged adapter accepted a blank luminance fixture");
        const string decoderIdentity = "DeskBridge.QrDecoder, Version=0.0.0.0, Culture=neutral, PublicKeyToken=null";
        var resolveDecoder = decoderLoader.GetMethod("Resolve", BindingFlags.Static | BindingFlags.NonPublic)!;
        Assembly ResolveDecoder(string name) => (Assembly)resolveDecoder.Invoke(null, new object?[] { null, new ResolveEventArgs(name, assembly) })!;
        var resolvedDecoder = ResolveDecoder(decoderIdentity);
        Expect(resolvedDecoder != null && resolvedDecoder.FullName == decoderIdentity, "Resolver did not return the exact verified decoder identity");
        int decoderAssemblyCount = AppDomain.CurrentDomain.GetAssemblies().Count(a => a.FullName == decoderIdentity);
        initializeDecoder.Invoke(null, null);
        Expect(ReferenceEquals(resolvedDecoder, ResolveDecoder(decoderIdentity)) &&
            AppDomain.CurrentDomain.GetAssemblies().Count(a => a.FullName == decoderIdentity) == decoderAssemblyCount,
            "Decoder initialization must be idempotent and preserve the verified cached assembly");
        foreach (string identity in new[] { "Other.Decoder, Version=0.0.0.0, Culture=neutral, PublicKeyToken=null",
            "DeskBridge.QrDecoder, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null",
            "DeskBridge.QrDecoder, Version=0.0.0.0, Culture=ko-KR, PublicKeyToken=null",
            "DeskBridge.QrDecoder, Version=0.0.0.0, Culture=neutral, PublicKeyToken=0123456789abcdef" })
            Expect(ResolveDecoder(identity) == null, "Resolver must reject a different decoder identity/version/culture/token");
        var launcher = assembly.GetType("Launcher", true)!;
        var quote = launcher.GetMethod("Quote", BindingFlags.Static | BindingFlags.NonPublic)!;
        var validate = launcher.GetMethod("ValidateName", BindingFlags.Static | BindingFlags.NonPublic)!;
        foreach (var path in new[] { @"C:\테스트 폴더\setup.ps1", @"C:\one&two\setup.ps1", @"C:\$draft\setup.ps1" })
            Expect((string)quote.Invoke(null, new object[] { path })! == "\"" + path + "\"", "Argument boundary changed");
        foreach (var path in new[] { "", "x\" -command bad", "x\r\n-command bad", "x\0bad", "C:\\" })
            Reject(quote, path);
        foreach (var name in new[] { "Setup-DeskBridge.ps1", "LICENSE", "한국어 파일.json" })
        { validate.Invoke(null, new object[] { name }); count++; }
        foreach (var name in new[] { "", ".", "..", "../outside", @"..\outside", "name:stream", "bad\0name" })
            Reject(validate, name);
        var copyInstaller = launcher.GetMethod("CopyPinnedInstaller", BindingFlags.Static | BindingFlags.NonPublic)!;
        foreach (var input in new[] { (Bytes: new byte[7], Expected: 7L, Success: true), (Bytes: new byte[6], Expected: 7L, Success: false), (Bytes: new byte[8], Expected: 7L, Success: false), (Bytes: new byte[65537], Expected: 65537L, Success: true) })
        {
            using var source = new MemoryStream(input.Bytes);
            using var output = new MemoryStream();
            bool success = false;
            try { copyInstaller.Invoke(null, new object[] { source, output, input.Expected }); success = true; }
            catch (TargetInvocationException error) when (error.InnerException is InvalidDataException) { }
            Expect(success == input.Success, "Pinned installer copy must reject truncated or growing input");
            Expect(output.Length <= input.Expected, "Pinned installer output must never exceed its byte cap");
            if (success) Expect(output.ToArray().SequenceEqual(input.Bytes), "Pinned installer copy changed bytes");
        }
        var installerResult = launcher.GetMethod("InterpretSunshineInstallerResult", BindingFlags.Static | BindingFlags.NonPublic)!;
        foreach (int code in new[] { 0, 3010, 1641, 1618, 1602 })
            Expect((int)installerResult.Invoke(null, new object[] { code })! == code, "MSI outcome was lost before the UI boundary");
        foreach (int code in new[] { 1, 2, 12, 13, 1603, -1, Int32.MaxValue })
        {
            try { installerResult.Invoke(null, new object[] { code }); }
            catch (TargetInvocationException error) when (error.InnerException is InvalidOperationException) { count++; continue; }
            throw new Exception("Unknown MSI failure was accepted as a user outcome");
        }
        var setupResult = launcher.GetMethod("InterpretSetupResult", BindingFlags.Static | BindingFlags.NonPublic)!;
        Expect((int)setupResult.Invoke(null, new object[] { 0, false, true })! == 0 && (int)setupResult.Invoke(null, new object[] { 0, true, true })! == 0, "Successful setup must succeed in both modes");
        Expect((int)setupResult.Invoke(null, new object[] { 2, false, false })! == 2, "Only explicitly acknowledged interactive script failure is already reported");
        foreach (var input in new[] { (Code: 0, Silent: false), (Code: 0, Silent: true), (Code: 1, Silent: false), (Code: 1, Silent: true), (Code: 2, Silent: true), (Code: 7, Silent: false) })
        {
            try { setupResult.Invoke(null, new object[] { input.Code, input.Silent, false }); }
            catch (TargetInvocationException error) when (error.InnerException is InvalidOperationException) { count++; continue; }
            throw new Exception("An early/unhandled setup failure was hidden");
        }
        var headlessResult = launcher.GetMethod("InterpretHeadlessResult", BindingFlags.Static | BindingFlags.NonPublic)!;
        foreach (int code in new[] { 0, 2, 12, 13, 3010, 1, 1602 })
        foreach (bool completed in new[] { false, true })
        foreach (bool rebootRequired in new[] { false, true })
        foreach (bool recoveryBlocked in new[] { false, true })
        {
            bool accepted = !recoveryBlocked && ((code == 0 && completed && !rebootRequired) || (code == 3010 && completed && rebootRequired) || (code == 12 && !completed && rebootRequired) || (code == 2 && !completed && !rebootRequired)) || (code == 13 && !completed && !rebootRequired && recoveryBlocked);
            try
            {
                int interpreted = (int)headlessResult.Invoke(null, new object[] { code, completed, rebootRequired, recoveryBlocked })!;
                Expect(accepted && interpreted == code, "Headless status confused completion, restart, cancellation, or acknowledged failure");
            }
            catch (TargetInvocationException error) when (error.InnerException is InvalidOperationException && !accepted) { count++; }
        }
        var receiptCheck = launcher.GetMethod("HasSetupSuccessReceipt", BindingFlags.Static | BindingFlags.NonPublic)!;
        var zeroReceiptCheck = launcher.GetMethod("HasZeroLengthReceipt", BindingFlags.Static | BindingFlags.NonPublic)!;
        var receiptFixture = Path.Combine(Path.GetTempPath(), "deskbridge-receipt-checks-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(receiptFixture);
        var receiptPath = Path.Combine(receiptFixture, "operation-success");
        try
        {
            bool HasReceipt() => (bool)receiptCheck.Invoke(null, new object[] { receiptFixture })!;
            Expect(!HasReceipt(), "Missing completion receipt must not attest success");
            File.WriteAllBytes(receiptPath, Array.Empty<byte>());
            Expect(HasReceipt(), "Fresh zero-length ordinary receipt must attest completion");
            File.WriteAllText(receiptPath, "not a receipt");
            Expect(!HasReceipt(), "Nonempty receipt must not attest success");
            File.Delete(receiptPath); Directory.CreateDirectory(receiptPath);
            Expect(!HasReceipt(), "Directory cannot attest setup completion");
            Directory.Delete(receiptPath);
            var rebootReceipt = Path.Combine(receiptFixture, "reboot-required");
            bool HasRebootReceipt() => (bool)zeroReceiptCheck.Invoke(null, new object[] { receiptFixture, "reboot-required" })!;
            Expect(!HasRebootReceipt(), "Missing receipt cannot attest a pending restart");
            File.WriteAllBytes(rebootReceipt, Array.Empty<byte>());
            Expect(HasRebootReceipt() && !HasReceipt(), "Restart receipt must remain distinct from completed operation receipt");
            File.WriteAllText(rebootReceipt, "not a receipt");
            Expect(!HasRebootReceipt(), "Nonempty receipt cannot attest a pending restart");
            File.Delete(rebootReceipt); Directory.CreateDirectory(rebootReceipt);
            Expect(!HasRebootReceipt(), "Directory cannot attest a pending restart");
            Directory.Delete(rebootReceipt);
        }
        finally { Directory.Delete(receiptFixture, true); }
        var bootstrap = launcher.GetMethod("ParseBootstrapArguments", BindingFlags.Static | BindingFlags.NonPublic)!;
        Expect((string)bootstrap.Invoke(null, new object[] { new[] { "--bootstrap-path", @"C:\다운로드\DeskBridge.exe" } })! == @"C:\다운로드\DeskBridge.exe", "GUI elevation must retain the original native outer EXE path");
        Expect(bootstrap.Invoke(null, new object[] { new[] { "--bootstrap-path", @"C:\outer.exe", "--elevated-operation", "DisableFiles" } }) == null, "Bootstrap handoff must not mix with elevated operations");
        foreach (var input in new[] { "relative.exe", @"\\host\share\outer.exe", @"C:\a\..\outer.exe", @"C:\inner.dll" })
        {
            try { bootstrap.Invoke(null, new object[] { new[] { "--bootstrap-path", input } }); }
            catch (TargetInvocationException error) when (error.InnerException is InvalidDataException) { count++; continue; }
            throw new Exception("Unsafe native bootstrap path accepted");
        }
        var nativeOwner = new[] { "--bootstrap-path", @"C:\Knot\DeskBridge-Windows.exe", "--bootstrap-pid", "1234", "--bootstrap-created", "133000000000000000" };
        Expect((string)bootstrap.Invoke(null, new object[] { nativeOwner })! == nativeOwner[1], "Native update owner metadata was rejected");
        var ownerPID = launcher.GetField("BootstrapParentID", BindingFlags.Static | BindingFlags.NonPublic)!;
        var ownerTime = launcher.GetField("BootstrapCreationFileTime", BindingFlags.Static | BindingFlags.NonPublic)!;
        Expect((int)ownerPID.GetValue(null)! == 1234 && (long)ownerTime.GetValue(null)! == 133000000000000000L,
            "Native update owner metadata changed");
        bootstrap.Invoke(null, new object[] { new[] { "--bootstrap-path", @"C:\Knot\DeskBridge-Windows.exe" } });
        Expect((int)ownerPID.GetValue(null)! == 0 && (long)ownerTime.GetValue(null)! == 0,
            "Legacy handoff retained another invocation's updater owner");
        foreach (var invalidOwner in new[] {
            new[] { "--bootstrap-path", nativeOwner[1], "--bootstrap-pid", "0", "--bootstrap-created", nativeOwner[5] },
            new[] { "--bootstrap-path", nativeOwner[1], "--bootstrap-pid", "-1", "--bootstrap-created", nativeOwner[5] },
            new[] { "--bootstrap-path", nativeOwner[1], "--bootstrap-pid", "1234", "--bootstrap-created", "0" },
            new[] { "--bootstrap-path", nativeOwner[1], "--bootstrap-pid", "1234", "--bootstrap-created", "9223372036854775808" },
            new[] { "--bootstrap-path", nativeOwner[1], "--elevated-operation", "1234", "--bootstrap-created", nativeOwner[5] }
        }) {
            bool rejected = false;
            try { bootstrap.Invoke(null, new object[] { invalidOwner }); }
            catch (TargetInvocationException error) when (error.InnerException is InvalidDataException) { rejected = true; }
            Expect(rejected, "Malformed native update ownership metadata was admitted");
        }
        var broker = launcher.GetMethod("ParseBrokerArguments", BindingFlags.Static | BindingFlags.NonPublic)!;
        var msiPath = launcher.GetMethod("ValidateMsiPath", BindingFlags.Static | BindingFlags.NonPublic)!;
        var sunshinePin = launcher.GetMethod("ParseSunshinePin", BindingFlags.Static | BindingFlags.NonPublic)!;
        var headlessOperation = launcher.GetMethod("RunHeadlessOperation", BindingFlags.Static | BindingFlags.NonPublic)!;
        var blockedInstall = broker.Invoke(null, new object[] { new[] { "--elevated-operation", "InstallVirtualDisplay", "--zip-path", @"C:\synthetic-driver.zip" } })!;
        bool installBlockedBeforeIo = false;
        // Null paths/list are deliberate: reaching staging/receipts/PowerShell
        // instead of the compiled deny gate must fail this pure fixture.
        try { headlessOperation.Invoke(null, new object?[] { blockedInstall, null, null }); }
        catch (TargetInvocationException error) when (error.InnerException is InvalidOperationException) { installBlockedBeforeIo = true; }
        Expect(installBlockedBeforeIo, "Blocked driver must be refused before ZIP or process operations");
        Expect(broker.Invoke(null, new object[] { Array.Empty<string>() }) == null, "Ordinary launch must remain non-elevated GUI mode");
        var requestJson = "{\"kind\":\"deskbridge.mac-setup\",\"version\":1,\"requestID\":\"11111111-1111-4111-8111-111111111111\",\"clientPublicKey\":\"synthetic public key\",\"allowedClientAddresses\":[\"192.168.1.10\"]}";
        var encodedRequest = Convert.ToBase64String(Encoding.UTF8.GetBytes(requestJson));
        var exportArgs = new[] { "--elevated-operation", "Export", "--request-base64", encodedRequest, "--windows-address", "192.168.1.20" };
        var export = broker.Invoke(null, new object[] { exportArgs })!;
        string? Field(object value, string name) => (string?)value.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(value);
        Expect(Field(export, "Operation") == "Export" && Field(export, "RequestJson") == requestJson && Field(export, "WindowsAddress") == "192.168.1.20" && Field(export, "DesktopUserSid") == null,
            "Broker must retain exact public snapshot/address without a caller request-file path");
        var enableArgs = exportArgs.ToArray(); enableArgs[1] = "EnableFiles";
        enableArgs = enableArgs.Concat(new[] { "--desktop-user-sid", "S-1-5-21-1-2-3-1001" }).ToArray();
        Expect(Field(broker.Invoke(null, new object[] { enableArgs })!, "DesktopUserSid") == "S-1-5-21-1-2-3-1001", "Original desktop SID must cross UAC exactly");
        Expect(Field(broker.Invoke(null, new object[] { new[] { "--elevated-operation", "DisableFiles" } })!, "RequestJson") == null, "Revocation must not accept public request or result paths");
        var silentDisable = broker.Invoke(null, new object[] { new[] { "--elevated-operation", "DisableFiles", "--silent" } })!;
        Expect((bool)silentDisable.GetType().GetField("Silent", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(silentDisable)! && Field(silentDisable, "RequestJson") == null,
            "Silent uninstall must revoke without dialog/request/result paths");
        var visibleDisable = broker.Invoke(null, new object[] { new[] { "--elevated-operation", "DisableFiles" } })!;
        Expect(!(bool)visibleDisable.GetType().GetField("Silent", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(visibleDisable)!, "Ordinary revocation must retain visible error guidance");
        RejectBroker(broker, new[] { "--elevated-operation", "DisableFiles", "--silent", "extra" });
        RejectBroker(broker, exportArgs.Concat(new[] { "--silent" }).ToArray());
        RejectBroker(broker, enableArgs.Concat(new[] { "--silent" }).ToArray());
        RejectBroker(broker, new[] { "--elevated-operation", "InstallSunshine", "--msi-path", @"C:\good.msi", "--silent" });

        foreach (var address in new[] { "10.0.0.1", "172.16.0.1", "192.168.1.20", "100.64.0.1", "169.254.1.2" })
        { var input = exportArgs.ToArray(); input[5] = address; broker.Invoke(null, new object[] { input }); count++; }
        foreach (var input in new[] {
            new[] { "--elevated-operation" }, new[] { "--elevated-operation", "anything" },
            new[] { "--elevated-operation", "DisableFiles", "--request-path", @"C:\evil.ps1" },
            new[] { "--elevated-operation", "Export", "--request-path", @"C:\request.json", "--windows-address", "10.0.0.1" },
            exportArgs.Concat(new[] { "--script-path", @"C:\evil.ps1" }).ToArray(),
            exportArgs.Concat(new[] { "--result-path", @"C:\output.json" }).ToArray(),
            new[] { "--elevated-operation", "EnableFiles", "--request-base64", encodedRequest, "--windows-address", "10.0.0.1" },
            new[] { "--elevated-operation", "InstallSunshine", "--msi-path", @"C:\good.msi", "--sha256", new string('a',64) },
            new[] { "--elevated-operation", "InstallSunshine", "--url", "https://example.invalid/a.msi" },
            new[] { "-File", @"C:\evil.ps1" }
        }) RejectBroker(broker, input);
        foreach (var encoded in new[] { "", "not-base64", encodedRequest + "=", " " + encodedRequest, Convert.ToBase64String(new byte[] { 0xff, 0xff }), Convert.ToBase64String(Encoding.UTF8.GetBytes("a\0b")), Convert.ToBase64String(new byte[16385]) })
        { var input = exportArgs.ToArray(); input[3] = encoded; RejectBroker(broker, input); }
        var maximum = exportArgs.ToArray(); maximum[3] = Convert.ToBase64String(Encoding.UTF8.GetBytes(new string(' ', 16384)));
        broker.Invoke(null, new object[] { maximum }); count++;
        foreach (var address in new[] { "8.8.8.8", "127.0.0.1", "localhost", "::1", "192.168.01.1", "100.128.1.1", "10.0.0.1/24", "10.0.0.1 --arg" })
        { var input = exportArgs.ToArray(); input[5] = address; RejectBroker(broker, input); }
        foreach (var sid in new[] { "S-1-5-32-544", "S-1-5-21-1-2-3-4294967296", "S-1-5-21-01-2-3-1001", "S-1-5-21-1-2-3-1001 --arg", "S-1-5-21-1-2-3-1001\n" })
        { var input = enableArgs.ToArray(); input[7] = sid; RejectBroker(broker, input); }
        foreach (var path in new[] { @"C:\새 폴더\Sunshine.msi", @"D:\one&two\installer.MSI" })
        {
            msiPath.Invoke(null, new object[] { path }); count++;
            Expect(Field(broker.Invoke(null, new object[] { new[] { "--elevated-operation", "InstallSunshine", "--msi-path", path } })!, "MsiPath") == path, "Broker install must retain only the bounded data path");
        }
        foreach (var path in new[] { "relative.msi", @"\\host\share\x.msi", @"C:\x.msi:evil", @"C:\..\x.msi", @"C:\a\.\x.msi", @"C:\a\\x.msi", @"C:\a.\x.msi", "C:/x.msi", @"C:\x.msi"" --arg", @"C:\x.exe", @"C:\" + new string('a',1024) + ".msi" })
            Reject(msiPath, path);
        foreach (var path in new[] { @"C:\새 폴더\VirtualDisplay.ZIP", @"D:\one&two\driver.zip", @"C:\$fixture\driver.zip", @"C:\" + new string('a',1017) + ".zip" })
        {
            var install = broker.Invoke(null, new object[] { new[] { "--elevated-operation", "InstallVirtualDisplay", "--zip-path", path } })!;
            Expect(Field(install, "Operation") == "InstallVirtualDisplay" && Field(install, "ZipPath") == path && Field(install, "MsiPath") == null,
                "Virtual display install must retain exactly the bounded ZIP path");
        }
        var removeDisplay = broker.Invoke(null, new object[] { new[] { "--elevated-operation", "RemoveVirtualDisplay" } })!;
        Expect(Field(removeDisplay, "Operation") == "RemoveVirtualDisplay" && Field(removeDisplay, "ZipPath") == null && Field(removeDisplay, "RequestJson") == null,
            "Virtual display removal must not accept caller-selected paths or device identity");
        foreach (var input in new[] {
            new[] { "--elevated-operation", "InstallVirtualDisplay" },
            new[] { "--elevated-operation", "InstallVirtualDisplay", "--zip-path" },
            new[] { "--elevated-operation", "InstallVirtualDisplay", "--msi-path", @"C:\driver.zip" },
            new[] { "--elevated-operation", "InstallVirtualDisplay", "--zip-path", @"C:\driver.zip", "--silent" },
            new[] { "--elevated-operation", "InstallVirtualDisplay", "--zip-path", @"C:\driver.zip", "--sha256", new string('a',64) },
            new[] { "--elevated-operation", "InstallVirtualDisplay", "--url", "https://example.invalid/driver.zip" },
            new[] { "--elevated-operation", "RemoveVirtualDisplay", "--silent" },
            new[] { "--elevated-operation", "RemoveVirtualDisplay", "--instance-id", @"ROOT\FOREIGN\0000" },
            new[] { "--elevated-operation", "RemoveVirtualDisplay", "--zip-path", @"C:\driver.zip" },
            new[] { "--elevated-operation", "RemoveVirtualDisplay", "--script-path", @"C:\evil.ps1" }
        }) RejectBroker(broker, input);
        foreach (var path in new[] { "", "relative.zip", @"C:relative.zip", @"\\host\share\driver.zip", @"\\?\C:\driver.zip", "C:/driver.zip",
            @"C:\a\..\driver.zip", @"C:\a\.\driver.zip", @"C:\a\\driver.zip", @"C:\a.\driver.zip", @"C:\a \driver.zip", @"C:\driver.zip:stream",
            @"C:\driver.zip.exe", @"C:\driver.msi", @"C:\*.zip", @"C:\driver.zip"" --arg", @"C:\" + new string('a',1018) + ".zip" })
            RejectBroker(broker, new[] { "--elevated-operation", "InstallVirtualDisplay", "--zip-path", path });
        for (int control = 0; control < 32; control++)
            RejectBroker(broker, new[] { "--elevated-operation", "InstallVirtualDisplay", "--zip-path", @"C:\fixture" + (char)control + "a.zip" });
        foreach (var dependencyName in new[] { "SunshineDependency.json", "VirtualDisplayDependency.json" })
        using (var dependencyStream = assembly.GetManifestResourceStream("DeskBridge.Payload." + dependencyName)!)
        using (var dependencyReader = new StreamReader(dependencyStream))
        {
            var dependencyJson = dependencyReader.ReadToEnd();
            using var dependency = JsonDocument.Parse(dependencyJson);
            var pin = sunshinePin.Invoke(null, new object[] { dependencyJson })!;
            Expect(Field(pin, "Sha256") == dependency.RootElement.GetProperty("sha256").GetString(), "Broker hash authority must come from the embedded dependency");
            Expect((long)pin.GetType().GetField("Bytes", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(pin)! == dependency.RootElement.GetProperty("bytes").GetInt64(), "Broker size authority must come from the embedded dependency");
        }
        foreach (var metadata in new[] { "{}", "{\"sha256\":\"bad\",\"bytes\":1}", "{\"sha256\":\"" + new string('a',64) + "\",\"bytes\":0}", "{\"sha256\":\"" + new string('a',64) + "\",\"bytes\":268435457}", "{\"sha256\":\"" + new string('a',64) + "\",\"sha256\":\"" + new string('b',64) + "\",\"bytes\":1}" })
            Reject(sunshinePin, metadata);
        using var qrResource = assembly.GetManifestResourceStream("DeskBridge.Payload.DeskBridge-QR.dll")!;
        using var qrBytes = new MemoryStream(); qrResource.CopyTo(qrBytes);
        var qrAssembly = Assembly.Load(qrBytes.ToArray());
        var qrType = qrAssembly.GetType("Net.Codecrete.QrCodeGenerator.QrCode", true)!;
        var ecc = qrType.GetNestedType("Ecc")!;
        var medium = ecc.GetField("Medium")!.GetValue(null)!;
        var text = "deskbridge://connect?v=1&name=Synthetic%20PC&address=192.168.1.20&address=100.80.10.20";
        var qr = qrType.GetMethod("EncodeText")!.Invoke(null, new[] { (object)text, medium })!;
        var size = (int)qrType.GetProperty("Size")!.GetValue(qr)!;
        Expect(size >= 21 && size <= 177, "Actual pinned QR generator returned an invalid matrix");
        var bmp = (byte[])qrType.GetMethod("ToBmpBitmap", new[] { typeof(int), typeof(int) })!.Invoke(qr, new object[] { 4, 6 })!;
        Expect(bmp[0] == (byte)'B' && bmp[1] == (byte)'M', "Actual QR bitmap encoder failed");
        // Exercise the production adapter's external assembly reference after its actual
        // packaged loader has initialized. No adjacent decoder DLL is available here.
        int scale = 4, quiet = 4, side = (size + quiet * 2) * scale;
        var luminance = Enumerable.Repeat((byte)255, side * side).ToArray();
        var getModule = qrType.GetMethod("GetModule")!;
        for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
            if ((bool)getModule.Invoke(qr, new object[] { x, y })!)
                for (int dy = 0; dy < scale; dy++) for (int dx = 0; dx < scale; dx++)
                    luminance[((y + quiet) * scale + dy) * side + (x + quiet) * scale + dx] = 0;
        Expect((string)readLuminance.Invoke(null, new object[] { luminance, side, side })! == text,
            "Packaged adapter could not bind and decode a fresh product-generated QR using the embedded decoder");
        bool macToWindowsQRInterop = false;
        string? macToWindowsQRFixtureSha256 = null;
        if (args.Length == 3)
        {
            var input = new FileInfo(args[2]);
            Expect(input.Length > 0 && input.Length <= 8 * 1024 * 1024, "Mac QR fixture exceeds its size bound");
            byte[] fixtureBytes = File.ReadAllBytes(input.FullName);
            using var fixture = JsonDocument.Parse(fixtureBytes);
            string expectedLink = fixture.RootElement.GetProperty("link").GetString()!;
            int width = fixture.RootElement.GetProperty("width").GetInt32(), height = fixture.RootElement.GetProperty("height").GetInt32();
            Expect(width > 0 && height > 0 && width <= 2048 && height <= 2048, "Mac QR luminance dimensions exceed adapter limits");
            byte[] macLuminance = Convert.FromBase64String(fixture.RootElement.GetProperty("luminance").GetString()!);
            Expect(macLuminance.Length == checked(width * height), "Mac QR luminance length mismatch");
            string decoded = (string)readLuminance.Invoke(null, new object[] { macLuminance, width, height })!;
            Expect(decoded == expectedLink, "Production Windows decoder changed the actual Mac PNG-chain QR payload");
            var policy = assembly.GetType("DeskBridge.Reverse.ConnectionPolicy", true)!;
            object invitation = policy.GetMethod("Parse", BindingFlags.Public | BindingFlags.Static)!.Invoke(null, new object[] { decoded })!;
            Expect((string)invitation.GetType().GetProperty("Name")!.GetValue(invitation)! == "Knot Mac", "Actual Mac QR name did not survive Windows policy parsing");
            var addresses = (System.Collections.IEnumerable)invitation.GetType().GetProperty("Addresses")!.GetValue(invitation)!;
            Expect(addresses.Cast<string>().SequenceEqual(new[] { "192.168.50.20" }), "Actual Mac QR selected address did not survive Windows policy parsing");
            macToWindowsQRFixtureSha256 = Convert.ToHexString(SHA256.HashData(fixtureBytes)).ToLowerInvariant();
            macToWindowsQRInterop = true;
        }
        if (args.Length >= 2) File.WriteAllBytes(args[1], bmp);
        Console.WriteLine(JsonSerializer.Serialize(new { status = "passed", checks = count,
            embeddedDecoderBindingTested = true, embeddedDecoderSha256 = extraResources.GetProperty("DeskBridge.Reverse.QrDecoder").GetString(),
            decoderIdentity = decoderIdentity, decoderResolverIdentityTested = true, decoderInitializationIdempotent = true,
            macToWindowsQRInterop, macToWindowsQRFixtureSha256,
            scope = "actual compiled Windows payload/broker arguments, embedded installer pin and QR bitmap generator; no Windows Main/UAC/UI/ACL/services executed" }));
    }
    private static void RejectBroker(MethodInfo method, string[] input)
    {
        try { method.Invoke(null, new object[] { input }); }
        catch (TargetInvocationException error) when (error.InnerException is InvalidDataException) { count++; return; }
        throw new Exception("Unsafe elevated broker request accepted");
    }
    private static void Reject(MethodInfo method, string input)
    {
        try { method.Invoke(null, new object[] { input }); }
        catch (TargetInvocationException error) when (error.InnerException is InvalidDataException) { count++; return; }
        throw new Exception("Unsafe boundary accepted");
    }
}
