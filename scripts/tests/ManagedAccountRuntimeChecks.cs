// SPDX-License-Identifier: GPL-3.0-only
// The only files touched are under the newly-created synthetic directory argument.
using System;
using System.IO;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading.Tasks;
internal static class ManagedAccountRuntimeChecks
{
    private static int count;
    private static void Check(bool value) { if (!value) throw new Exception("Synthetic managed-account check failed"); count++; }
    private static SunshineAccountRecord Record(string suffix) { return new SunshineAccountRecord { Username = "synthetic", Password = "synthetic-password-" + suffix, Recovery = true }; }
    private static void Main(string[] args)
    {
        if (args.Length != 1 || !Directory.Exists(args[0])) throw new Exception("Fresh fixture directory required");
        byte[] certificate = new byte[] { 1, 2, 3, 4 };
        using (var store = new SunshineProtectedAccountStore(args[0], certificate)) {
            Check(store.Read() == null); store.Save(Record("one"));
            Check(store.Read().Password == Record("one").Password && store.Read().Recovery);
            bool exclusive = false; try { using (var other = new SunshineProtectedAccountStore(args[0], certificate)) { } } catch (SunshineSetupFailure) { exclusive = true; } Check(exclusive);
            var record = Record("two"); record.Recovery = false; store.Save(record);
            Check(store.Read().Password == record.Password && !store.Read().Recovery);
            byte[] raw = File.ReadAllBytes(Path.Combine(args[0], "knot-account.dpapi"));
            Check(System.Text.Encoding.UTF8.GetString(raw).IndexOf("synthetic-password", StringComparison.Ordinal) < 0);
            var gate = typeof(SunshineProtectedAccountStore).GetField("gate", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(store);
            Task late;
            lock (gate) {
                late = Task.Run(delegate { try { store.Save(Record("late")); return false; } catch (ObjectDisposedException) { return true; } });
                store.Dispose(); // Reentrant while a pending writer is blocked behind the same gate.
            }
            Check(((Task<bool>)late).GetAwaiter().GetResult()); store.Dispose();
        }
        using (var reopened = new SunshineProtectedAccountStore(args[0], certificate)) Check(reopened.Read().Password == Record("two").Password);
        bool changed = false; using (var otherCert = new SunshineProtectedAccountStore(args[0], new byte[] { 4, 3, 2, 1 })) {
            try { otherCert.Read(); } catch (SunshineSetupFailure) { changed = true; }
        } Check(changed);
        string file = Path.Combine(args[0], "knot-account.dpapi"); var original = File.GetAccessControl(file);
        var unsafeAcl = File.GetAccessControl(file); unsafeAcl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null), FileSystemRights.ReadData, AccessControlType.Allow));
        File.SetAccessControl(file, unsafeAcl);
        try { bool unsafeRejected = false; using (var store = new SunshineProtectedAccountStore(args[0], certificate)) { try { store.Read(); } catch (SunshineSetupFailure) { unsafeRejected = true; } } Check(unsafeRejected); }
        finally { File.SetAccessControl(file, original); }
        byte[] saved = File.ReadAllBytes(file); File.WriteAllBytes(file, new byte[] { 1, 2, 3 });
        try { bool corrupt = false; using (var store = new SunshineProtectedAccountStore(args[0], certificate)) { try { store.Read(); } catch (SunshineSetupFailure) { corrupt = true; } } Check(corrupt); }
        finally { File.WriteAllBytes(file, saved); }
        Console.WriteLine("{\"status\":\"passed\",\"checks\":" + count + ",\"freshSyntheticOnly\":true,\"existingVaultAccessed\":false,\"nativeDPAPITested\":true}");
    }
}
