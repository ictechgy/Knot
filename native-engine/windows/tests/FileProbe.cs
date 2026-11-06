// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.IO;

namespace Knot.NativePreview
{
    // A separate headless Windows diagnostic entry. It compiles the same managed
    // sources but does not replace complete-build/PAKE/codec acceptance.
    internal static class NativeFileProbe
    {
        private static int Main(string[] args) { return NativeChecks.RunFileProbe(args); }
    }

    internal static partial class NativeChecks
    {
        internal static int RunFileProbe(string[] args)
        {
            try
            {
                if (args.Length != 2 || args[0] != "--output") throw new ArgumentException("Invalid synthetic output argument.");
                string output = Path.GetFullPath(args[1]);
                if (Directory.Exists(output) && Directory.GetFileSystemEntries(output).Length != 0)
                    throw new InvalidOperationException("Synthetic probe output must be fresh.");
                Directory.CreateDirectory(output);
                certificateExportPath = Path.Combine(output, "vector-output-anchor.cer");
                stage = "explorer-input-barrier"; ExplorerInputChecks();
                stage = "explorer-ole-data"; DragBridgeChecks(); ++explorerOleFixtures;
                stage = "folder-trees"; TreeChecks();
                stage = "file-wire"; FileWireChecks();
                stage = "file-storage"; FileStorageChecks();
                stage = "file-link-containment"; FileLinkChecks();
                stage = "file-tls-roundtrip"; FileTlsRoundTrip();
                stage = "file-tls-auth-source"; FileTlsAuthSource();
                stage = "file-tls-cancel-digest"; FileTlsCancelDigest();
                stage = "file-tls-revoke-commit"; FileTlsRevokeCommit();
                stage = "file-tls-quota"; FileTlsQuota();
                stage = "file-tls-slow-dribble"; FileTlsSlowDribble();
                stage = "file-host-consent"; FileHostConsent();
                stage = "file-windows-vectors"; FileVectors();
                Console.WriteLine("{\"status\":\"passed\",\"probeOnly\":true,\"freshSyntheticOnly\":true," +
                    "\"actualCapture\":false,\"actualSendInput\":false,\"nativePairingChecksInvoked\":false," +
                    "\"actualFreshFileFixtures\":" + fileFixtures + ",\"actualFreshFileTlsFixtures\":" + fileTlsFixtures +
                    ",\"actualFreshFileMediaTlsFixtures\":" + fileMediaTlsFixtures + ",\"actualFreshExplorerInputFixtures\":" + explorerInputFixtures + ",\"actualFreshExplorerOleFixtures\":" + explorerOleFixtures + ",\"actualFreshTreeFixtures\":" + treeFixtures + ",\"actualFreshTreeTlsFixtures\":" + treeTlsFixtures + ",\"assertions\":" + assertions + "}");
                return 0;
            }
            catch (Exception failure)
            {
                FileTransferException file = failure as FileTransferException;
                string diagnostic = file == null ? "" : ",\"fileApiCategory\":" + StrictJson.Quote(file.Operation) + ",\"fileNativeError\":" + file.NativeError;
                if (file != null && file.NativeNtStatus.HasValue && file.NativeIoStatus.HasValue)
                    diagnostic += ",\"fileNtStatus\":" + file.NativeNtStatus.Value + ",\"fileIoStatus\":" + file.NativeIoStatus.Value;
                Console.WriteLine("{\"status\":\"failed\",\"probeOnly\":true,\"freshSyntheticOnly\":true," +
                    "\"actualCapture\":false,\"actualSendInput\":false,\"stage\":" + StrictJson.Quote(stage) +
                    ",\"exceptionType\":" + StrictJson.Quote(failure.GetType().FullName) +
                    ",\"exceptionHResult\":" + failure.HResult + diagnostic + ",\"actualFreshExplorerInputFixtures\":" + explorerInputFixtures + ",\"actualFreshExplorerOleFixtures\":" + explorerOleFixtures + ",\"actualFreshTreeFixtures\":" + treeFixtures + ",\"actualFreshTreeTlsFixtures\":" + treeTlsFixtures + ",\"assertions\":" + assertions + "}");
                return 1;
            }
        }
    }
}
