// SPDX-License-Identifier: GPL-3.0-only
// Fresh, separate design renderer. Never enters Program.Main or starts a host.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

namespace Knot.NativePreview
{
    internal static class NativeVisualFixtures
    {
        private sealed class Frame
        {
            internal string Name;
            internal HostViewPhase Phase;
            internal bool Help;
            internal int Width, Height;
            internal float Scale;
            internal Frame(string name, HostViewPhase phase, bool help, int width, int height, float scale)
            { Name = name; Phase = phase; Help = help; Width = width; Height = height; Scale = scale; }
        }

        private static string Digest(string path)
        {
            using (SHA256 hash = SHA256.Create())
            using (FileStream input = File.OpenRead(path))
                return BitConverter.ToString(hash.ComputeHash(input)).Replace("-", "").ToLowerInvariant();
        }
        private static string Q(string value) { return StrictJson.Quote(value); }
        private static int CountControls(Control root)
        {
            int count = 1;
            foreach (Control child in root.Controls) count += CountControls(child);
            return count;
        }
        private static void Pump()
        {
            // This dispatches only the fresh fixture's layout/paint messages.
            for (int i = 0; i < 8; ++i) Application.DoEvents();
        }
        private static HostViewSnapshot Snapshot(HostViewPhase phase)
        {
            bool active = phase == HostViewPhase.Invitation || phase == HostViewPhase.Request ||
                phase == HostViewPhase.Preparing || phase == HostViewPhase.Sharing || phase == HostViewPhase.Stopping;
            bool named = phase == HostViewPhase.Request || phase == HostViewPhase.Preparing || phase == HostViewPhase.Sharing;
            string status = phase == HostViewPhase.Failed ?
                "하드웨어 인코더를 사용할 수 없어요. 그래픽 드라이버를 확인한 뒤 다시 시도해주세요." :
                phase == HostViewPhase.Sharing ? "화면을 전송하고 있어요. 중지하면 이번 연결의 권한이 끝나요." :
                phase == HostViewPhase.Request ? "연결할 Mac을 확인해주세요. 아직 화면과 입력은 공유되지 않았어요." :
                phase == HostViewPhase.Preparing ? "연결을 허용했어요. Windows 화면과 인코더를 준비하고 있어요." :
                phase == HostViewPhase.Invitation ? "Mac에서 연결 코드를 입력한 뒤, 이 PC에서 요청을 허용해주세요." :
                "공유를 시작하면 Mac에 보낼 연결 코드가 만들어져요.";
            string pin = active && phase != HostViewPhase.Stopping ?
                "3d72a8f1b6e940c51a23d7e4f8b06c92a5e134789f2b60d8c714eab39065f2cd" : "";
            return new HostViewSnapshot(phase, true, active, pin, named ? "작업용 MacBook" : "",
                named ? "192.168.50.24" : "", status);
        }

        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                string output = null, iconPath = null;
                for (int i = 0; i < args.Length; ++i)
                {
                    if (args[i] == "--output" && i + 1 < args.Length) output = args[++i];
                    else if (args[i] == "--brand-icon" && i + 1 < args.Length) iconPath = args[++i];
                    else throw new ArgumentException("Unsupported synthetic renderer argument.");
                }
                if (output == null || iconPath == null) throw new ArgumentException("Provide --output and --brand-icon.");
                output = Path.GetFullPath(output); iconPath = Path.GetFullPath(iconPath);
                if (!File.Exists(iconPath)) throw new FileNotFoundException("Synthetic source brand icon is missing.");
                if (Directory.Exists(output) && Directory.GetFileSystemEntries(output).Length != 0)
                    throw new IOException("Synthetic output must be new or empty.");
                Directory.CreateDirectory(output);
                Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
                List<Frame> frames = new List<Frame>();
                frames.Add(new Frame("windows-idle.png", HostViewPhase.Idle, false, 1040, 740, 1));
                frames.Add(new Frame("windows-invitation.png", HostViewPhase.Invitation, false, 1040, 740, 1));
                frames.Add(new Frame("windows-request.png", HostViewPhase.Request, false, 1040, 740, 1));
                frames.Add(new Frame("windows-preparing.png", HostViewPhase.Preparing, false, 1040, 740, 1));
                frames.Add(new Frame("windows-sharing.png", HostViewPhase.Sharing, false, 1040, 740, 1));
                frames.Add(new Frame("windows-failure.png", HostViewPhase.Failed, false, 1040, 740, 1));
                frames.Add(new Frame("windows-help.png", HostViewPhase.Idle, true, 1040, 740, 1));
                frames.Add(new Frame("windows-idle-compact.png", HostViewPhase.Idle, false, 800, 620, 1));
                frames.Add(new Frame("windows-request-compact.png", HostViewPhase.Request, false, 800, 620, 1));
                frames.Add(new Frame("windows-sharing-compact.png", HostViewPhase.Sharing, false, 800, 620, 1));
                frames.Add(new Frame("windows-help-compact.png", HostViewPhase.Idle, true, 800, 620, 1));
                frames.Add(new Frame("windows-request-scale150.png", HostViewPhase.Request, false, 1040, 740, 1.5f));
                frames.Add(new Frame("windows-request-scale200.png", HostViewPhase.Request, false, 1040, 740, 2f));
                List<string> records = new List<string>();
                using (Icon icon = new Icon(iconPath, 256, 256))
                {
                    foreach (Frame frame in frames)
                    {
                        List<AdapterChoice> adapters = new List<AdapterChoice>();
                        adapters.Add(new AdapterChoice(IPAddress.Parse("192.168.50.12"), "Wi-Fi", NetworkInterfaceType.Wireless80211, true));
                        adapters.Add(new AdapterChoice(IPAddress.Parse("100.85.20.16"), "Tailscale", NetworkInterfaceType.Tunnel, false));
                        using (PreviewForm form = new PreviewForm(adapters, true, icon, frame.Scale))
                        {
                            form.StartPosition = FormStartPosition.Manual; form.Location = new Point(20, 20);
                            form.ClientSize = new Size((int)(frame.Width * frame.Scale), (int)(frame.Height * frame.Scale));
                            HostViewSnapshot state = Snapshot(frame.Phase);
                            form.SetFixturePresentation(state, frame.Help);
                            form.Show(); form.PerformLayout(); Pump();
                            if (!form.FixtureMode || !form.Visible || form.HelpVisible != frame.Help)
                                throw new InvalidOperationException("Synthetic form state is not visible.");
                            if (form.DisplayedPin != state.Pin) throw new InvalidOperationException("Synthetic pin was not retained exactly.");
                            bool expectedApproval = frame.Phase == HostViewPhase.Request && !frame.Help;
                            if (form.ApprovalVisible != expectedApproval) throw new InvalidOperationException("Approval visibility is not state-bound.");
                            bool expectedShare = !frame.Help && (frame.Phase == HostViewPhase.Idle || frame.Phase == HostViewPhase.Stopped || frame.Phase == HostViewPhase.Failed);
                            if (form.ShareVisible != expectedShare || form.ShareEnabled != expectedShare)
                                throw new InvalidOperationException("Share must remain unavailable while a run owns resources.");
                            bool expectedCopy = !frame.Help && frame.Phase == HostViewPhase.Invitation;
                            if (form.CopyVisible != expectedCopy || form.CopyEnabled != expectedCopy)
                                throw new InvalidOperationException("Only an available invitation has a copy action.");
                            if (form.ApprovalEnabled != expectedApproval)
                                throw new InvalidOperationException("Approval must be an explicit pending-request action.");
                            if (form.StopVisible != state.RunPresent) throw new InvalidOperationException("Stop action is not lifecycle-bound.");
                            float actualDpi;
                            using (Graphics graphics = form.CreateGraphics()) actualDpi = graphics.DpiX;
                            string path = Path.Combine(output, frame.Name);
                            using (Bitmap bitmap = new Bitmap(form.Width, form.Height, PixelFormat.Format32bppArgb))
                            {
                                form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size));
                                HashSet<int> sampleColors = new HashSet<int>();
                                for (int y = 8; y < bitmap.Height; y += 13)
                                    for (int x = 8; x < bitmap.Width; x += 13) sampleColors.Add(bitmap.GetPixel(x, y).ToArgb());
                                if (sampleColors.Count < 12) throw new InvalidOperationException("Synthetic render appears blank.");
                                bitmap.Save(path, ImageFormat.Png);
                                records.Add("{\"name\":" + Q(frame.Name) + ",\"sha256\":" + Q(Digest(path)) +
                                    ",\"bytes\":" + new FileInfo(path).Length + ",\"width\":" + bitmap.Width + ",\"height\":" + bitmap.Height +
                                    ",\"clientWidth\":" + form.ClientSize.Width + ",\"clientHeight\":" + form.ClientSize.Height +
                                    ",\"layoutFontScale\":" + frame.Scale.ToString(CultureInfo.InvariantCulture) +
                                    ",\"actualDrawingDpi\":" + actualDpi.ToString(CultureInfo.InvariantCulture) +
                                    ",\"state\":" + Q(frame.Phase.ToString()) + ",\"controlCount\":" + CountControls(form) +
                                    ",\"sampleColors\":" + sampleColors.Count + ",\"pinExact\":true,\"effectsBound\":false}");
                            }
                            form.Close(); Pump();
                        }
                    }
                }
                string report = "{\"schema\":1,\"status\":\"passed\",\"freshSyntheticOnly\":true," +
                    "\"productionEntryInvoked\":false,\"networkInvoked\":false,\"clipboardInvoked\":false," +
                    "\"certificateCreationInvoked\":false,\"captureInvoked\":false,\"actualInputInvoked\":false," +
                    "\"screenCaptureInvoked\":false,\"existingUserUIRead\":false,\"syntheticWindowsShown\":true," +
                    "\"visualAcceptance\":\"manual-review-required\",\"renderMethod\":\"Owned fresh fixture Form.DrawToBitmap after Show and finite DoEvents; no screen capture\"," +
                    "\"scaleScope\":\"layout/font geometry simulation only; actual drawing DPI recorded; not a per-monitor DPI acceptance test\"," +
                    "\"brandIconSHA256\":" + Q(Digest(iconPath)) + ",\"images\":[" + string.Join(",", records.ToArray()) + "]}";
                File.WriteAllText(Path.Combine(output, "visual-checks.json"), report + Environment.NewLine, new UTF8Encoding(false));
                Console.WriteLine(report); return 0;
            }
            catch (Exception error)
            {
                // Only synthetic fixture diagnostics, without user/service data.
                Console.Error.WriteLine("Synthetic UI rendering failed: " + error.GetType().Name + ": " + error.Message);
                return 1;
            }
        }
    }
}
