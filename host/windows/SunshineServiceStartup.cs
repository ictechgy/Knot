// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.IO;
using System.Runtime.InteropServices;

internal static class SunshineServiceStartup
{
    [StructLayout(LayoutKind.Sequential)] private struct ServiceConfig {
        internal uint Type, Start, Error; internal IntPtr Binary, Group; internal uint Tag;
        internal IntPtr Dependencies, Account, DisplayName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr OpenSCManagerW(string machine, string database, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr OpenServiceW(IntPtr manager, string service, uint access);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool QueryServiceConfigW(IntPtr service, IntPtr config, uint size, out uint needed);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool StartServiceW(IntPtr service, uint count, IntPtr args);
    [DllImport("advapi32.dll")] private static extern bool CloseServiceHandle(IntPtr handle);
    // Called only while the pinned API holds and validates the exact installed
    // binary and directory handles. Never repair a foreign service configuration.
    internal static void EnsureStarted(string expectedBinary)
    {
        IntPtr manager = OpenSCManagerW(null, null, 1), service = IntPtr.Zero, memory = IntPtr.Zero;
        try {
            SunshineSetupPolicy.Require(manager != IntPtr.Zero);
            service = OpenServiceW(manager, "SunshineService", 1 | 16); SunshineSetupPolicy.Require(service != IntPtr.Zero);
            uint needed; QueryServiceConfigW(service, IntPtr.Zero, 0, out needed);
            SunshineSetupPolicy.Require(needed >= Marshal.SizeOf(typeof(ServiceConfig)) && needed <= 65536);
            memory = Marshal.AllocHGlobal((int)needed);
            SunshineSetupPolicy.Require(QueryServiceConfigW(service, memory, needed, out needed));
            var config = (ServiceConfig)Marshal.PtrToStructure(memory, typeof(ServiceConfig));
            string binary = Marshal.PtrToStringUni(config.Binary), account = Marshal.PtrToStringUni(config.Account);
            SunshineSetupPolicy.Require(config.Type == 16 && config.Start != 4 &&
                String.Equals(account, "LocalSystem", StringComparison.OrdinalIgnoreCase) &&
                (String.Equals(binary, expectedBinary, StringComparison.OrdinalIgnoreCase) || String.Equals(binary, "\"" + expectedBinary + "\"", StringComparison.OrdinalIgnoreCase)));
            if (!StartServiceW(service, 0, IntPtr.Zero) && Marshal.GetLastWin32Error() != 1056)
                throw new IOException(); // The existing bounded startup UI retries; never report ready here.
        } finally {
            if (memory != IntPtr.Zero) Marshal.FreeHGlobal(memory);
            if (service != IntPtr.Zero) CloseServiceHandle(service);
            if (manager != IntPtr.Zero) CloseServiceHandle(manager);
        }
    }
}
