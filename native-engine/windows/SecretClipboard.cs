using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Knot.NativePreview
{
    internal static class SecretClipboard
    {
        // Microsoft documents these registered formats and their serialized DWORDs:
        // https://learn.microsoft.com/windows/win32/dataxchg/clipboard-formats#cloud-clipboard-and-clipboard-history-formats
        internal static Dictionary<string, byte[]> ProtectionFormats()
        {
            Dictionary<string, byte[]> formats = new Dictionary<string, byte[]>(StringComparer.Ordinal);
            formats.Add("CanIncludeInClipboardHistory", new byte[4]);
            formats.Add("CanUploadToCloudClipboard", new byte[4]);
            formats.Add("ExcludeClipboardContentFromMonitorProcessing", new byte[] { 0 });
            return formats;
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint RegisterClipboardFormat(string name);
        // Called only by the explicit Copy action. No clipboard read API is used.
        internal static void CopyOwnInvitation(string invitation)
        {
            DataObject data = new DataObject();
            foreach (KeyValuePair<string, byte[]> format in ProtectionFormats())
            {
                if (RegisterClipboardFormat(format.Key) == 0) throw new ExternalException("Clipboard exclusion format registration failed.");
                data.SetData(format.Key, false, new MemoryStream(format.Value, false));
            }
            data.SetData(DataFormats.UnicodeText, false, invitation);
            Clipboard.SetDataObject(data, true, 3, 50);
        }
    }
}
