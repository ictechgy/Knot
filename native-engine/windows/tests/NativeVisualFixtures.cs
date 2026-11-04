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
using System.Runtime.InteropServices;
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
            internal bool EnrollmentMode;
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
        private static string IllustrationChecks()
        {
            Size[] sizes = { new Size(700, 88), new Size(700, 44), new Size(52, 88),
                new Size(700, 176), new Size(700, 264), new Size(16, 12) };
            int[] dpis = { 96, 120, 144, 192, 240, 288 };
            int renders = 0;
            foreach (Size size in sizes)
            {
                MonitorGeometry geometry;
                if (!MonitorGeometry.TryFit(size, out geometry)) throw new InvalidOperationException("Valid illustration bounds were rejected.");
                RectangleF client = new RectangleF(PointF.Empty, size);
                if (!client.Contains(geometry.Screen) || geometry.BaseLeft.X < 0 || geometry.BaseRight.X > size.Width ||
                    geometry.StemBottom.Y > size.Height ||
                    Math.Abs(geometry.Screen.Width / geometry.Screen.Height - 118f / 72f) > 0.001f ||
                    Math.Abs(geometry.Logo.Left + geometry.Logo.Width / 2 - geometry.Screen.Left - geometry.Screen.Width / 2) > 0.001f ||
                    Math.Abs(geometry.Logo.Top + geometry.Logo.Height / 2 - geometry.Screen.Top - geometry.Screen.Height / 2) > 0.001f)
                    throw new InvalidOperationException("Monitor geometry lost aspect, centering or containment.");
                for (int row = 0; row < 2; ++row)
                    for (int column = 0; column < 2; ++column)
                    {
                        RectangleF pane = geometry.Pane(column, row);
                        if (!geometry.Screen.Contains(pane) || Math.Abs(pane.Width - pane.Height) > 0.001f)
                            throw new InvalidOperationException("A Windows pane escaped or changed aspect.");
                    }
                string previousPixels = null;
                foreach (int dpi in dpis)
                {
                    using (MonitorIllustration control = new MonitorIllustration())
                    using (Bitmap bitmap = new Bitmap(size.Width, size.Height, PixelFormat.Format32bppArgb))
                    {
                        control.Size = size; bitmap.SetResolution(dpi, dpi);
                        using (Graphics graphics = Graphics.FromImage(bitmap))
                        { graphics.Clear(PreviewStyle.Surface); control.DrawIllustration(graphics); }
                        for (int row = 0; row < 2; ++row)
                            for (int column = 0; column < 2; ++column)
                            {
                                RectangleF pane = geometry.Pane(column, row);
                                // GDI+ samples around integer pixel centers.
                                // The nearest center stays inside a two-pixel
                                // pane; flooring can land on its antialiased edge.
                                int x = (int)Math.Round(pane.Left + pane.Width / 2), y = (int)Math.Round(pane.Top + pane.Height / 2);
                                if (bitmap.GetPixel(x, y).ToArgb() != PreviewStyle.Accent.ToArgb())
                                    throw new InvalidOperationException("A centered Windows pane did not paint: " +
                                        size.Width + "x" + size.Height + " dpi=" + dpi + " pane=" + column + "," + row + ".");
                            }
                        BitmapData data = bitmap.LockBits(new Rectangle(Point.Empty, bitmap.Size), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                        byte[] pixels;
                        try
                        {
                            if (data.Stride != size.Width * 4 || data.Height != size.Height)
                                throw new InvalidOperationException("Unexpected owned bitmap row layout.");
                            pixels = new byte[data.Stride * data.Height];
                            Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
                        }
                        finally { bitmap.UnlockBits(data); }
                        string digest;
                        using (SHA256 hash = SHA256.Create()) digest = BitConverter.ToString(hash.ComputeHash(pixels));
                        if (previousPixels != null && digest != previousPixels)
                            throw new InvalidOperationException("Graphics DPI was applied a second time to fitted monitor pixels.");
                        previousPixels = digest; ++renders;
                    }
                }
            }
            MonitorGeometry tiny;
            if (MonitorGeometry.TryFit(Size.Empty, out tiny) || MonitorGeometry.TryFit(new Size(1, 1), out tiny))
                throw new InvalidOperationException("Degenerate illustration bounds must skip painting.");
            return "{\"status\":\"PASS\",\"boundsCases\":" + sizes.Length + ",\"rasterCases\":" + renders +
                ",\"minimumDpi\":96,\"maximumDpi\":288,\"centered\":true,\"paneAspectPreserved\":true," +
                "\"panesContained\":true,\"sameBoundsDpiPixelIdentity\":true,\"degenerateBoundsSkipped\":true," +
                "\"scope\":\"Production drawing on fresh bitmaps; not a physical monitor transition test\"}";
        }
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
        private static void AssertFontsUsable(Control root)
        {
            // GetHeight(dpi) consults the native font; Font.Height may be cached.
            float height = root.Font.GetHeight(96f);
            if (float.IsNaN(height) || float.IsInfinity(height) || height <= 0)
                throw new InvalidOperationException("A synthetic control has an unusable active font: " + root.GetType().Name);
            foreach (Control child in root.Controls) AssertFontsUsable(child);
        }
        private static void Pump()
        {
            // This dispatches only the fresh fixture's layout/paint messages.
            for (int i = 0; i < 8; ++i) Application.DoEvents();
        }
        private static HostViewSnapshot Snapshot(HostViewPhase phase, bool enrollmentMode)
        {
            bool active = phase == HostViewPhase.Invitation || phase == HostViewPhase.Request ||
                phase == HostViewPhase.Preparing || phase == HostViewPhase.Sharing || phase == HostViewPhase.Stopping;
            bool named = phase == HostViewPhase.Request || phase == HostViewPhase.Preparing || phase == HostViewPhase.Sharing;
            string status = phase == HostViewPhase.Failed ?
                "화면 공유를 시작하지 못했어요. 선택한 네트워크와 포트 48631을 사용할 수 있는지 확인해주세요." :
                phase == HostViewPhase.Sharing ? "화면을 전송하고 있어요. 중지하면 이번 연결의 권한이 끝나요." :
                phase == HostViewPhase.Request ? "연결할 Mac을 확인해주세요. 아직 화면과 입력은 공유되지 않았어요." :
                phase == HostViewPhase.Preparing ? "연결을 허용했어요. Windows 화면과 인코더를 준비하고 있어요." :
                phase == HostViewPhase.Invitation ? (enrollmentMode ? EnrollmentGuidance.Ready : "Mac에서 연결 코드를 입력한 뒤, 이 PC에서 요청을 허용해주세요.") :
                "공유를 시작하면 Mac에 보낼 연결 코드가 만들어져요.";
            string pin = active && phase != HostViewPhase.Stopping ?
                "3d72a8f1b6e940c51a23d7e4f8b06c92a5e134789f2b60d8c714eab39065f2cd" : "";
            return new HostViewSnapshot(phase, true, active, pin, named ? "작업용 MacBook" : "",
                named ? "192.168.50.24" : "", status, !enrollmentMode, enrollmentMode);
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
                // This separate renderer must fail, never wait on the default
                // WinForms ThreadException dialog in unattended Windows CI.
                // Configure before creating any control or native window handle.
                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
                Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
                string illustrationChecks = IllustrationChecks();
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
                frames.Add(new Frame("windows-short-idle.png", HostViewPhase.Idle, false, 1040, 740, 1) { EnrollmentMode = true });
                frames.Add(new Frame("windows-short-idle-scale150.png", HostViewPhase.Idle, false, 1040, 740, 1.5f) { EnrollmentMode = true });
                frames.Add(new Frame("windows-short-idle-scale200.png", HostViewPhase.Idle, false, 1040, 740, 2f) { EnrollmentMode = true });
                frames.Add(new Frame("windows-short-code.png", HostViewPhase.Invitation, false, 1040, 740, 1) { EnrollmentMode = true });
                frames.Add(new Frame("windows-short-code-compact.png", HostViewPhase.Invitation, false, 800, 620, 1) { EnrollmentMode = true });
                frames.Add(new Frame("windows-short-code-scale200.png", HostViewPhase.Invitation, false, 1040, 740, 2f) { EnrollmentMode = true });
                frames.Add(new Frame("windows-short-preparing.png", HostViewPhase.Preparing, false, 1040, 740, 1) { EnrollmentMode = true });
                frames.Add(new Frame("windows-short-sharing.png", HostViewPhase.Sharing, false, 1040, 740, 1) { EnrollmentMode = true });
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
                            HostViewSnapshot state = Snapshot(frame.Phase, frame.EnrollmentMode);
                            form.SetFixtureEnrollmentCode("01234567");
                            if (frame.StatusOverride != null || frame.ViewerLabelOverride != null)
                                state = new HostViewSnapshot(state.Phase, state.HasAddress, state.RunPresent, state.Pin, frame.ViewerLabelOverride ?? state.ViewerLabel, state.ObservedAddress, frame.StatusOverride ?? state.Status, state.CanCopy, state.EnrollmentMode);
                            Progress(frame, "before-presentation"); form.SetFixturePresentation(state, frame.Help); Progress(frame, "after-presentation");
                            AssertFontsUsable(form); Progress(frame, "fonts-usable-before-show");
                            Progress(frame, "before-show"); form.Show(); Progress(frame, "after-show");
                            form.PerformLayout(); Progress(frame, "after-initial-layout"); Pump(); Progress(frame, "after-initial-pump");
                            for (int layoutPass = 0; layoutPass < 3; ++layoutPass)
                            {
                                Progress(frame, "before-layout-pass-" + layoutPass); form.PrepareFixtureLayout();
                                Progress(frame, "after-layout-pass-" + layoutPass); Pump(); Progress(frame, "after-layout-pump-" + layoutPass);
                            }
                            if (frame.Phase == HostViewPhase.Invitation)
                            {
                                // Same-form normal/compact/normal transitions
                                // exercise both replacement and equal-value paths.
                                Size fullSize = form.ClientSize;
                                Progress(frame, "before-compact-font-probe"); form.ClientSize = new Size(800, 620);
                                form.PrepareFixtureLayout(); Pump(); AssertFontsUsable(form);
                                if (!form.FixtureCompactMode) throw new InvalidOperationException("The compact font probe did not enter compact presentation.");
                                Progress(frame, "fonts-usable-compact"); form.ClientSize = fullSize;
                                form.PrepareFixtureLayout(); Pump(); AssertFontsUsable(form);
                                if (frame.Width >= 920 && frame.Scale == 1 && form.FixtureCompactMode) throw new InvalidOperationException("The compact font probe did not restore normal presentation.");
                                form.PrepareFixtureLayout(); AssertFontsUsable(form); Progress(frame, "fonts-usable-restored");
                                Progress(frame, "before-help"); form.SetFixturePresentation(state, true); Progress(frame, "after-help"); Pump(); Progress(frame, "after-help-pump");
                                AssertFontsUsable(form); Progress(frame, "fonts-usable-help");
                                if (form.CopyVisible) throw new InvalidOperationException("Invitation copy action must be hidden on the help page (visible=" + form.CopyVisible + ",enabled=" + form.CopyEnabled + ").");
                                Progress(frame, "before-help-return"); form.SetFixturePresentation(state, false); Progress(frame, "after-help-return"); Pump(); Progress(frame, "after-help-return-pump");
                                AssertFontsUsable(form); Progress(frame, "fonts-usable-help-return");
                                if (form.CopyVisible != !frame.EnrollmentMode || form.CopyEnabled != !frame.EnrollmentMode)
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
                            bool expectedCopy = !frame.Help && !frame.EnrollmentMode && frame.Phase == HostViewPhase.Invitation;
                            if (form.CopyVisible != expectedCopy || form.CopyEnabled != expectedCopy)
                                throw new InvalidOperationException("Only an available invitation has a copy action.");
                            if (form.ApprovalEnabled != expectedApproval)
                                throw new InvalidOperationException("Approval must be an explicit pending-request action.");
                            if (form.StopVisible != state.RunPresent) throw new InvalidOperationException("Stop action is not lifecycle-bound.");
                            string expectedCode = frame.EnrollmentMode && frame.Phase == HostViewPhase.Invitation ? "0123 4567" : "";
                            if (form.DisplayedEnrollmentCode != expectedCode) throw new InvalidOperationException("Only the current short-code invitation is displayed.");
                            if (frame.EnrollmentMode && frame.Phase == HostViewPhase.Invitation && form.DisplayedStatus != EnrollmentGuidance.Ready)
                                throw new InvalidOperationException("The short-code footer must use production enrollment guidance.");
                            if (form.FixtureQualityEditable == state.RunPresent)
                                throw new InvalidOperationException("Quality is selectable only before the sharing run.");
                            AssertFontsUsable(form);
                            if (!form.FixtureFooterFits) throw new InvalidOperationException("Fixed status text and stop action must fit the actual client viewport.");
                            if (!form.FixtureEnrollmentCodeFits) throw new InvalidOperationException("The complete short code must fit the actual client viewport.");
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
                                    ",\"state\":" + Q(frame.Phase.ToString()) + ",\"enrollmentMode\":" + (frame.EnrollmentMode ? "true" : "false") + ",\"shortCodeFits\":true,\"controlCount\":" + CountControls(form) +
                                    ",\"sampleColors\":" + sampleColors.Count + ",\"pinExact\":true,\"brandPainted\":true,\"fontsUsable\":true,\"effectsBound\":false}");
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
                    "\"uiExceptionPolicy\":\"ThrowException\"," +
                    "\"scaleScope\":\"layout/font geometry simulation only; actual drawing DPI recorded; not a per-monitor DPI acceptance test\"," +
                    "\"monitorIllustrationChecks\":" + illustrationChecks + "," +
                    "\"brandIconSHA256\":" + Q(Digest(iconPath)) + ",\"images\":[" + string.Join(",", records.ToArray()) + "]}";
                File.WriteAllText(Path.Combine(output, "visual-checks.json"), report + Environment.NewLine, new UTF8Encoding(false));
                Console.WriteLine(report); return 0;
            }
            catch (Exception error)
            {
                // Only synthetic fixture diagnostics, without user/service data.
                string diagnostic = "Synthetic UI rendering failed [" + currentFrame + " stage=" + currentStage + "]: " + error;
                Console.Error.WriteLine(diagnostic);
                if (progressPath != null)
                {
                    try { File.AppendAllText(progressPath, diagnostic + Environment.NewLine, new UTF8Encoding(false)); }
                    catch (IOException) { Console.Error.WriteLine("The synthetic failure log could not be persisted."); }
                    catch (UnauthorizedAccessException) { Console.Error.WriteLine("The synthetic failure log could not be persisted."); }
                }
                return 1;
            }
        }
    }
}
