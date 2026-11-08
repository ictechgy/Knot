// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        private static void UpdateChecks()
        {
            var disabled = new NativeUpdateConfiguration("0.1.0-native.10\n\n\n\n\n"); Check(!disabled.Configured);
            foreach (string v in new[] { "0.1.0", "0.1.0-native.0", "0.1.0-native.01", "0.1.0-native.65536", "0.1.0-native.11\n" }) UpdateReject(delegate { NativeUpdateManifest.VersionBuild(v); });
            Check(NativeUpdateManifest.VersionBuild("0.1.0-native.10") < NativeUpdateManifest.VersionBuild("0.1.0-native.11"));
            UpdateAttemptOwnershipChecks(); UpdateRuntimeSnapshotChecks();
            using (var rsa = new RSACryptoServiceProvider(2048))
            {
                rsa.PersistKeyInCsp = false;
                RSAParameters p = rsa.ExportParameters(false);
                var c = new NativeUpdateConfiguration("0.1.0-native.10\nhttps://example.com/mac.feed\nhttps://example.com/windows.feed\n" + Convert.ToBase64String(p.Modulus) + "\n" + Convert.ToBase64String(p.Exponent) + "\n");
                Check(c.Configured);
                string body = "KNOT-NATIVE-UPDATE-1\n0.1.0-native.11\n" + NativeUpdateManifest.VersionBuild("0.1.0-native.11").ToString(CultureInfo.InvariantCulture) + "\nwindows-x64\nhttps://example.com/Knot-Native-0.1.0-native.11-windows-x64-setup.exe\n5\n" + new string('a', 64) + "\n200\n";
                byte[] envelope = UpdateEnvelope(body, rsa);
                NativeUpdateManifest m = NativeUpdateManifest.Verify(envelope, c, "windows-x64", 100); Check(m.Bytes == 5 && m.Version == "0.1.0-native.11");
                UpdateReject(delegate { NativeUpdateManifest.Verify(envelope, c, "macos-arm64", 100); });
                UpdateReject(delegate { NativeUpdateManifest.Verify(envelope, c, "windows-x64", 200); });
                byte[] altered = (byte[])envelope.Clone(); altered[20] ^= 1;
                UpdateReject(delegate { NativeUpdateManifest.Verify(altered, c, "windows-x64", 100); });
                foreach (string bad in new[] { body.Replace("\n5\n", "\n0\n"), body.Replace("\n5\n", "\n536870913\n"), body.Replace(new string('a',64), new string('A',64)), body.Replace("\n200\n", "\n9999999\n") })
                    UpdateReject(delegate { NativeUpdateManifest.Verify(UpdateEnvelope(bad, rsa), c, "windows-x64", 100); });
                string expected = "Knot-Native-0.1.0-native.11-windows-x64-setup.exe";
                foreach (string name in new[] { "x" + expected, "%4b" + expected.Substring(1), expected + "/", expected + "/extra" })
                    UpdateReject(delegate { NativeUpdateManifest.Verify(UpdateEnvelope(body.Replace(expected, name), rsa), c, "windows-x64", 100); });
                UpdateInstallStateChecks(c, m);
                var newer = new NativeUpdateConfiguration("0.1.0-native.11\nhttps://example.com/mac.feed\nhttps://example.com/windows.feed\n" + Convert.ToBase64String(p.Modulus) + "\n" + Convert.ToBase64String(p.Exponent) + "\n");
                bool current = false; try { NativeUpdateManifest.Verify(envelope, newer, "windows-x64", 100); } catch (NativeUpdateCurrentException) { current = true; } Check(current);
            }
        }
        private static void UpdateAttemptOwnershipChecks()
        {
            // A late child cannot inherit publication authority after its
            // parent reports failure, even if READY arrives after cancellation.
            string root = Path.Combine(Path.GetTempPath(), "knot-update-check-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try {
                string first = Guid.NewGuid().ToString("N"), second = Guid.NewGuid().ToString("N");
                Check(NativeUpdateHandoff.ValidNonce(first)); Check(!NativeUpdateHandoff.ValidNonce(new string('A', 32)));
                NativeUpdateHandoff.WriteSignal(root, first, "cancel");
                NativeUpdateHandoff.WriteSignal(root, first, "ready");
                NativeUpdateHandoff.WriteSignal(root, first, "commit");
                Check(!NativeUpdateHandoff.MayInstall(root, first));
                Check(!NativeUpdateHandoff.MayInstall(root, second));
                NativeUpdateHandoff.WriteSignal(root, second, "ready");
                Check(!NativeUpdateHandoff.MayInstall(root, second));
                NativeUpdateHandoff.WriteSignal(root, second, "commit");
                Check(NativeUpdateHandoff.MayInstall(root, second));
                NativeUpdateHandoff.WriteSignal(root, second, "cancel");
                NativeUpdateHandoff.WriteSignal(root, second, "cancel"); // idempotent cancellation
                Check(!NativeUpdateHandoff.MayInstall(root, second));
            } finally { Directory.Delete(root, true); }
            // This is the recovery gate actually used after the helper's
            // original-process wait, including cancellation during verification.
            root = Path.Combine(Path.GetTempPath(), "knot-recovery-cancel-check-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try {
                string nonce = Guid.NewGuid().ToString("N"); int launches = 0;
                NativeUpdateHandoff.WriteSignal(root, nonce, "commit");
                var lease = new UpdateFakeChild();
                Check(!NativeUpdateRecovery.TryReopenOriginal(false, false, false,
                    delegate { return NativeUpdateHandoff.HasSignal(root, nonce, "cancel"); }, delegate {
                        NativeUpdateHandoff.WriteSignal(root, nonce, "cancel"); return lease;
                    }, delegate { ++launches; }));
                Check(launches == 0 && lease.Disposed);
                Check(!NativeUpdateRecovery.TryReopenOriginal(false, false, false,
                    delegate { return NativeUpdateHandoff.HasSignal(root, nonce, "cancel"); },
                    delegate { throw new Exception("cancelled handoff must not verify or reopen"); }, delegate { ++launches; }));
                Check(launches == 0);
                Check(!NativeUpdateRecovery.MayReopenOriginal(true, true, false, true, true));
            } finally { Directory.Delete(root, true); }
            bool revoked = false, killed = false, exited = false, cleaned = false;
            var child = new UpdateFakeChild();
            var attempt = new NativeUpdateAttempt(delegate { revoked = true; }, delegate { Check(exited); cleaned = true; },
                delegate { return exited; }, delegate { Check(revoked); killed = true; },
                delegate(int timeout) { Check(timeout == 5000 && killed); return false; }, child);
            Check(!attempt.RevokeAndStop()); Check(revoked && killed && !cleaned && !child.Disposed);
            // Completion is required before any stage/child resource cleanup.
            exited = true;
            var completed = new NativeUpdateAttempt(delegate { revoked = true; }, delegate { Check(exited); cleaned = true; },
                delegate { return exited; }, delegate { throw new Exception("must not kill an exited child"); },
                delegate(int timeout) { return true; }, child);
            Check(completed.RevokeAndStop()); Check(cleaned && child.Disposed);
        }
        private sealed class UpdateFakeChild : IDisposable
        { internal bool Disposed; public void Dispose() { Disposed = true; } }
        private static void UpdateInstallStateChecks(NativeUpdateConfiguration configuration, NativeUpdateManifest manifest)
        {
            Check(!NativeUpdateRecovery.MayReopenOriginal(true, false, false, true)); // installer timeout
            Check(NativeUpdateRecovery.MayReopenOriginal(false, false, false, true)); // failure before mutation
            Check(NativeUpdateRecovery.MayReopenOriginal(true, true, false, true)); // terminal failure, original intact
            Check(!NativeUpdateRecovery.MayReopenOriginal(true, true, false, false)); // unknown/mutated canonical
            Check(!NativeUpdateRecovery.MayReopenOriginal(true, true, true, true)); // no old-app recovery on success
            string stage = NativeUpdatePaths.CreateStage();
            bool fakeExited = false; var fake = new UpdateFakeChild();
            NativeUpdates model = null;
            try {
                model = new NativeUpdates(configuration, delegate(string holding, NativeUpdateManifest value, string nonce, System.Threading.CancellationToken token) {
                    return new NativeUpdateAttempt(delegate { NativeUpdateHandoff.WriteSignal(holding, nonce, "cancel"); }, delegate { },
                        delegate { return fakeExited; }, delegate { fakeExited = true; }, delegate(int wait) { return fakeExited; }, fake);
                }, manifest, stage);
                Check(!model.InstallAsync(delegate { throw new InvalidOperationException("synthetic beforeExit failure"); }).GetAwaiter().GetResult());
                Check(!model.Available && !model.Busy && fake.Disposed && !Directory.Exists(stage));
            } finally { if (model != null) model.Dispose(); if (Directory.Exists(stage)) Directory.Delete(stage, true); }
            stage = NativeUpdatePaths.CreateStage(); fakeExited = false; fake = new UpdateFakeChild();
            int disposePhase = 0, caller = System.Threading.Thread.CurrentThread.ManagedThreadId;
            using (var completed = new System.Threading.ManualResetEvent(false)) {
                try {
                    model = new NativeUpdates(configuration, delegate(string holding, NativeUpdateManifest value, string nonce, System.Threading.CancellationToken token) {
                        return new NativeUpdateAttempt(delegate { NativeUpdateHandoff.WriteSignal(holding, nonce, "cancel"); }, delegate { },
                            delegate { return fakeExited; }, delegate { }, delegate(int wait) {
                                if (System.Threading.Interlocked.CompareExchange(ref disposePhase, 0, 0) == 0) return false;
                                Check(System.Threading.Thread.CurrentThread.ManagedThreadId != caller); fakeExited = true; completed.Set(); return true;
                            }, fake);
                    }, manifest, stage);
                    Check(!model.InstallAsync(delegate { throw new InvalidOperationException("synthetic retained child"); }).GetAwaiter().GetResult());
                    Check(model.Busy && model.Available && Directory.Exists(stage) && !fake.Disposed);
                    System.Threading.Interlocked.Exchange(ref disposePhase, 1); model.Dispose();
                    Check(completed.WaitOne(2000)); Check(System.Threading.SpinWait.SpinUntil(delegate { return !model.Busy; }, 2000));
                    Check(System.Threading.SpinWait.SpinUntil(delegate { return !Directory.Exists(stage); }, 2000));
                    Check(fake.Disposed);
                } finally { if (Directory.Exists(stage)) Directory.Delete(stage, true); }
            }
            stage = NativeUpdatePaths.CreateStage(); fakeExited = false; fake = new UpdateFakeChild();
            try {
                model = new NativeUpdates(configuration, delegate(string holding, NativeUpdateManifest value, string nonce, System.Threading.CancellationToken token) {
                    return new NativeUpdateAttempt(delegate { }, delegate { throw new Exception("committed helper must not be cleaned by parent"); },
                        delegate { return fakeExited; }, delegate { }, delegate(int wait) { return false; }, fake);
                }, manifest, stage);
                Check(model.InstallAsync(delegate { model.Dispose(); }).GetAwaiter().GetResult());
                Check(!model.Available && !model.Busy && Directory.Exists(stage) && fake.Disposed);
            } finally { if (Directory.Exists(stage)) Directory.Delete(stage, true); }
        }
        private static void UpdateRuntimeSnapshotChecks()
        {
            string root = Path.Combine(Path.GetTempPath(), "knot-runtime-snapshot-check-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            string[] names = { "Knot-Native-Preview.exe", "KnotNativeMedia.dll", "KnotNativePairing.dll" };
            try {
                foreach (string name in names) File.WriteAllText(Path.Combine(root, name), "fresh synthetic original " + name);
                var snapshot = NativeUpdateInstalledSnapshot.Capture(Path.Combine(root, names[0]));
                using (snapshot.LockUnchanged()) {
                    bool denied = false;
                    try { File.WriteAllText(Path.Combine(root, names[1]), "cannot change a leased runtime"); } catch (IOException) { denied = true; }
                    Check(denied);
                }
                foreach (string name in names) {
                    string path = Path.Combine(root, name), original = File.ReadAllText(path);
                    File.WriteAllText(path, "changed runtime " + name);
                    UpdateReject(delegate { using (snapshot.LockUnchanged()) { } });
                    File.WriteAllText(path, original);
                    using (snapshot.LockUnchanged()) { Check(true); }
                }
                File.Delete(Path.Combine(root, names[2]));
                UpdateReject(delegate { using (snapshot.LockUnchanged()) { } });
            } finally { Directory.Delete(root, true); }
        }
        private static byte[] UpdateEnvelope(string text, RSACryptoServiceProvider key)
        {
            byte[] body = Encoding.ASCII.GetBytes(text), signature = key.SignData(body, CryptoConfig.MapNameToOID("SHA256"));
            return Encoding.ASCII.GetBytes(Convert.ToBase64String(body) + "\n" + Convert.ToBase64String(signature) + "\n");
        }
        private static void UpdateReject(Action action)
        {
            bool rejected = false; try { action(); } catch (InvalidDataException) { rejected = true; } catch (FormatException) { rejected = true; }
            Check(rejected);
        }
    }
}
