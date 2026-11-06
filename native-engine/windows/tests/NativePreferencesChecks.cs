// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Globalization;
using System.Net;
using System.Net.NetworkInformation;

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
            string lan = "192.168.50.23", overlay = "100.101.2.3";
            string disabled = NativePreferences.EncodeUpdateResume(false, custom, overlay, now);
            NativeUpdateResumeState off = NativePreferences.ParseUpdateResume(disabled, now);
            Check(off != null && !off.AllowFiles && off.FileRootPath == custom && off.UntilTicks == now.AddMinutes(5).Ticks && off.Address == overlay);
            NativeUpdateResumeState on = NativePreferences.ParseUpdateResume(NativePreferences.EncodeUpdateResume(true, custom, lan, now), now);
            Check(on != null && on.AllowFiles && on.FileRootPath == custom && on.Address == lan);
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
                try { NativePreferences.EncodeUpdateResume(true, root, lan, now); } catch (ArgumentException) { rejected = true; } catch (ProtocolException) { rejected = true; }
                Check(rejected);
                string invalid = "{\"v\":2,\"untilTicks\":" + now.AddMinutes(5).Ticks.ToString(CultureInfo.InvariantCulture) +
                    ",\"allowFiles\":true,\"fileRootPath\":" + StrictJson.Quote(root) + ",\"address\":" + StrictJson.Quote(lan) + "}";
                Check(NativePreferences.ParseUpdateResume(invalid, now) == null);
            }
            for (int bits = 0; bits < 32; ++bits)
            {
                bool requested = (bits & 1) != 0, present = (bits & 2) != 0;
                bool session = (bits & 4) != 0, registered = (bits & 8) != 0, address = (bits & 16) != 0;
                Check(NativePreferences.ShouldRequestUpdateResume(requested, present, session, registered, address) == (requested && present && address && (session || registered)));
            }
            Check(NativePreferences.ParseUpdateResume(disabled.Replace(",\"address\":" + StrictJson.Quote(overlay), ""), now) == null);
            foreach (string invalidAddress in new string[] { "", "8.8.8.8", "127.0.0.1", "169.254.1.1", "192.168.050.23", "192.168.50.023", "192.168.50.23 ", "0xc0a83217", "3232248343", "::ffff:192.168.50.23", "192.168.50.256", "example.test" })
            {
                Check(!NativePreferences.CanonicalPrivateAddress(invalidAddress));
                bool rejected = false;
                try { NativePreferences.EncodeUpdateResume(true, custom, invalidAddress, now); } catch (ArgumentException) { rejected = true; }
                Check(rejected);
                Check(NativePreferences.ParseUpdateResume(disabled.Replace(StrictJson.Quote(overlay), StrictJson.Quote(invalidAddress)), now) == null);
            }
            AdapterChoice lanAdapter = new AdapterChoice(IPAddress.Parse(lan), "Synthetic Wi-Fi", NetworkInterfaceType.Wireless80211, true);
            AdapterChoice overlayAdapter = new AdapterChoice(IPAddress.Parse(overlay), "Synthetic Tailscale", NetworkInterfaceType.Tunnel, false);
            AdapterChoice[] current = new AdapterChoice[] { lanAdapter, overlayAdapter };
            Check(object.ReferenceEquals(NativePreferences.SelectResumeAdapter(overlay, current), overlayAdapter));
            Check(object.ReferenceEquals(NativePreferences.SelectResumeAdapter(lan, current), lanAdapter));
            Check(NativePreferences.SelectResumeAdapter(overlay, new AdapterChoice[] { lanAdapter }) == null);
            Check(NativePreferences.SelectResumeAdapter(lan, new AdapterChoice[] { overlayAdapter }) == null);
            Check(NativePreferences.SelectResumeAdapter(overlay, new AdapterChoice[0]) == null);
            Check(NativePreferences.SelectResumeAdapter(overlay, null) == null);
            Check(NativePreferences.SelectResumeAdapter("8.8.8.8", current) == null);
            Check(!NativePreferences.ShouldRequestUpdateResume(true, true, true, true, false));
            // Stop has already cleared shareRequested, even if the old server
            // remains present while its asynchronous shutdown finishes.
            Check(!NativePreferences.ShouldRequestUpdateResume(false, true, true, true, true));
        }
    }
}
