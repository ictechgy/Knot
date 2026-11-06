// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Globalization;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        private static void NativePreferencesChecks()
        {
            // Pure codec and decision checks. These strings refer only to fresh
            // synthetic paths; no registry, preferences or directory is opened.
            DateTime now = new DateTime(2026, 11, 6, 12, 0, 0, DateTimeKind.Utc);
            string custom = @"C:\Synthetic\Restricted Project";
            string disabled = NativePreferences.EncodeUpdateResume(false, custom, now);
            NativeUpdateResumeState off = NativePreferences.ParseUpdateResume(disabled, now);
            Check(off != null && !off.AllowFiles && off.FileRootPath == custom && off.UntilTicks == now.AddMinutes(5).Ticks);
            NativeUpdateResumeState on = NativePreferences.ParseUpdateResume(NativePreferences.EncodeUpdateResume(true, custom, now), now);
            Check(on != null && on.AllowFiles && on.FileRootPath == custom);
            Check(NativePreferences.ParseUpdateResume(disabled, now.AddMinutes(5)) == null);
            Check(NativePreferences.ParseUpdateResume(disabled, now.AddTicks(-1)) == null);
            Check(NativePreferences.ParseUpdateResume(null, now) == null);
            Check(NativePreferences.ParseUpdateResume(42, now) == null);
            Check(NativePreferences.ParseUpdateResume(now.AddMinutes(5).Ticks.ToString(CultureInfo.InvariantCulture), now) == null);
            Check(NativePreferences.ParseUpdateResume("{\"untilTicks\":" + now.AddMinutes(5).Ticks + "}", now) == null);
            Check(NativePreferences.ParseUpdateResume(disabled.Replace("\"v\":2", "\"v\":1"), now) == null);
            Check(NativePreferences.ParseUpdateResume(disabled.Replace("\"allowFiles\":false", "\"allowFiles\":\"false\""), now) == null);
            Check(NativePreferences.ParseUpdateResume(disabled.Replace("\"allowFiles\":false,", ""), now) == null);
            Check(NativePreferences.ParseUpdateResume(disabled.Replace("\"v\":2", "\"v\":2,\"v\":2"), now) == null);
            foreach (string root in new string[] { "", "relative", @"C:relative", @"\\server\share", @"C:\Synthetic\..\Different", @"C:\Synthetic\Trailing\", "C:\\Synthetic\\Line\nBreak" })
            {
                bool rejected = false;
                try { NativePreferences.EncodeUpdateResume(true, root, now); } catch (ArgumentException) { rejected = true; } catch (ProtocolException) { rejected = true; }
                Check(rejected);
                string invalid = "{\"v\":2,\"untilTicks\":" + now.AddMinutes(5).Ticks.ToString(CultureInfo.InvariantCulture) +
                    ",\"allowFiles\":true,\"fileRootPath\":" + StrictJson.Quote(root) + "}";
                Check(NativePreferences.ParseUpdateResume(invalid, now) == null);
            }
            for (int bits = 0; bits < 16; ++bits)
            {
                bool requested = (bits & 1) != 0, present = (bits & 2) != 0;
                bool session = (bits & 4) != 0, registered = (bits & 8) != 0;
                Check(NativePreferences.ShouldRequestUpdateResume(requested, present, session, registered) == (requested && present && (session || registered)));
            }
            // Stop has already cleared shareRequested, even if the old server
            // remains present while its asynchronous shutdown finishes.
            Check(!NativePreferences.ShouldRequestUpdateResume(false, true, true, true));
        }
    }
}
