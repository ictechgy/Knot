using System;
using System.Collections.Generic;
using System.Globalization;
using Microsoft.Win32;

namespace Knot.NativePreview
{
    internal sealed class NativeUpdateResumeState
    {
        internal readonly bool AllowFiles;
        internal readonly string FileRootPath;
        internal readonly long UntilTicks;
        internal NativeUpdateResumeState(bool allowFiles, string fileRootPath, long untilTicks)
        { AllowFiles = allowFiles; FileRootPath = fileRootPath; UntilTicks = untilTicks; }
    }

    // Nonsecret UI state only; credentials live in the DPAPI trusted-device store.
    internal static class NativePreferences
    {
        private const string Path = @"Software\Knot\NativePreview";
        private const string ResumeValue = "UpdateResumeV2";
        internal static int Quality
        {
            get { try { using (RegistryKey key = Registry.CurrentUser.OpenSubKey(Path)) { object value = key == null ? null : key.GetValue("Quality"); return value is int && (int)value >= 0 && (int)value <= 2 ? (int)value : 0; } } catch { return 0; } }
            set { try { using (RegistryKey key = Registry.CurrentUser.CreateSubKey(Path)) key.SetValue("Quality", Math.Max(0, Math.Min(2, value)), RegistryValueKind.DWord); } catch { } }
        }
        internal static bool ShouldRequestUpdateResume(bool shareRequested, bool serverPresent, bool registeredSession, bool registeredDevices)
        { return shareRequested && serverPresent && (registeredSession || registeredDevices); }
        private static bool ExactLocalRoot(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length > 32768 || value.Length < 3 ||
                !((value[0] >= 'A' && value[0] <= 'Z') || (value[0] >= 'a' && value[0] <= 'z')) ||
                value[1] != ':' || value[2] != '\\') return false;
            StrictJson.ValidUnicode(value, true);
            // This is lexical validation only. Sharing later applies the normal
            // filesystem, permissions and reparse checks to this exact folder.
            FileSharingOptions options = new FileSharingOptions(value);
            return string.Equals(value, options.RootPath, StringComparison.Ordinal);
        }
        internal static string EncodeUpdateResume(bool allowFiles, string fileRootPath, DateTime nowUtc)
        {
            if (nowUtc.Kind != DateTimeKind.Utc || !ExactLocalRoot(fileRootPath)) throw new ArgumentException("Invalid update resume scope.");
            long until = nowUtc.AddMinutes(5).Ticks;
            return "{\"v\":2,\"untilTicks\":" + until.ToString(CultureInfo.InvariantCulture) +
                ",\"allowFiles\":" + (allowFiles ? "true" : "false") + ",\"fileRootPath\":" + StrictJson.Quote(fileRootPath) + "}";
        }
        internal static NativeUpdateResumeState ParseUpdateResume(object value, DateTime nowUtc)
        {
            try
            {
                string text = value as string;
                if (nowUtc.Kind != DateTimeKind.Utc || string.IsNullOrEmpty(text) || text.Length > 65536) return null;
                Dictionary<string, object> fields = StrictJson.Parse(StrictJson.Utf8.GetBytes(text), "v", "untilTicks", "allowFiles", "fileRootPath");
                if (StrictJson.Integer(fields, "v", 2, 2) != 2 || !(fields["untilTicks"] is long) || !(fields["allowFiles"] is bool)) return null;
                long until = (long)fields["untilTicks"];
                string root = StrictJson.String(fields, "fileRootPath");
                if (until <= nowUtc.Ticks || until > nowUtc.AddMinutes(5).Ticks || !ExactLocalRoot(root)) return null;
                return new NativeUpdateResumeState((bool)fields["allowFiles"], root, until);
            }
            catch { return null; }
        }
        internal static void ClearUpdateResume()
        {
            try { using (RegistryKey key = Registry.CurrentUser.CreateSubKey(Path)) {
                key.DeleteValue(ResumeValue, false); key.DeleteValue("UpdateResumeUntil", false);
            } } catch { }
        }
        internal static void RequestUpdateResume(bool allowFiles, string fileRootPath)
        {
            ClearUpdateResume();
            try {
                string value = EncodeUpdateResume(allowFiles, fileRootPath, DateTime.UtcNow);
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(Path)) key.SetValue(ResumeValue, value, RegistryValueKind.String);
            } catch { ClearUpdateResume(); }
        }
        internal static NativeUpdateResumeState ConsumeUpdateResume()
        {
            try { using (RegistryKey key = Registry.CurrentUser.CreateSubKey(Path)) {
                object value = null; bool stringKind = false;
                try {
                    value = key.GetValue(ResumeValue, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                    stringKind = value != null && key.GetValueKind(ResumeValue) == RegistryValueKind.String;
                }
                finally {
                    // Consume every record, including malformed or legacy state,
                    // before validation. A failed parse must never retry later.
                    key.DeleteValue(ResumeValue, false); key.DeleteValue("UpdateResumeUntil", false);
                }
                return stringKind ? ParseUpdateResume(value, DateTime.UtcNow) : null;
            } } catch { return null; }
        }
    }
}
