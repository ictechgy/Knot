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
                var newer = new NativeUpdateConfiguration("0.1.0-native.11\nhttps://example.com/mac.feed\nhttps://example.com/windows.feed\n" + Convert.ToBase64String(p.Modulus) + "\n" + Convert.ToBase64String(p.Exponent) + "\n");
                bool current = false; try { NativeUpdateManifest.Verify(envelope, newer, "windows-x64", 100); } catch (NativeUpdateCurrentException) { current = true; } Check(current);
            }
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
