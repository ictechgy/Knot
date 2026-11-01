// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Net;
using System.Net.NetworkInformation;
using System.Windows.Forms;

namespace Knot.NativePreview
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new PreviewForm());
        }
    }

    internal sealed class PreviewForm : Form
    {
        private readonly float scale;
        private readonly bool fixtureMode;
        private readonly ComboBox addresses = new ComboBox();
        private readonly PreviewButton share, copy, stop, approve, decline, desktopNavigation, helpNavigation, networkDisclosure;
        private readonly TextBox status = new TextBox(), pin = new TextBox();
        private readonly Label headerTitle, headerSubtitle, badge, stateStep, stateTitle, stateDescription, requestName, requestAddress, requestWarning, networkValue;
        private readonly Panel scroll = new Panel();
        private readonly TableLayoutPanel body, helpBody, networkSettings;
        private readonly FlowLayoutPanel actions;
        private readonly PreviewCard taskCard;
        private readonly TableLayoutPanel requestPanel, trustPanel;
        private readonly MonitorIllustration illustration = new MonitorIllustration();
        private readonly List<Label> wrappingLabels = new List<Label>();
        private readonly RunPresentation presentation = new RunPresentation();
        private readonly Timer lifecycleTimer = new Timer();
        private Icon ownedIcon;
        private KnotBrandMark brandMark;
        private HostServer server;
        private HostViewPhase phase;
        private HostViewSnapshot fixture;
        private string rawStatus = "";
        private bool closing, helpVisible, settingWrapWidths, invitationAvailable;

        internal PreviewForm() : this(PrivateAddresses(), false, null, 1f) { }

        // The separate fixture supplies fake adapters and omits action handlers.
        // Production Main cannot select fixture mode through arguments.
        internal PreviewForm(IEnumerable<AdapterChoice> choices, bool visualFixture, Icon fixtureIcon, float layoutScale)
        {
            if (layoutScale < 1 || layoutScale > 2) throw new ArgumentException("Invalid fixture layout scale.");
            fixtureMode = visualFixture; scale = visualFixture ? layoutScale : 1f;
            Text = "Knot Native Preview"; ClientSize = new Size(P(1040), P(740));
            MinimumSize = new Size(P(800), P(620)); StartPosition = FormStartPosition.CenterScreen;
            AutoScaleDimensions = new SizeF(96, 96); AutoScaleMode = visualFixture ? AutoScaleMode.None : AutoScaleMode.Dpi;
            Font = PreviewStyle.Type(10.5f, FontStyle.Regular, scale); BackColor = PreviewStyle.Canvas;
            try
            {
                string installedIcon = System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "AppIcon.ico");
                ownedIcon = fixtureIcon != null ? (Icon)fixtureIcon.Clone() : System.IO.File.Exists(installedIcon) ? new Icon(installedIcon, 256, 256) : System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                if (ownedIcon != null) Icon = ownedIcon;
            }
            catch (ArgumentException) { }
            catch (System.Runtime.InteropServices.ExternalException) { }
            catch (NotSupportedException) { }
            catch (System.IO.FileNotFoundException) { }

            share = ActionButton("화면 공유 시작", PreviewButtonKind.Primary);
            copy = ActionButton("연결 코드 복사", PreviewButtonKind.Primary);
            stop = ActionButton("공유 중지", PreviewButtonKind.Danger);
            approve = ActionButton("이 연결 허용", PreviewButtonKind.Primary);
            decline = ActionButton("거절", PreviewButtonKind.Secondary);
            desktopNavigation = ActionButton("이 PC 공유", PreviewButtonKind.Navigation);
            helpNavigation = ActionButton("연결 안내", PreviewButtonKind.Navigation);
            networkDisclosure = ActionButton("연결 경로 변경", PreviewButtonKind.Secondary);
            networkDisclosure.Font = PreviewStyle.Type(9, FontStyle.Regular, scale);
            networkDisclosure.MinimumSize = new Size(0, P(34));

            TableLayoutPanel shell = Column(); shell.Dock = DockStyle.Fill; shell.AutoSize = false;
            shell.ColumnCount = 2; shell.ColumnStyles.Clear();
            shell.RowCount = 1; shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            shell.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, P(204)));
            shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            Controls.Add(shell);
            shell.Controls.Add(BuildSidebar(), 0, 0);

            Panel main = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty, BackColor = PreviewStyle.Canvas };
            shell.Controls.Add(main, 1, 0);
            TableLayoutPanel header = Column(); header.Dock = DockStyle.Top; header.Padding = new Padding(P(32), P(28), P(32), P(20));
            headerTitle = MakeLabel("이 PC를 Mac에서 열기", 24, FontStyle.Bold); headerTitle.Margin = new Padding(0, 0, 0, P(8));
            header.Controls.Add(headerTitle);
            headerSubtitle = MakeLabel("원하는 순간에만 화면과 입력을 공유하세요.", 10.5f, FontStyle.Regular); header.Controls.Add(headerSubtitle);
            badge = MakeLabel("공유 전", 9, FontStyle.Bold); badge.ForeColor = PreviewStyle.Muted;
            badge.Margin = new Padding(0, P(12), 0, 0); header.Controls.Add(badge);
            main.Controls.Add(header);

            Panel footer = BuildFooter(); main.Controls.Add(footer);
            scroll.Dock = DockStyle.Fill; scroll.AutoScroll = true; scroll.BackColor = PreviewStyle.Canvas;
            main.Controls.Add(scroll); scroll.BringToFront();
            body = Column(); body.Padding = new Padding(P(32), 0, P(32), P(20)); body.Dock = DockStyle.Top;
            scroll.Controls.Add(body);

            taskCard = new PreviewCard(scale); taskCard.Dock = DockStyle.Top; body.Controls.Add(taskCard);
            illustration.LayoutScale = scale; illustration.Height = P(88); illustration.Dock = DockStyle.Top; illustration.Margin = new Padding(0, 0, 0, P(12));
            taskCard.Content.Controls.Add(illustration);
            stateStep = MakeLabel("01  화면 공유", 9, FontStyle.Bold); stateStep.ForeColor = PreviewStyle.Accent;
            stateStep.Margin = new Padding(0, 0, 0, P(8)); taskCard.Content.Controls.Add(stateStep);
            stateTitle = MakeLabel("Mac에서 이 화면을 사용하세요", 17, FontStyle.Bold);
            stateTitle.Margin = new Padding(0, 0, 0, P(10)); taskCard.Content.Controls.Add(stateTitle);
            stateDescription = MakeLabel("", 10.5f, FontStyle.Regular);
            stateDescription.Margin = new Padding(0, 0, 0, P(20)); taskCard.Content.Controls.Add(stateDescription);

            requestPanel = Column(); requestPanel.Dock = DockStyle.Top;
            requestName = MakeLabel("", 13, FontStyle.Bold); requestName.Margin = new Padding(0, 0, 0, P(4));
            requestAddress = MakeLabel("", 10.5f, FontStyle.Regular); requestAddress.Margin = new Padding(0, 0, 0, P(6));
            requestWarning = MakeLabel("요청자가 보낸 이름이에요. 신원이 확인된 기기는 아니에요.", 9, FontStyle.Regular);
            requestWarning.Margin = new Padding(0, 0, 0, P(18));
            requestPanel.Controls.Add(requestName); requestPanel.Controls.Add(requestAddress); requestPanel.Controls.Add(requestWarning);
            taskCard.Content.Controls.Add(requestPanel);

            trustPanel = Column(); trustPanel.Dock = DockStyle.Top; trustPanel.Margin = new Padding(0, 0, 0, P(18));
            Label trustTitle = MakeLabel("인증서 지문 · Mac에 표시된 값과 비교해주세요", 9, FontStyle.Bold);
            trustTitle.Margin = new Padding(0, 0, 0, P(8)); trustPanel.Controls.Add(trustTitle);
            pin.ReadOnly = true; pin.Multiline = true; pin.WordWrap = true; pin.BorderStyle = BorderStyle.None;
            pin.Font = new Font("Consolas", 10 * scale); pin.BackColor = PreviewStyle.Surface; pin.ForeColor = PreviewStyle.Ink;
            pin.Dock = DockStyle.Top; pin.Height = P(43); pin.Margin = Padding.Empty;
            pin.AccessibleName = "현재 연결의 인증서 SHA-256 지문"; pin.ShortcutsEnabled = true; trustPanel.Controls.Add(pin);
            taskCard.Content.Controls.Add(trustPanel);

            actions = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = true, Margin = Padding.Empty };
            actions.Controls.AddRange(new Control[] { share, copy, approve, decline });
            taskCard.Content.Controls.Add(actions);

            PreviewCard networkCard = new PreviewCard(scale); networkCard.Dock = DockStyle.Top; body.Controls.Add(networkCard);
            TableLayoutPanel networkHeading = Column(); networkHeading.ColumnCount = 2; networkHeading.ColumnStyles.Clear();
            networkHeading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); networkHeading.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            Label networkTitle = MakeLabel("연결 네트워크", 9, FontStyle.Bold); networkTitle.ForeColor = PreviewStyle.Muted;
            networkHeading.Controls.Add(networkTitle, 0, 0); networkHeading.Controls.Add(networkDisclosure, 1, 0);
            networkHeading.Dock = DockStyle.Top; networkCard.Content.Controls.Add(networkHeading);
            networkValue = MakeLabel("", 10.5f, FontStyle.Regular); networkValue.Margin = new Padding(0, P(4), 0, 0);
            networkCard.Content.Controls.Add(networkValue);
            networkSettings = Column(); networkSettings.Dock = DockStyle.Top; networkSettings.Margin = new Padding(0, P(14), 0, 0);
            networkSettings.Controls.Add(MakeLabel("같은 Wi-Fi 또는 Tailscale 경로를 선택하세요.", 9, FontStyle.Regular));
            addresses.DropDownStyle = ComboBoxStyle.DropDownList; addresses.FlatStyle = FlatStyle.Flat;
            addresses.Dock = DockStyle.Top; addresses.DropDownWidth = P(650); addresses.Font = PreviewStyle.Type(10, FontStyle.Regular, scale);
            addresses.AccessibleName = "화면 공유에 사용할 네트워크"; addresses.Margin = new Padding(0, P(8), 0, 0);
            foreach (AdapterChoice choice in choices) addresses.Items.Add(choice);
            if (addresses.Items.Count > 0) addresses.SelectedIndex = 0;
            networkSettings.Controls.Add(addresses); networkSettings.Visible = false; networkCard.Content.Controls.Add(networkSettings);

            Label privacy = MakeLabel("허용한 연결에서만 화면과 입력을 공유해요. 연결 권한은 이번 세션에만 유지돼요.", 9, FontStyle.Regular);
            privacy.Margin = new Padding(P(2), 0, P(2), P(12)); body.Controls.Add(privacy);

            helpBody = BuildHelp(); helpBody.Dock = DockStyle.Top; helpBody.Visible = false; scroll.Controls.Add(helpBody);
            desktopNavigation.Click += delegate { ShowHelp(false); };
            helpNavigation.Click += delegate { ShowHelp(true); };
            networkDisclosure.Click += delegate { networkSettings.Visible = !networkSettings.Visible; UpdateWrapWidths(); };
            addresses.SelectedIndexChanged += delegate { UpdateNetwork(); };
            SizeChanged += delegate { UpdateWrapWidths(); };
            body.SizeChanged += delegate { UpdateWrapWidths(); };
            helpBody.SizeChanged += delegate { UpdateWrapWidths(); };
            lifecycleTimer.Interval = 250;
            lifecycleTimer.Tick += delegate
            {
                if (server == null) return;
                HostViewPhase before = phase;
                if (presentation.IsCurrent(server.Identity) && server.IsActive) phase = HostViewPhase.Sharing;
                else if (phase == HostViewPhase.Sharing) phase = HostViewPhase.Stopping;
                if (before != phase) ApplyCurrentPresentation();
            };
            if (!fixtureMode) BindActions();
            FormClosing += delegate
            {
                closing = true; lifecycleTimer.Stop();
                if (server != null) { presentation.Clear(server.Identity); pin.Clear(); server.Dispose(); server = null; }
            };
            FormClosed += delegate
            {
                lifecycleTimer.Dispose();
                if (ownedIcon != null) { ownedIcon.Dispose(); ownedIcon = null; }
            };
            phase = addresses.Items.Count > 0 ? HostViewPhase.Idle : HostViewPhase.Failed;
            rawStatus = addresses.Items.Count > 0 ? "공유를 시작하면 Mac에 보낼 연결 코드가 만들어져요." : "사용할 수 있는 사설 네트워크가 없어요. Wi-Fi나 Tailscale 연결을 확인해주세요.";
            UpdateNetwork(); ShowHelp(false); ApplyCurrentPresentation();
        }

        private int P(float value) { return (int)Math.Round(value * scale); }
        private PreviewButton ActionButton(string text, PreviewButtonKind kind) { return new PreviewButton(text, kind, scale); }
        private TableLayoutPanel Column()
        {
            TableLayoutPanel panel = new TableLayoutPanel { ColumnCount = 1, Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Margin = Padding.Empty, BackColor = Color.Transparent };
            panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); return panel;
        }
        private Label MakeLabel(string text, float size, FontStyle style)
        {
            Label label = new Label { Text = text, Font = PreviewStyle.Type(size, style, scale), AutoSize = true, Dock = DockStyle.Top, UseMnemonic = false,
                ForeColor = style == FontStyle.Bold ? PreviewStyle.Ink : PreviewStyle.Muted, BackColor = Color.Transparent, Margin = Padding.Empty, MaximumSize = new Size(P(650), 0) };
            wrappingLabels.Add(label); return label;
        }
        private Control BuildSidebar()
        {
            Panel rail = new Panel { Dock = DockStyle.Fill, BackColor = PreviewStyle.Rail, Margin = Padding.Empty, Padding = new Padding(P(18), P(28), P(18), P(22)) };
            TableLayoutPanel top = Column(); top.Dock = DockStyle.Top;
            brandMark = new KnotBrandMark(ownedIcon) { Width = P(40), Height = P(40), MinimumSize = new Size(P(40), P(40)), Margin = new Padding(P(8), 0, 0, P(12)) };
            top.Controls.Add(brandMark);
            Label name = MakeLabel("Knot", 21, FontStyle.Bold); name.Margin = new Padding(P(8), 0, 0, P(3)); top.Controls.Add(name);
            Label preview = MakeLabel(fixtureMode ? "미리보기 · 합성 화면" : "Native Preview", 8.5f, FontStyle.Regular);
            preview.Margin = new Padding(P(8), 0, 0, P(34)); top.Controls.Add(preview);
            foreach (PreviewButton button in new PreviewButton[] { desktopNavigation, helpNavigation })
            { button.Dock = DockStyle.Top; button.AutoSize = false; button.Height = P(44); button.Margin = new Padding(0, 0, 0, P(6)); top.Controls.Add(button); }
            rail.Controls.Add(top);
            Label footer = MakeLabel("컴퓨터를 잇다.\r\n작업을 이어가다.", 9, FontStyle.Regular);
            footer.Dock = DockStyle.Bottom; footer.Margin = new Padding(P(8), 0, 0, 0); rail.Controls.Add(footer);
            return rail;
        }
        private Panel BuildFooter()
        {
            Panel footer = new Panel { Dock = DockStyle.Bottom, Height = P(88), Padding = new Padding(P(32), P(18), P(32), P(18)), BackColor = PreviewStyle.Canvas };
            footer.Paint += delegate(object sender, PaintEventArgs e) { using (Pen line = new Pen(PreviewStyle.Border)) e.Graphics.DrawLine(line, P(32), 0, footer.Width - P(32), 0); };
            TableLayoutPanel row = Column(); row.Dock = DockStyle.Fill; row.AutoSize = false; row.ColumnCount = 2; row.ColumnStyles.Clear();
            row.RowCount = 1; row.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            status.ReadOnly = true; status.Multiline = true; status.WordWrap = true; status.BorderStyle = BorderStyle.None;
            status.BackColor = PreviewStyle.Canvas; status.ForeColor = PreviewStyle.Muted; status.Font = PreviewStyle.Type(9.5f, FontStyle.Regular, scale);
            status.Dock = DockStyle.Fill; status.Margin = new Padding(0, P(3), P(18), 0); status.AccessibleName = "현재 공유 상태";
            stop.Margin = Padding.Empty; row.Controls.Add(status, 0, 0); row.Controls.Add(stop, 1, 0); footer.Controls.Add(row); return footer;
        }
        private TableLayoutPanel BuildHelp()
        {
            TableLayoutPanel help = Column(); help.Padding = new Padding(P(32), 0, P(32), P(20));
            PreviewCard steps = new PreviewCard(scale); steps.Dock = DockStyle.Top;
            Label title = MakeLabel("세 단계로 연결하세요", 17, FontStyle.Bold); title.Margin = new Padding(0, 0, 0, P(20)); steps.Content.Controls.Add(title);
            AddHelpStep(steps.Content, "01  이 PC에서 공유 시작", "‘화면 공유 시작’을 누르고 연결 코드를 복사하세요.");
            AddHelpStep(steps.Content, "02  Mac에서 코드 확인", "Knot Native Preview에 코드를 붙여 넣고, 두 화면의 인증서 지문이 같은지 확인하세요.");
            AddHelpStep(steps.Content, "03  이 PC에서 연결 허용", "요청 이름과 주소를 확인한 뒤 연결을 허용하세요. 이름은 인증된 신원이 아니에요.");
            help.Controls.Add(steps);
            PreviewCard scope = new PreviewCard(scale); scope.Dock = DockStyle.Top;
            Label scopeTitle = MakeLabel("이번 미리보기에서 알아둘 점", 12, FontStyle.Bold); scopeTitle.Margin = new Padding(0, 0, 0, P(10)); scope.Content.Controls.Add(scopeTitle);
            scope.Content.Controls.Add(MakeLabel("연결 코드는 2분 동안 한 번만 사용할 수 있어요. 다시 연결할 때는 새 코드가 필요해요.\r\n\r\n로그인된 Windows 기본 SDR 가로 화면과 하드웨어 H.264 인코더가 필요해요.\r\n\r\n파일·오디오·무모니터·HDR·잠금/UAC 화면·자동 업데이트는 아직 지원하지 않아요.\r\n\r\n코드 복사는 현재 클립보드를 바꾸고 Windows 기록·클라우드 제외를 요청해요. 다른 프로그램의 현재 클립보드 접근까지 막지는 않아요.\r\n\r\n중지는 입력 해제를 요청해요. Windows가 거부하면 제한된 재시도로 해제 성공을 보장할 수는 없어요.", 10, FontStyle.Regular));
            help.Controls.Add(scope); return help;
        }
        private void AddHelpStep(TableLayoutPanel parent, string title, string description)
        {
            Label heading = MakeLabel(title, 11, FontStyle.Bold); heading.Margin = new Padding(0, 0, 0, P(6)); parent.Controls.Add(heading);
            Label detail = MakeLabel(description, 10, FontStyle.Regular); detail.Margin = new Padding(0, 0, 0, P(20)); parent.Controls.Add(detail);
        }
        private void ShowHelp(bool show)
        {
            helpVisible = show; body.Visible = !show; helpBody.Visible = show;
            headerTitle.Text = show ? "Mac 연결 안내" : "이 PC를 Mac에서 열기";
            headerSubtitle.Text = show ? "처음 연결부터, 공유를 마칠 때까지." : "원하는 순간에만 화면과 입력을 공유하세요.";
            desktopNavigation.Selected = !show; helpNavigation.Selected = show; desktopNavigation.Invalidate(); helpNavigation.Invalidate();
            desktopNavigation.AccessibleDescription = show ? "이 PC 공유 화면으로 이동" : "현재 선택한 화면";
            helpNavigation.AccessibleDescription = show ? "현재 선택한 화면" : "연결 안내 화면으로 이동";
            scroll.AutoScrollPosition = Point.Empty; UpdateWrapWidths();
        }
        private void UpdateWrapWidths()
        {
            if (settingWrapWidths) return;
            settingWrapWidths = true;
            try
            {
                foreach (Label label in wrappingLabels)
                {
                    if (label.Parent == null) continue;
                    int width = Math.Max(P(80), label.Parent.ClientSize.Width - label.Parent.Padding.Horizontal - label.Margin.Horizontal);
                    if (label.MaximumSize.Width != width) label.MaximumSize = new Size(width, 0);
                }
            }
            finally { settingWrapWidths = false; }
        }
        private void UpdateNetwork()
        {
            AdapterChoice selected = addresses.SelectedItem as AdapterChoice;
            if (networkValue != null) networkValue.Text = selected == null ? "사용 가능한 연결 경로가 없어요" : selected.FriendlyName + "  ·  " + selected.Address + (selected.IsOverlay ? "  ·  Tailscale" : "");
        }
        private HostViewSnapshot CurrentSnapshot()
        {
            if (fixtureMode && fixture != null) return fixture;
            ApprovalMetadata approval = presentation.Approval;
            return new HostViewSnapshot(phase, addresses.Items.Count > 0, server != null, presentation.Pin,
                approval == null ? "" : approval.ClaimedViewerLabel, approval == null ? "" : approval.ObservedRemoteIPv4, PreviewCopy.Status(rawStatus), invitationAvailable);
        }
        private void ApplyCurrentPresentation() { ApplyPresentation(CurrentSnapshot()); }
        private void ApplyPresentation(HostViewSnapshot view)
        {
            bool idle = view.Phase == HostViewPhase.Idle || view.Phase == HostViewPhase.Stopped || view.Phase == HostViewPhase.Failed;
            badge.Text = "●  " + PreviewCopy.Phase(view.Phase);
            badge.ForeColor = view.Phase == HostViewPhase.Failed ? PreviewStyle.Warning : PreviewStyle.Muted;
            illustration.Visible = idle;
            stateStep.Text = view.Phase == HostViewPhase.Failed ? "공유 준비 확인" : idle ? "01  화면 공유" : view.Phase == HostViewPhase.Invitation ? "02  Mac에 코드 보내기" : "03  연결 확인";
            stateTitle.Text = view.Phase == HostViewPhase.Failed ? "공유 준비를 확인해주세요" : view.Phase == HostViewPhase.Stopped ? "새 코드로 다시 연결하세요" : idle ? "Mac에서 이 화면을 사용하세요" : view.Phase == HostViewPhase.Invitation ? "연결 코드를 Mac에 보내세요" : view.Phase == HostViewPhase.Request ? "이 Mac의 연결을 허용할까요?" : view.Phase == HostViewPhase.Sharing ? "Windows 화면을 전송하고 있어요" : view.Phase == HostViewPhase.Stopping ? "화면 공유를 마치고 있어요" : "Windows 화면을 준비하고 있어요";
            stateDescription.Text = view.Phase == HostViewPhase.Failed ? view.Status : view.Phase == HostViewPhase.Stopped ? "이전 연결의 권한은 끝났어요.\r\n공유를 시작하면 새 연결 코드가 만들어져요." : idle ? "공유를 시작하면 연결 코드가 만들어져요.\r\nMac에서 코드를 확인한 뒤 이 PC에서 연결을 허용해주세요." : view.Phase == HostViewPhase.Invitation ? "Mac의 Knot Native Preview에 붙여 넣으세요.\r\n연결 코드는 2분 동안 한 번만 사용할 수 있어요." : view.Phase == HostViewPhase.Request ? "직접 연결을 요청한 Mac인지 이름과 주소를 확인해주세요." : view.Phase == HostViewPhase.Sharing ? "이 PC의 화면과 입력이 공유 중이에요.\r\n다시 연결하려면 새 연결 코드가 필요해요." : view.Phase == HostViewPhase.Stopping ? "이번 연결의 권한을 종료하고 있어요. 정리가 끝나면 새 코드를 만들 수 있어요." : "연결은 허용됐어요. 인코더와 전송 준비가 끝날 때까지 잠시 기다려주세요.";
            requestPanel.Visible = view.ViewerLabel.Length > 0 && (view.Phase == HostViewPhase.Request || view.Phase == HostViewPhase.Preparing || view.Phase == HostViewPhase.Sharing);
            requestName.Text = view.ViewerLabel + "  ·  확인되지 않은 이름";
            requestAddress.Text = "연결 주소  " + view.ObservedAddress;
            requestWarning.Visible = view.Phase == HostViewPhase.Request;
            trustPanel.Visible = view.Pin.Length != 0;
            if (pin.Text != view.Pin) pin.Text = view.Pin;
            share.Visible = idle; share.Enabled = idle && view.HasAddress && !view.RunPresent;
            copy.Visible = view.Phase == HostViewPhase.Invitation; copy.Enabled = view.Phase == HostViewPhase.Invitation && view.CanCopy && view.RunPresent;
            approve.Visible = decline.Visible = view.Phase == HostViewPhase.Request;
            approve.Enabled = decline.Enabled = view.Phase == HostViewPhase.Request && view.RunPresent;
            stop.Visible = view.RunPresent; stop.Enabled = view.RunPresent && view.Phase != HostViewPhase.Stopping;
            addresses.Enabled = networkDisclosure.Enabled = !view.RunPresent;
            if (status.Text != view.Status) status.Text = view.Status;
            UpdateWrapWidths();
        }
        internal void SetFixturePresentation(HostViewSnapshot snapshot, bool showHelp)
        {
            if (!fixtureMode) throw new InvalidOperationException("Synthetic presentation is unavailable in the production form.");
            fixture = snapshot; ShowHelp(showHelp); ApplyCurrentPresentation();
        }
        internal bool FixtureMode { get { return fixtureMode; } }
        internal bool HelpVisible { get { return helpVisible; } }
        internal string DisplayedPin { get { return pin.Text; } }
        internal bool ApprovalVisible { get { return approve.Visible; } }
        internal bool StopVisible { get { return stop.Visible; } }
        internal bool ShareVisible { get { return share.Visible; } }
        internal bool ShareEnabled { get { return share.Visible && share.Enabled; } }
        internal bool CopyVisible { get { return copy.Visible; } }
        internal bool CopyEnabled { get { return copy.Visible && copy.Enabled; } }
        internal bool ApprovalEnabled { get { return approve.Visible && approve.Enabled && decline.Visible && decline.Enabled; } }
        internal bool FixtureBrandPainted { get { return brandMark != null && brandMark.Visible && brandMark.DrawCalls > 0; } }

        private void BindActions()
        {
            share.Click += delegate { StartShare(); };
            copy.Click += delegate
            {
                try
                {
                    if (server != null && presentation.IsCurrent(server.Identity))
                    {
                        SecretClipboard.CopyOwnInvitation(server.GetInvitation());
                        rawStatus = "연결 코드를 복사했어요. Mac에 붙여 넣어주세요. 코드는 공유 시작 후 2분 동안 한 번만 사용할 수 있어요.";
                    }
                }
                catch (ProtocolException) { invitationAvailable = false; rawStatus = "이 연결 코드는 더 이상 사용할 수 없어요. 공유를 중지하고 새 코드를 만들어주세요."; }
                catch (System.Runtime.InteropServices.ExternalException) { rawStatus = "클립보드를 사용할 수 없거나 기록 제외를 적용하지 못했어요. 코드 복사를 다시 시도해주세요."; }
                ApplyCurrentPresentation();
            };
            stop.Click += delegate { StopShare(); };
            approve.Click += delegate { Decide(true); }; decline.Click += delegate { Decide(false); };
        }
        private static List<AdapterChoice> PrivateAddresses()
        {
            List<AdapterChoice> result = new List<AdapterChoice>();
            foreach (NetworkInterface adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (adapter.OperationalStatus != OperationalStatus.Up) continue;
                IPInterfaceProperties properties = adapter.GetIPProperties(); bool gateway = false;
                foreach (GatewayIPAddressInformation entry in properties.GatewayAddresses)
                    if (entry.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && !entry.Address.Equals(IPAddress.Any) && !IPAddress.IsLoopback(entry.Address)) gateway = true;
                foreach (UnicastIPAddressInformation entry in properties.UnicastAddresses)
                    if (NativeProtocol.IsPrivate(entry.Address)) result.Add(new AdapterChoice(entry.Address, adapter.Name, adapter.NetworkInterfaceType, gateway));
            }
            return AdapterChoice.Ordered(result);
        }
        private void OnUi(Action action)
        {
            if (closing || IsDisposed || !IsHandleCreated) return;
            try { BeginInvoke(new MethodInvoker(delegate { if (!closing && !IsDisposed) action(); })); } catch (InvalidOperationException) { }
        }
        private void StartShare()
        {
            AdapterChoice selected = addresses.SelectedItem as AdapterChoice;
            if (server != null || selected == null) return;
            try
            {
                HostServer run = new HostServer(selected.Address, 48631, new WindowsMediaFactory(), new WindowsInputSink(), false, null);
                server = run; presentation.Bind(run.Identity); phase = HostViewPhase.Invitation; invitationAvailable = true;
                run.StatusChanged = delegate(string text)
                {
                    OnUi(delegate
                    {
                        if (server != run || !presentation.IsCurrent(run.Identity)) return;
                        rawStatus = text;
                        if (run.IsActive) phase = HostViewPhase.Sharing;
                        ApplyCurrentPresentation();
                    });
                };
                run.ApprovalRequested = delegate(ApprovalMetadata metadata)
                {
                    OnUi(delegate
                    {
                        if (server != run || !presentation.PublishApproval(run.Identity, metadata)) return;
                        invitationAvailable = false; phase = HostViewPhase.Request; ShowHelp(false); ApplyCurrentPresentation();
                    });
                };
                run.Finished = delegate
                {
                    OnUi(delegate
                    {
                        if (server != run) return;
                        presentation.Clear(run.Identity); run.Dispose(); server = null; lifecycleTimer.Stop();
                        phase = HostViewPhase.Stopped; invitationAvailable = false;
                        ApplyCurrentPresentation();
                    });
                };
                rawStatus = "Mac에서 연결 코드를 입력한 뒤, 이 PC에서 요청을 허용해주세요.";
                ShowHelp(false); ApplyCurrentPresentation(); lifecycleTimer.Start(); run.Start();
            }
            catch (Exception)
            {
                if (server != null) { presentation.Clear(server.Identity); server.Dispose(); server = null; }
                lifecycleTimer.Stop(); phase = HostViewPhase.Failed; invitationAvailable = false;
                rawStatus = "화면 공유를 시작하지 못했어요. 선택한 네트워크와 포트 48631을 사용할 수 있는지 확인해주세요.";
                ApplyCurrentPresentation();
            }
        }
        private void Decide(bool allowed)
        {
            if (server == null || !presentation.IsCurrent(server.Identity) || phase != HostViewPhase.Request) return;
            phase = allowed ? HostViewPhase.Preparing : HostViewPhase.Stopping;
            server.RespondToApproval(allowed);
            rawStatus = allowed ? "연결을 허용했어요. Windows 화면과 인코더를 준비하고 있어요." : "연결 요청을 거절했어요. 이번 연결 권한을 종료하고 있어요.";
            ApplyCurrentPresentation();
        }
        private void StopShare()
        {
            if (server != null) { presentation.Clear(server.Identity); server.Stop(); phase = HostViewPhase.Stopping; }
            invitationAvailable = false;
            rawStatus = "화면 공유를 중지했어요. 이번 연결의 입력 해제를 요청했어요.";
            ApplyCurrentPresentation();
        }
    }
}
