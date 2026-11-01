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
        private static string currentFrame = "initialization";
        private static string currentStage = "initialization", progressPath;
        private sealed class Frame
        {
            internal string Name;
            internal HostViewPhase Phase;
            internal bool Help;
            internal int Width, Height;
            internal float Scale;
            internal string StatusOverride, ViewerLabelOverride;
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
        private static void Progress(Frame frame, string stage)
        {
            currentStage = stage;
            // Only fixed stage names and synthetic fixture names are recorded.
            // The file survives an outer builder timeout with captured stdout.
            string line = frame.Name + " " + stage + Environment.NewLine;
            File.AppendAllText(progressPath, line, new UTF8Encoding(false));
            Console.Write(line); Console.Out.Flush();
        }
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
                "화면 공유를 시작하지 못했어요. 선택한 네트워크와 포트 48631을 사용할 수 있는지 확인해주세요." :
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
                progressPath = Path.Combine(output, "fixture-progress.log");
                Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
                List<Frame> frames = new List<Frame>();
                frames.Add(new Frame("windows-idle.png", HostViewPhase.Idle, false, 1040, 740, 1));
                frames.Add(new Frame("windows-invitation.png", HostViewPhase.Invitation, false, 1040, 740, 1));
                frames.Add(new Frame("windows-request.png", HostViewPhase.Request, false, 1040, 740, 1));
                frames.Add(new Frame("windows-preparing.png", HostViewPhase.Preparing, false, 1040, 740, 1));
                frames.Add(new Frame("windows-sharing.png", HostViewPhase.Sharing, false, 1040, 740, 1));
                frames.Add(new Frame("windows-failure.png", HostViewPhase.Failed, false, 1040, 740, 1));
                frames.Add(new Frame("windows-ended-error.png", HostViewPhase.Stopped, false, 1040, 740, 1) { StatusOverride = PreviewCopy.Status(HostServer.Guidance("encoder")) });
                frames.Add(new Frame("windows-help.png", HostViewPhase.Idle, true, 1040, 740, 1));
                frames.Add(new Frame("windows-idle-compact.png", HostViewPhase.Idle, false, 800, 620, 1));
                frames.Add(new Frame("windows-request-compact.png", HostViewPhase.Request, false, 800, 620, 1));
                frames.Add(new Frame("windows-sharing-compact.png", HostViewPhase.Sharing, false, 800, 620, 1));
                frames.Add(new Frame("windows-help-compact.png", HostViewPhase.Idle, true, 800, 620, 1));
                frames.Add(new Frame("windows-ended-error-compact.png", HostViewPhase.Stopped, false, 800, 620, 1) { StatusOverride = PreviewCopy.Status(HostServer.Guidance("encoder")) });
                frames.Add(new Frame("windows-request-scale150.png", HostViewPhase.Request, false, 1040, 740, 1.5f));
                frames.Add(new Frame("windows-request-scale200.png", HostViewPhase.Request, false, 1040, 740, 2f));
                frames.Add(new Frame("windows-request-long-name-scale200.png", HostViewPhase.Request, false, 1040, 740, 2f) { ViewerLabelOverride = new string('W', 64) });
                frames.Add(new Frame("windows-ended-error-scale200.png", HostViewPhase.Stopped, false, 1040, 740, 2f) { StatusOverride = PreviewCopy.Status(HostServer.Guidance("encoder")) });
                List<string> records = new List<string>();
                using (Icon icon = new Icon(iconPath, 256, 256))
                {
                    foreach (Frame frame in frames)
                    {
                        currentFrame = frame.Name + " phase=" + frame.Phase + " help=" + frame.Help +
                            " layoutScale=" + frame.Scale.ToString(CultureInfo.InvariantCulture);
                        List<AdapterChoice> adapters = new List<AdapterChoice>();
                        adapters.Add(new AdapterChoice(IPAddress.Parse("192.168.50.12"), "Wi-Fi", NetworkInterfaceType.Wireless80211, true));
                        adapters.Add(new AdapterChoice(IPAddress.Parse("100.85.20.16"), "Tailscale", NetworkInterfaceType.Tunnel, false));
                        Progress(frame, "before-constructor");
                        using (PreviewForm form = new PreviewForm(adapters, true, icon, frame.Scale, delegate(string stage) { Progress(frame, "source-" + stage); }))
                        {
                            Progress(frame, "after-constructor");
                            form.StartPosition = FormStartPosition.Manual; form.Location = new Point(20, 20);
                            form.ClientSize = new Size((int)(frame.Width * frame.Scale), (int)(frame.Height * frame.Scale));
                            Progress(frame, "after-requested-size");
                            HostViewSnapshot state = Snapshot(frame.Phase);
                            if (frame.StatusOverride != null || frame.ViewerLabelOverride != null)
                                state = new HostViewSnapshot(state.Phase, state.HasAddress, state.RunPresent, state.Pin, frame.ViewerLabelOverride ?? state.ViewerLabel, state.ObservedAddress, frame.StatusOverride ?? state.Status, state.CanCopy);
                            Progress(frame, "before-presentation"); form.SetFixturePresentation(state, frame.Help); Progress(frame, "after-presentation");
                            Progress(frame, "before-show"); form.Show(); Progress(frame, "after-show");
                            form.PerformLayout(); Progress(frame, "after-initial-layout"); Pump(); Progress(frame, "after-initial-pump");
                            for (int layoutPass = 0; layoutPass < 3; ++layoutPass)
                            {
                                Progress(frame, "before-layout-pass-" + layoutPass); form.PrepareFixtureLayout();
                                Progress(frame, "after-layout-pass-" + layoutPass); Pump(); Progress(frame, "after-layout-pump-" + layoutPass);
                            }
                            if (frame.Phase == HostViewPhase.Invitation)
                            {
                                Progress(frame, "before-help"); form.SetFixturePresentation(state, true); Progress(frame, "after-help"); Pump(); Progress(frame, "after-help-pump");
                                if (form.CopyVisible) throw new InvalidOperationException("Invitation copy action must be hidden on the help page (visible=" + form.CopyVisible + ",enabled=" + form.CopyEnabled + ").");
                                Progress(frame, "before-help-return"); form.SetFixturePresentation(state, false); Progress(frame, "after-help-return"); Pump(); Progress(frame, "after-help-return-pump");
                                if (!form.CopyVisible || !form.CopyEnabled)
                                    throw new InvalidOperationException("Invitation copy action must restore from explicit state after help navigation (visible=" + form.CopyVisible + ",enabled=" + form.CopyEnabled + ").");
                            }
                            currentFrame += " actual[shareVisible=" + form.ShareVisible + ",shareEnabled=" + form.ShareEnabled +
                                ",copyVisible=" + form.CopyVisible + ",copyEnabled=" + form.CopyEnabled +
                                ",approvalVisible=" + form.ApprovalVisible + ",approvalEnabled=" + form.ApprovalEnabled +
                                ",stopVisible=" + form.StopVisible + ",help=" + form.HelpVisible + "]";
                            currentFrame += " layout[" + form.FixtureLayoutDiagnostic + "]";
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
                            if (!form.FixtureFooterFits) throw new InvalidOperationException("Fixed status text and stop action must fit the actual client viewport.");
                            if (expectedApproval && !form.FixtureConsentFits) throw new InvalidOperationException("The full pin, observed address, unverified name and consent actions must fit the request viewport.");
                            float actualDpi;
                            using (Graphics graphics = form.CreateGraphics()) actualDpi = graphics.DpiX;
                            string path = Path.Combine(output, frame.Name);
                            Progress(frame, "before-bitmap");
                            using (Bitmap bitmap = new Bitmap(form.Width, form.Height, PixelFormat.Format32bppArgb))
                            {
                                form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size));
                                Progress(frame, "after-bitmap");
                                if (!form.FixtureBrandPainted) throw new InvalidOperationException("The actual sidebar Knot mark did not paint.");
                                HashSet<int> sampleColors = new HashSet<int>();
                                for (int y = 8; y < bitmap.Height; y += 13)
                                    for (int x = 8; x < bitmap.Width; x += 13) sampleColors.Add(bitmap.GetPixel(x, y).ToArgb());
                                if (sampleColors.Count < 12) throw new InvalidOperationException("Synthetic render appears blank.");
                                bitmap.Save(path, ImageFormat.Png);
                                Progress(frame, "after-save");
                                records.Add("{\"name\":" + Q(frame.Name) + ",\"sha256\":" + Q(Digest(path)) +
                                    ",\"bytes\":" + new FileInfo(path).Length + ",\"width\":" + bitmap.Width + ",\"height\":" + bitmap.Height +
                                    ",\"clientWidth\":" + form.ClientSize.Width + ",\"clientHeight\":" + form.ClientSize.Height +
                                    ",\"requestedClientWidth\":" + (int)(frame.Width * frame.Scale) + ",\"requestedClientHeight\":" + (int)(frame.Height * frame.Scale) +
                                    ",\"logicalClientWidth\":" + form.FixtureLogicalWidth.ToString(CultureInfo.InvariantCulture) + ",\"responsiveCompact\":" + (form.FixtureCompactMode ? "true" : "false") +
                                    ",\"footerFits\":true,\"consentFits\":" + (expectedApproval ? "true" : "null") +
                                    ",\"layoutFontScale\":" + frame.Scale.ToString(CultureInfo.InvariantCulture) +
                                    ",\"actualDrawingDpi\":" + actualDpi.ToString(CultureInfo.InvariantCulture) +
                                    ",\"state\":" + Q(frame.Phase.ToString()) + ",\"controlCount\":" + CountControls(form) +
                                    ",\"sampleColors\":" + sampleColors.Count + ",\"pinExact\":true,\"brandPainted\":true,\"effectsBound\":false}");
                            }
                            Progress(frame, "before-close"); form.Close(); Progress(frame, "after-close"); Pump(); Progress(frame, "after-close-pump");
                        }
                        Progress(frame, "after-dispose");
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
                Console.Error.WriteLine("Synthetic UI rendering failed [" + currentFrame + " stage=" + currentStage + "]: " + error.GetType().Name + ": " + error.Message);
                return 1;
            }
        }
    }
}
