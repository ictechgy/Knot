using System;
using Microsoft.Win32;

namespace Knot.NativePreview
{
    // Nonsecret UI state only; credentials live in the DPAPI trusted-device store.
    internal static class NativePreferences
    {
        private const string Path = @"Software\Knot\NativePreview";
        internal static int Quality
        {
            get { try { using (RegistryKey key = Registry.CurrentUser.OpenSubKey(Path)) { object value = key == null ? null : key.GetValue("Quality"); return value is int && (int)value >= 0 && (int)value <= 2 ? (int)value : 0; } } catch { return 0; } }
            set { try { using (RegistryKey key = Registry.CurrentUser.CreateSubKey(Path)) key.SetValue("Quality", Math.Max(0, Math.Min(2, value)), RegistryValueKind.DWord); } catch { } }
        }
        internal static void RequestUpdateResume() { try { using (RegistryKey key = Registry.CurrentUser.CreateSubKey(Path)) key.SetValue("UpdateResumeUntil", DateTime.UtcNow.AddMinutes(5).Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture), RegistryValueKind.String); } catch { } }
        internal static bool ConsumeUpdateResume()
        {
            try { using (RegistryKey key = Registry.CurrentUser.CreateSubKey(Path)) {
                string value = key.GetValue("UpdateResumeUntil") as string; key.DeleteValue("UpdateResumeUntil", false);
                long ticks; return long.TryParse(value, out ticks) && ticks > DateTime.UtcNow.Ticks && ticks <= DateTime.UtcNow.AddMinutes(5).Ticks;
            } } catch { return false; }
        }
    }
}
