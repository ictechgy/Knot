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
        private static void Main(string[] args)
        {
            if (NativeUpdateHandoff.TryRun(args)) return;
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            // One owner presents/manages this user's shared host and trust store.
            // This lease does not open the store and never terminates another app.
            IDisposable owner;
            try { owner = PersistentCertificateLease.TryAcquireHostOwner(NativeTrustedDevices.DirectoryPath); }
            catch (System.Security.Cryptography.CryptographicException)
            { MessageBox.Show("Knot 실행 권한을 확인하지 못했어요. 실행 중인 Knot을 확인하고 다시 시도해주세요.", "Knot"); return; }
            catch (UnauthorizedAccessException)
            { MessageBox.Show("Knot 실행 권한에 접근하지 못했어요. Windows 사용자 계정과 실행 중인 Knot을 확인해주세요.", "Knot"); return; }
            using (owner)
            {
                if (owner == null)
                {
                    MessageBox.Show("Knot이 이미 실행 중이에요. 열려 있는 Knot에서 연결과 등록 기기를 관리해주세요.", "Knot");
                    return;
                }
                Application.Run(new PreviewForm());
            }
        }
    }

    internal sealed class PreviewForm : Form
    {
        private NativeUpdates updates;
        private bool shareRequested;
        private bool certificateCompatibilityRequired, certificateRenewalRequired;
        private Label updateNotice;
        private PreviewButton updateAction;
        private readonly float scale;
        private readonly bool fixtureMode;
        private readonly string advertisedName;
        private readonly Action<string> fixtureTrace;
        private readonly ComboBox addresses = new ComboBox();
        private readonly ComboBox qualityProfiles = new ComboBox();
        private readonly CheckBox legacyMode = new CheckBox();
        private readonly CheckBox allowFiles = new CheckBox();
        private readonly CheckBox allowAudio = new CheckBox();
        private readonly PreviewButton chooseFileFolder, openFileFolder;
        private readonly Label fileFolderValue, fileFolderHint;
        private string fileRootPath;
        private string fileRootName = "Knot Files";
        private readonly Label shareScope;
        private readonly Label enrollmentCode = new Label();
        private readonly PreviewButton share, copy, stop, approve, decline, desktopNavigation, helpNavigation, networkDisclosure, compactDesktopNavigation, compactHelpNavigation;
        private readonly TextBox status = new TextBox(), pin = new TextBox();
        private readonly Label headerTitle, headerSubtitle, badge, stateStep, stateTitle, stateDescription, hostIdentity, numberLifetime, requestName, requestAddress, requestWarning, networkValue, privacy, trustTitle;
        private readonly Panel scroll = new Panel();
        private readonly TableLayoutPanel body, helpBody, networkSettings, shell, header;
        private readonly FlowLayoutPanel actions, compactNavigation;
        private readonly PreviewCard taskCard, networkCard, qualityCard, filesCard;
        private readonly Panel main, rail, footer;
        private readonly TableLayoutPanel requestPanel;
        private readonly PreviewTrustPanel trustPanel;
        private readonly MonitorIllustration illustration = new MonitorIllustration();
        private readonly List<Label> wrappingLabels = new List<Label>();
        private readonly Dictionary<Control, Font> ownedFonts = new Dictionary<Control, Font>();
        // Control.Visible includes ancestor visibility. Track the requested local
        // value so hidden pages do not repeatedly invalidate WinForms layout.
        private readonly Dictionary<Control, bool> localVisibility = new Dictionary<Control, bool>();
        private readonly RunPresentation presentation = new RunPresentation();
        private readonly Timer lifecycleTimer = new Timer();
        private Icon ownedIcon;
        private KnotBrandMark brandMark, compactBrandMark;
        private HostServer server;
        private HostViewPhase phase;
        private HostViewSnapshot fixture;
        private string rawStatus = "";
        private string rawFileStatus = "";
        private string fixtureCode = "";
        private bool closing, helpVisible, networkExpanded, settingWrapWidths, invitationAvailable, responsiveLayout, compactMode, densityApplied;

        internal PreviewForm() : this(PrivateAddresses(), false, null, 1f) { }

        // The separate fixture supplies fake adapters and omits action handlers.
        // Production Main cannot select fixture mode through arguments.
        internal PreviewForm(IEnumerable<AdapterChoice> choices, bool visualFixture, Icon fixtureIcon, float layoutScale, Action<string> trace = null)
        {
            if (layoutScale < 1 || layoutScale > 2) throw new ArgumentException("Invalid fixture layout scale.");
            fixtureMode = visualFixture; scale = visualFixture ? layoutScale : 1f; fixtureTrace = visualFixture ? trace : null;
            advertisedName = PreviewCopy.DiscoveryName(visualFixture ? "작업용 Windows" : Environment.MachineName);
            fileRootPath = visualFixture ? @"C:\Synthetic\Knot Files" : FileSharingOptions.DefaultRootPath;
            Text = "Knot Native Preview"; ClientSize = new Size(P(1040), P(740));
            MinimumSize = new Size(P(500), P(360)); StartPosition = FormStartPosition.CenterScreen;
            AutoScaleDimensions = new SizeF(96, 96); AutoScaleMode = visualFixture ? AutoScaleMode.None : AutoScaleMode.Dpi;
            SetOwnedFont(this, PreviewStyle.Type(10.5f, FontStyle.Regular, scale)); BackColor = PreviewStyle.Canvas;
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
            compactDesktopNavigation = ActionButton("이 PC 공유", PreviewButtonKind.Navigation);
            compactHelpNavigation = ActionButton("연결 안내", PreviewButtonKind.Navigation);
            networkDisclosure = ActionButton("연결 세부정보", PreviewButtonKind.Secondary);
            SetOwnedFont(networkDisclosure, PreviewStyle.Type(9, FontStyle.Regular, scale));
            networkDisclosure.MinimumSize = new Size(0, P(34));
            chooseFileFolder = ActionButton("폴더 변경", PreviewButtonKind.Secondary);
            openFileFolder = ActionButton("공유 폴더 열기", PreviewButtonKind.Secondary);
            foreach (PreviewButton button in new PreviewButton[] { chooseFileFolder, openFileFolder })
            {
                SetOwnedFont(button, PreviewStyle.Type(9, FontStyle.Regular, scale));
                button.MinimumSize = new Size(0, P(32)); button.Padding = new Padding(P(10), P(6), P(10), P(6));
            }

            shell = Column(); shell.Dock = DockStyle.Fill; shell.AutoSize = false;
            shell.ColumnCount = 2; shell.ColumnStyles.Clear();
            shell.RowCount = 1; shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            shell.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, P(204)));
            shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            Controls.Add(shell);
            rail = (Panel)BuildSidebar(); shell.Controls.Add(rail, 0, 0);

            main = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty, BackColor = PreviewStyle.Canvas };
            shell.Controls.Add(main, 1, 0);
            header = Column(); header.Dock = DockStyle.Top; header.Padding = new Padding(P(32), P(28), P(32), P(20));
            compactNavigation = BuildCompactNavigation(); SetViewVisible(compactNavigation, false); header.Controls.Add(compactNavigation);
            headerTitle = MakeLabel("Windows 화면 공유", 24, FontStyle.Bold); headerTitle.Margin = new Padding(0, 0, 0, P(8));
            header.Controls.Add(headerTitle);
            headerSubtitle = MakeLabel("이 PC를 Mac에서 사용하기 · 계정 없이 3단계로 연결", 10.5f, FontStyle.Regular); header.Controls.Add(headerSubtitle);
            badge = MakeLabel("공유 전", 9, FontStyle.Bold); badge.ForeColor = PreviewStyle.Muted;
            badge.Margin = new Padding(0, P(12), 0, 0); header.Controls.Add(badge);
            main.Controls.Add(header);

            footer = BuildFooter(); main.Controls.Add(footer);
            scroll.Dock = DockStyle.Fill; scroll.AutoScroll = true; scroll.BackColor = PreviewStyle.Canvas;
            main.Controls.Add(scroll); scroll.BringToFront();
            body = Column(); body.Padding = new Padding(P(32), 0, P(32), P(20)); body.Dock = DockStyle.Top;
            scroll.Controls.Add(body);

            taskCard = new PreviewCard(scale); taskCard.Dock = DockStyle.Top; body.Controls.Add(taskCard);
            illustration.Height = P(88); illustration.Dock = DockStyle.Top; illustration.Margin = new Padding(0, 0, 0, P(12));
            taskCard.Content.Controls.Add(illustration);
            stateStep = MakeLabel("01  화면 공유", 9, FontStyle.Bold); stateStep.ForeColor = PreviewStyle.Accent;
            stateStep.Margin = new Padding(0, 0, 0, P(8)); taskCard.Content.Controls.Add(stateStep);
            stateTitle = MakeLabel("Mac에서 이 화면을 사용하세요", 17, FontStyle.Bold);
            stateTitle.Margin = new Padding(0, 0, 0, P(10)); taskCard.Content.Controls.Add(stateTitle);
            stateDescription = MakeLabel("", 10.5f, FontStyle.Regular);
            stateDescription.Margin = new Padding(0, 0, 0, P(20)); taskCard.Content.Controls.Add(stateDescription);

            hostIdentity = MakeLabel("", 10.5f, FontStyle.Bold);
            hostIdentity.Margin = new Padding(0, 0, 0, P(12));
            hostIdentity.AccessibleName = "Mac에서 선택할 이 Windows의 이름과 주소";
            taskCard.Content.Controls.Add(hostIdentity);

            enrollmentCode.Dock = DockStyle.Top; enrollmentCode.AutoSize = false; enrollmentCode.Height = P(60);
            enrollmentCode.TextAlign = ContentAlignment.MiddleCenter; enrollmentCode.BackColor = PreviewStyle.Surface;
            enrollmentCode.ForeColor = PreviewStyle.Ink; enrollmentCode.Margin = new Padding(0, 0, 0, P(20));
            SetOwnedFont(enrollmentCode, new Font("Consolas", 30 * scale, FontStyle.Bold));
            enrollmentCode.AccessibleName = "8자리 일회용 연결번호";
            taskCard.Content.Controls.Add(enrollmentCode);
            numberLifetime = MakeLabel(PreviewCopy.NumberLifetime, 9, FontStyle.Regular);
            numberLifetime.Margin = new Padding(0, 0, 0, P(12)); taskCard.Content.Controls.Add(numberLifetime);

            requestPanel = Column(); requestPanel.Dock = DockStyle.Top;
            requestName = MakeLabel("", 13, FontStyle.Bold); requestName.Margin = new Padding(0, 0, 0, P(4));
            requestAddress = MakeLabel("", 10.5f, FontStyle.Regular); requestAddress.Margin = new Padding(0, 0, 0, P(6));
            requestWarning = MakeLabel("요청자가 보낸 이름이에요. 신원이 확인된 기기는 아니에요.", 9, FontStyle.Regular);
            requestWarning.Margin = new Padding(0, 0, 0, P(18));
            requestPanel.Controls.Add(requestName); requestPanel.Controls.Add(requestAddress); requestPanel.Controls.Add(requestWarning);
            taskCard.Content.Controls.Add(requestPanel);

            trustTitle = MakeLabel("인증서 지문 · Mac에 표시된 값과 비교해주세요", 9, FontStyle.Bold);
            wrappingLabels.Remove(trustTitle);
            pin.ReadOnly = true; pin.Multiline = true; pin.WordWrap = true; pin.BorderStyle = BorderStyle.None;
            SetOwnedFont(pin, new Font("Consolas", 10 * scale)); pin.BackColor = PreviewStyle.Surface; pin.ForeColor = PreviewStyle.Ink;
            pin.Height = P(43); pin.Margin = Padding.Empty;
            pin.AccessibleName = "현재 연결의 인증서 SHA-256 지문"; pin.ShortcutsEnabled = true;
            trustPanel = new PreviewTrustPanel(trustTitle, pin) { Dock = DockStyle.Top, Margin = new Padding(0, 0, 0, P(18)) };
            taskCard.Content.Controls.Add(trustPanel);

            shareScope = MakeLabel("", 9, FontStyle.Bold);
            shareScope.Margin = new Padding(0, 0, 0, P(12));
            shareScope.AccessibleName = "이번 공유의 화면 입력, 공유 폴더와 직접 끌어온 탐색기 항목 범위";
            taskCard.Content.Controls.Add(shareScope);

            actions = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = true, Margin = Padding.Empty };
            actions.Controls.AddRange(new Control[] { share, copy, approve, decline });
            allowAudio.Text = "Windows 재생 소리 포함 · 마이크 제외";
            allowAudio.AutoSize = true; allowAudio.Checked = false;
            allowAudio.Margin = new Padding(P(8), P(12), 0, 0);
            allowAudio.AccessibleName = "이번 화면 공유에 Windows 재생 소리 포함, 마이크는 제외";
            SetOwnedFont(allowAudio, PreviewStyle.Type(9, FontStyle.Regular, scale));
            actions.Controls.Add(allowAudio);
            allowAudio.CheckedChanged += delegate { ApplyCurrentPresentation(); };
            taskCard.Content.Controls.Add(actions);

            filesCard = new PreviewCard(scale); filesCard.Dock = DockStyle.Top; body.Controls.Add(filesCard);
            allowFiles.Text = "파일·폴더 송수신 허용"; allowFiles.Checked = true;
            allowFiles.AutoSize = true; allowFiles.Dock = DockStyle.Top; allowFiles.Margin = new Padding(0, 0, 0, P(8));
            allowFiles.AccessibleName = "공유 폴더 송수신과 직접 끌어온 탐색기 항목 내보내기 허용";
            SetOwnedFont(allowFiles, PreviewStyle.Type(10, FontStyle.Bold, scale)); filesCard.Content.Controls.Add(allowFiles);
            fileFolderValue = MakeLabel(fileRootPath, 9.5f, FontStyle.Regular);
            fileFolderValue.AccessibleName = "Mac과 파일을 주고받을 Windows 공유 폴더";
            fileFolderValue.Margin = new Padding(0, 0, 0, P(8)); filesCard.Content.Controls.Add(fileFolderValue);
            fileFolderHint = MakeLabel("Mac 파일·폴더는 여기에 복사돼요. 탐색기에서 직접 끌어온 항목도 Mac으로 보낼 수 있어요.", 9, FontStyle.Regular);
            fileFolderHint.Margin = new Padding(0, 0, 0, P(10)); filesCard.Content.Controls.Add(fileFolderHint);
            FlowLayoutPanel fileActions = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = true, Margin = Padding.Empty };
            fileActions.Controls.AddRange(new Control[] { chooseFileFolder, openFileFolder }); filesCard.Content.Controls.Add(fileActions);

            qualityCard = new PreviewCard(scale); qualityCard.Dock = DockStyle.Top; body.Controls.Add(qualityCard);
            Label qualityTitle = MakeLabel("화질", 9, FontStyle.Bold);
            qualityTitle.Margin = new Padding(0, 0, 0, P(8)); qualityCard.Content.Controls.Add(qualityTitle);
            qualityProfiles.DropDownStyle = ComboBoxStyle.DropDownList; qualityProfiles.FlatStyle = FlatStyle.Flat;
            qualityProfiles.Dock = DockStyle.Top; qualityProfiles.DropDownWidth = P(650);
            qualityProfiles.AccessibleName = "공유를 시작할 화면 화질";
            SetOwnedFont(qualityProfiles, PreviewStyle.Type(10, FontStyle.Regular, scale));
            qualityProfiles.Items.AddRange(new object[] { MediaQualityProfile.Sharp4K, MediaQualityProfile.Smooth4K, MediaQualityProfile.Compatible1080 });
            qualityProfiles.SelectedIndex = 0; qualityCard.Content.Controls.Add(qualityProfiles);
            Label qualityHint = MakeLabel("Windows 원본을 최대 4K로 전송해요. 원본보다 확대하지 않으며, GPU가 지원해야 해요. 문제가 있으면 호환 모드로 다시 시작하세요.", 9, FontStyle.Regular);
            qualityHint.Margin = new Padding(0, P(10), 0, 0); qualityCard.Content.Controls.Add(qualityHint);

            networkCard = new PreviewCard(scale); networkCard.Dock = DockStyle.Top; body.Controls.Add(networkCard);
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
            addresses.Dock = DockStyle.Top; addresses.DropDownWidth = P(650); SetOwnedFont(addresses, PreviewStyle.Type(10, FontStyle.Regular, scale));
            addresses.AccessibleName = "화면 공유에 사용할 네트워크"; addresses.Margin = new Padding(0, P(8), 0, 0);
            foreach (AdapterChoice choice in choices) addresses.Items.Add(choice);
            if (addresses.Items.Count > 0) addresses.SelectedIndex = 0;
            networkSettings.Controls.Add(addresses);
            legacyMode.Text = "고급: 긴 연결코드와 Windows 승인 사용"; legacyMode.AutoSize = true; legacyMode.Dock = DockStyle.Top;
            legacyMode.Margin = new Padding(0, P(12), 0, 0); legacyMode.AccessibleName = "기존 긴 연결코드 방식";
            SetOwnedFont(legacyMode, PreviewStyle.Type(9, FontStyle.Regular, scale)); networkSettings.Controls.Add(legacyMode);
            SetViewVisible(networkSettings, false); networkCard.Content.Controls.Add(networkSettings);

            privacy = MakeLabel("허용한 연결에서만 화면과 입력을 공유해요. 연결 권한은 이번 세션에만 유지돼요.", 9, FontStyle.Regular);
            privacy.Margin = new Padding(P(2), 0, P(2), P(12)); body.Controls.Add(privacy);

            helpBody = BuildHelp(); helpBody.Dock = DockStyle.Top; SetViewVisible(helpBody, false); scroll.Controls.Add(helpBody);
            desktopNavigation.Click += delegate { ShowHelp(false); };
            helpNavigation.Click += delegate { ShowHelp(true); };
            compactDesktopNavigation.Click += delegate { ShowHelp(false); };
            compactHelpNavigation.Click += delegate { ShowHelp(true); };
            networkDisclosure.Click += delegate { networkExpanded = !networkExpanded; SetViewVisible(networkSettings, networkExpanded); ApplyCurrentPresentation(); };
            legacyMode.CheckedChanged += delegate { if (server == null) ApplyCurrentPresentation(); };
            addresses.SelectedIndexChanged += delegate { UpdateNetwork(); };
            allowFiles.CheckedChanged += delegate { if (server == null) rawFileStatus = ""; ApplyCurrentPresentation(); };
            SizeChanged += delegate { ApplyResponsiveLayout(); UpdateWrapWidths(); };
            Shown += delegate
            {
                UpdateUpdaterPresentation();
                TraceFixture("shown-enter");
                // Complete native Show/activation before changing the hierarchy.
                // Exactly one deferred pass; layout outputs never enqueue more.
                BeginInvoke((MethodInvoker)delegate
                {
                    if (IsDisposed || Disposing) return;
                    TraceFixture("shown-deferred-enter"); ApplyResponsiveLayout(); UpdateWrapWidths(); TraceFixture("shown-deferred-exit");
                });
                TraceFixture("shown-exit");
            };
            // Child sizes are outputs of layout, not new presentation inputs.
            // Re-entering full layout from their SizeChanged callbacks creates
            // deferred AutoSize/scrollbar feedback, especially on hidden pages.
            lifecycleTimer.Interval = 250;
            lifecycleTimer.Tick += delegate
            {
                if (server == null) return;
                HostViewPhase before = phase;
                HostEnrollmentState enrollmentState = server.EnrollmentState;
                phase = PreviewCopy.ReconcileEnrollmentPhase(phase, enrollmentState,
                    presentation.IsCurrent(server.Identity) && server.IsActive);
                if (phase == HostViewPhase.RegisteredWaiting)
                { invitationAvailable = false; if (before != phase) rawStatus = EnrollmentGuidance.RegisteredWaiting; }
                else if (phase == HostViewPhase.Invitation && before != phase && enrollmentState == HostEnrollmentState.Number)
                { invitationAvailable = true; rawStatus = EnrollmentGuidance.Ready; }
                else if (phase == HostViewPhase.Stopping) invitationAvailable = false;
                if (before != phase) ApplyCurrentPresentation();
            };
            if (!fixtureMode) {
                BindActions(); qualityProfiles.SelectedIndex = NativePreferences.Quality;
                try { certificateRenewalRequired = RunCertificate.RequiresRenewal(); if (!certificateRenewalRequired) certificateCompatibilityRequired = RunCertificate.RequiresCompatibilityMigration(); }
                catch { /* StartShare reports a stored-identity failure without replacing it. */ }
                qualityProfiles.SelectedIndexChanged += delegate { NativePreferences.Quality = qualityProfiles.SelectedIndex; };
                updates = new NativeUpdates(); updates.Changed += delegate { OnUi(UpdateUpdaterPresentation); };
                updates.StartAutomaticChecks(); UpdateUpdaterPresentation();
                NativeUpdateResumeState updateResume = NativePreferences.ConsumeUpdateResume();
                if (updateResume != null) Shown += delegate {
                    try {
                        if (updateResume.UntilTicks <= DateTime.UtcNow.Ticks) return;
                        List<AdapterChoice> currentAdapters = new List<AdapterChoice>();
                        foreach (object item in addresses.Items) { AdapterChoice choice = item as AdapterChoice; if (choice != null) currentAdapters.Add(choice); }
                        AdapterChoice restoredAdapter = NativePreferences.SelectResumeAdapter(updateResume.Address, currentAdapters);
                        if (restoredAdapter == null || NativeTrustedDevices.List().Count == 0) return;
                        addresses.SelectedItem = restoredAdapter;
                        // Restore the exact prior consent before any listener or
                        // file scope can be constructed; never use default scope.
                        FileSharingOptions scope = new FileSharingOptions(updateResume.FileRootPath);
                        fileRootPath = updateResume.FileRootPath; fileRootName = scope.RootName;
                        allowFiles.Checked = updateResume.AllowFiles;
                        ApplyCurrentPresentation(); StartShare();
                    } catch { }
                };
            }
            FormClosing += delegate
            {
                closing = true; shareRequested = false; lifecycleTimer.Stop();
                if (updates != null) updates.Dispose();
                enrollmentCode.Text = ""; enrollmentCode.AccessibleName = "8자리 일회용 연결번호";
                if (server != null) { presentation.Clear(server.Identity); pin.Clear(); server.Dispose(); server = null; }
            };
            FormClosed += delegate
            {
                lifecycleTimer.Dispose();
                if (ownedIcon != null) { ownedIcon.Dispose(); ownedIcon = null; }
            };
            phase = addresses.Items.Count > 0 ? HostViewPhase.Idle : HostViewPhase.Failed;
            rawStatus = addresses.Items.Count > 0 ? "먼저 이 Windows에서 공유를 시작한 뒤, Mac에서 이 PC를 찾아 선택하세요." : "사용할 수 있는 사설 네트워크가 없어요. Wi-Fi나 Tailscale 연결을 확인해주세요.";
            UpdateNetwork(); ShowHelp(false); ApplyCurrentPresentation();
        }

        private int P(float value) { return (int)Math.Round(value * scale); }
        private void TraceFixture(string stage) { if (fixtureTrace != null) fixtureTrace(stage); }
        private PreviewButton ActionButton(string text, PreviewButtonKind kind)
        {
            PreviewButton button = new PreviewButton(text, kind, scale);
            SetOwnedFont(button, PreviewStyle.Type(kind == PreviewButtonKind.Navigation ? 10 : 10.5f, FontStyle.Bold, scale));
            return button;
        }
        private TableLayoutPanel Column()
        {
            TableLayoutPanel panel = new TableLayoutPanel { ColumnCount = 1, Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Margin = Padding.Empty, BackColor = Color.Transparent };
            panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); return panel;
        }
        private Label MakeLabel(string text, float size, FontStyle style)
        {
            Label label = new Label { Text = text, AutoSize = true, Dock = DockStyle.Top, UseMnemonic = false,
                ForeColor = style == FontStyle.Bold ? PreviewStyle.Ink : PreviewStyle.Muted, BackColor = Color.Transparent, Margin = Padding.Empty, MaximumSize = new Size(P(650), 0) };
            SetOwnedFont(label, PreviewStyle.Type(size, style, scale));
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
        private FlowLayoutPanel BuildCompactNavigation()
        {
            FlowLayoutPanel navigation = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = true, Margin = Padding.Empty };
            compactBrandMark = new KnotBrandMark(ownedIcon) { Width = P(24), Height = P(24), MinimumSize = new Size(P(24), P(24)), Margin = new Padding(0, P(4), P(8), 0) };
            navigation.Controls.Add(compactBrandMark);
            Label name = MakeLabel("Knot", 12, FontStyle.Bold); name.Dock = DockStyle.None; name.Margin = new Padding(0, P(5), P(16), 0); navigation.Controls.Add(name);
            foreach (PreviewButton button in new PreviewButton[] { compactDesktopNavigation, compactHelpNavigation })
            {
                SetOwnedFont(button, PreviewStyle.Type(9, FontStyle.Bold, scale));
                button.Padding = new Padding(P(8), P(5), P(8), P(5)); button.MinimumSize = new Size(0, P(32));
                button.Margin = new Padding(0, 0, P(6), 0); navigation.Controls.Add(button);
            }
            return navigation;
        }
        private Panel BuildFooter()
        {
            Panel footer = new Panel { Dock = DockStyle.Bottom, Height = P(88), Padding = new Padding(P(32), P(18), P(32), P(18)), BackColor = PreviewStyle.Canvas };
            footer.Paint += delegate(object sender, PaintEventArgs e) { using (Pen line = new Pen(PreviewStyle.Border)) e.Graphics.DrawLine(line, P(32), 0, footer.Width - P(32), 0); };
            TableLayoutPanel row = Column(); row.Dock = DockStyle.Fill; row.AutoSize = false; row.ColumnCount = 2; row.ColumnStyles.Clear();
            row.RowCount = 1; row.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            status.ReadOnly = true; status.Multiline = true; status.WordWrap = true; status.BorderStyle = BorderStyle.None;
            status.BackColor = PreviewStyle.Canvas; status.ForeColor = PreviewStyle.Muted; SetOwnedFont(status, PreviewStyle.Type(9.5f, FontStyle.Regular, scale));
            status.Dock = DockStyle.Fill; status.Margin = new Padding(0, P(3), P(18), 0); status.AccessibleName = "현재 공유 상태";
            stop.Margin = Padding.Empty; row.Controls.Add(status, 0, 0); row.Controls.Add(stop, 1, 0); footer.Controls.Add(row); return footer;
        }
        private TableLayoutPanel BuildHelp()
        {
            TableLayoutPanel help = Column(); help.Padding = new Padding(P(32), 0, P(32), P(20));
            PreviewCard steps = new PreviewCard(scale); steps.Dock = DockStyle.Top;
            Label title = MakeLabel("8자리 번호로 연결하기", 17, FontStyle.Bold); title.Margin = new Padding(0, 0, 0, P(20)); steps.Content.Controls.Add(title);
            AddHelpStep(steps.Content, "01  Windows에서 공유 시작", "이 Windows와 Mac에서 Knot Native Preview를 여세요. 이 PC의 ‘화면 공유 시작’을 누르면 8자리 번호가 표시돼요. 같은 Wi-Fi나 Tailscale에 연결되어 있어야 해요.");
            AddHelpStep(steps.Content, "02  Mac에서 PC 찾기 → 이 PC 선택", "Mac의 ‘주변 PC 찾기’를 누르고 Windows 공유 화면의 이름·주소와 비교해 이 PC를 선택하세요. PC를 선택해야 다음 번호 입력 화면이 나와요. Tailscale이나 검색이 안 되는 환경에서는 Mac의 ‘다른 연결 방법’에서 이 Windows의 연결 네트워크 주소로 찾으세요.");
            AddHelpStep(steps.Content, "03  Mac에서 8자리 번호 입력", "선택한 이 PC의 Knot 번호를 Mac에 입력하고 ‘이 PC에 연결’을 누르세요. 화면·입력과, 파일 공유를 켰다면 공유 폴더 및 직접 끌어온 탐색기 항목을 허용해요. Windows에서 추가 승인은 없어요. 번호는 2분·1회용이며 만료되면 다시 공유하세요.");
            AddHelpStep(steps.Content, "연결 중 파일·폴더 주고받기", "Mac의 ‘파일’에서 파일·폴더를 보내거나 받으세요. Finder 항목을 원격 화면에 놓으면 표시한 공유 폴더로 복사돼요. 탐색기 항목은 버튼을 누른 채 화면 밖 Finder로 끌어오고, Mac 쪽 아이콘이 나타난 뒤 놓으세요. 목록의 ‘받기’도 사용할 수 있어요. 최대 8GiB이며 원본과 기존 파일은 유지해요. 앱 패키지·링크·백그라운드 클립보드 동기화는 지원하지 않아요. 텍스트는 Mac의 ⌘C/V로 직접 옮겨요.");
            Label legacyHelp = MakeLabel("고급의 긴 연결코드 방식을 선택했다면 Mac에 코드를 붙여 넣은 뒤, Windows에서 연결 요청을 허용해주세요.", 9, FontStyle.Regular);
            legacyHelp.ForeColor = PreviewStyle.Muted; legacyHelp.Margin = Padding.Empty; steps.Content.Controls.Add(legacyHelp);
            PreviewButton returnToSharing = ActionButton("이 PC 공유로 돌아가기", PreviewButtonKind.Secondary);
            returnToSharing.Margin = new Padding(0, P(16), 0, 0);
            returnToSharing.Click += delegate { ShowHelp(false); }; steps.Content.Controls.Add(returnToSharing);
            help.Controls.Add(steps);
            PreviewCard scope = new PreviewCard(scale); scope.Dock = DockStyle.Top;
            Label scopeTitle = MakeLabel("이번 미리보기에서 알아둘 점", 12, FontStyle.Bold); scopeTitle.Margin = new Padding(0, 0, 0, P(10)); scope.Content.Controls.Add(scopeTitle);
            scope.Content.Controls.Add(MakeLabel("번호는 2분 동안 한 번만 사용할 수 있어요. Mac에서 내 PC로 등록하면 다음에는 번호 없이 연결할 수 있어요.\r\n\r\n로그인된 Windows 기본 SDR 가로 화면과 하드웨어 H.264 인코더가 필요해요.\r\n\r\n공유 전 ‘Windows 재생 소리 포함’을 켜면 Mac에서 소리를 들어요. 마이크는 제외해요. 무모니터·HDR·잠금/UAC 화면은 아직 지원하지 않아요. 자동 업데이트는 서명된 공개 배포 피드 구성 후 사용할 수 있어요.\r\n\r\n긴 연결코드 복사는 현재 클립보드를 바꾸고 Windows 기록·클라우드 제외를 요청해요. 다른 프로그램의 현재 클립보드 접근까지 막지는 않아요.\r\n\r\n중지는 입력 해제를 요청해요. Windows가 거부하면 제한된 재시도로 해제 성공을 보장할 수는 없어요.", 10, FontStyle.Regular));
            updateNotice = MakeLabel("서명된 업데이트 배포를 준비하고 있어요.", 10, FontStyle.Regular); scope.Content.Controls.Add(updateNotice);
            updateAction = ActionButton("업데이트 확인", PreviewButtonKind.Secondary);
            updateAction.Click += async delegate { if (updates == null) return; if (updates.Available) InstallUpdate(); else await updates.CheckAsync(); };
            scope.Content.Controls.Add(updateAction);
            PreviewButton manageDevices = ActionButton("등록한 Mac 관리", PreviewButtonKind.Secondary);
            manageDevices.Click += delegate { ManageRegisteredDevices(); }; scope.Content.Controls.Add(manageDevices);
            help.Controls.Add(scope); return help;
        }
        private void AddHelpStep(TableLayoutPanel parent, string title, string description)
        {
            Label heading = MakeLabel(title, 11, FontStyle.Bold); heading.Margin = new Padding(0, 0, 0, P(6)); parent.Controls.Add(heading);
            Label detail = MakeLabel(description, 10, FontStyle.Regular); detail.Margin = new Padding(0, 0, 0, P(20)); parent.Controls.Add(detail);
        }
        private void ShowHelp(bool show)
        {
            helpVisible = show; SetViewVisible(body, !show); SetViewVisible(helpBody, show);
            headerTitle.Text = show ? "처음 연결하기" : "Windows 화면 공유";
            headerSubtitle.Text = show ? "Windows에서 시작하고, Mac에서 선택한 뒤 번호를 입력해요." : "이 PC를 Mac에서 사용하기 · 계정 없이 3단계로 연결";
            desktopNavigation.Selected = !show; helpNavigation.Selected = show; desktopNavigation.Invalidate(); helpNavigation.Invalidate();
            compactDesktopNavigation.Selected = !show; compactHelpNavigation.Selected = show; compactDesktopNavigation.Invalidate(); compactHelpNavigation.Invalidate();
            desktopNavigation.AccessibleDescription = show ? "이 PC 공유 화면으로 이동" : "현재 선택한 화면";
            helpNavigation.AccessibleDescription = show ? "현재 선택한 화면" : "연결 안내 화면으로 이동";
            compactDesktopNavigation.AccessibleDescription = desktopNavigation.AccessibleDescription;
            compactHelpNavigation.AccessibleDescription = helpNavigation.AccessibleDescription;
            scroll.AutoScrollPosition = Point.Empty; ApplyResponsiveLayout(); UpdateWrapWidths();
        }
        private float CurrentLayoutScale { get { return fixtureMode ? scale : DeviceDpi / 96f; } }
        private int R(float value) { return (int)Math.Round(value * CurrentLayoutScale); }
        private void SetViewVisible(Control control, bool visible)
        {
            bool previous;
            if (localVisibility.TryGetValue(control, out previous) && previous == visible) return;
            localVisibility[control] = visible;
            control.Visible = visible;
        }
        private void SetOwnedFont(Control control, Font next)
        {
            // All callers supply a newly allocated font. WinForms may ignore a
            // value-equal assignment and retain the previous font instance.
            Font previous = control.Font;
            if (ReferenceEquals(previous, next)) return;
            if (previous.Equals(next)) { next.Dispose(); return; }
            Font owned;
            bool mayRetire = ownedFonts.TryGetValue(control, out owned) && ReferenceEquals(owned, previous) &&
                !previous.IsSystemFont && (control.Parent == null || !ReferenceEquals(previous, control.Parent.Font));
            control.Font = next;
            if (!ReferenceEquals(control.Font, next)) { next.Dispose(); return; }
            ownedFonts[control] = next;
            if (mayRetire) previous.Dispose();
        }
        private int StatusTextHeight(int width)
        {
            return TextRenderer.MeasureText(status.Text.Length == 0 ? " " : status.Text, status.Font,
                new Size(Math.Max(40, width), 32767), TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.NoPadding).Height;
        }
        private void ApplyResponsiveLayout()
        {
            if (responsiveLayout || shell == null || footer == null || body == null || helpBody == null || networkCard == null) return;
            responsiveLayout = true;
            try
            {
                TraceFixture("responsive-enter");
                HostViewSnapshot view = CurrentSnapshot();
                bool compact = ClientSize.Width / CurrentLayoutScale < 920 || ClientSize.Height / CurrentLayoutScale < 680;
                bool idle = view.Phase == HostViewPhase.Idle || view.Phase == HostViewPhase.Stopped || view.Phase == HostViewPhase.Failed;
                if (!densityApplied || compactMode != compact)
                {
                    SetOwnedFont(stateTitle, PreviewStyle.Type(compact ? 14 : 17, FontStyle.Bold, scale));
                    SetOwnedFont(requestName, PreviewStyle.Type(compact ? 9.5f : 13, FontStyle.Bold, scale));
                    SetOwnedFont(requestAddress, PreviewStyle.Type(compact ? 9.5f : 10.5f, FontStyle.Regular, scale));
                    SetOwnedFont(trustTitle, PreviewStyle.Type(compact ? 8.5f : 9, FontStyle.Bold, scale));
                    SetOwnedFont(enrollmentCode, new Font("Consolas", (compact ? 22 : 30) * scale, FontStyle.Bold));
                    SetOwnedFont(stop, PreviewStyle.Type(compact ? 9.5f : 10.5f, FontStyle.Bold, scale));
                    SetOwnedFont(pin, new Font("Consolas", (compact ? 9 : 10) * scale));
                    foreach (PreviewButton action in new PreviewButton[] { share, copy, approve, decline })
                    {
                        SetOwnedFont(action, PreviewStyle.Type(compact ? 9.5f : 10.5f, FontStyle.Bold, scale));
                        action.MinimumSize = new Size(0, R(compact ? 36 : 44));
                        action.Padding = compact ? new Padding(R(12), R(8), R(12), R(8)) : new Padding(R(18), R(10), R(18), R(10));
                    }
                    densityApplied = true;
                }
                compactMode = compact;
                enrollmentCode.Height = R(compact ? 46 : 60);
                SetViewVisible(rail, !compact); shell.ColumnStyles[0].Width = compact ? 0 : R(204);
                SetViewVisible(compactNavigation, compact); SetViewVisible(headerTitle, !compact); SetViewVisible(headerSubtitle, !compact);
                header.Padding = compact ? new Padding(R(16), R(8), R(16), R(6)) : new Padding(R(32), R(28), R(32), R(20));
                badge.Margin = new Padding(0, R(compact ? 4 : 12), 0, 0);
                body.Padding = helpBody.Padding = new Padding(R(compact ? 16 : 32), 0, R(compact ? 16 : 32), R(compact ? 12 : 20));
                taskCard.Padding = networkCard.Padding = qualityCard.Padding = filesCard.Padding = new Padding(R(compact ? 12 : 24));
                taskCard.Margin = networkCard.Margin = qualityCard.Margin = filesCard.Margin = new Padding(0, 0, 0, R(compact ? 12 : 16));
                foreach (Control control in helpBody.Controls)
                {
                    PreviewCard card = control as PreviewCard;
                    if (card != null) { card.Padding = new Padding(R(compact ? 12 : 24)); card.Margin = new Padding(0, 0, 0, R(compact ? 12 : 16)); }
                }
                SetViewVisible(illustration, idle && !compact); SetViewVisible(stateStep, !compact);
                SetViewVisible(stateTitle, !compact || idle);
                SetViewVisible(stateDescription, !compact || idle || view.Phase == HostViewPhase.Invitation);
                stateTitle.Margin = new Padding(0, 0, 0, R(compact ? 8 : 10));
                stateDescription.Margin = new Padding(0, 0, 0, R(compact ? 12 : 20));
                hostIdentity.Margin = new Padding(0, 0, 0, R(compact ? 8 : 12));
                numberLifetime.Margin = new Padding(0, 0, 0, R(compact ? 8 : 12));
                requestName.Margin = new Padding(0, 0, 0, R(4)); requestAddress.Margin = new Padding(0, 0, 0, R(6));
                SetViewVisible(requestWarning, view.Phase == HostViewPhase.Request && !compact);
                trustPanel.Margin = new Padding(0, 0, 0, R(compact ? 8 : 18));
                SetViewVisible(networkCard, !compact || !view.RunPresent);
                SetViewVisible(privacy, !compact || idle);
                stop.MinimumSize = new Size(0, R(compact ? 36 : 44));
                stop.Padding = compact ? new Padding(R(12), R(8), R(12), R(8)) : new Padding(R(18), R(10), R(18), R(10));
                footer.Padding = compact ? new Padding(R(16), R(10), R(16), R(10)) : new Padding(R(32), R(18), R(32), R(18));
                status.Margin = new Padding(0, R(2), R(compact ? 12 : 18), 0);
                TraceFixture("responsive-before-shell"); shell.PerformLayout(); TraceFixture("responsive-after-shell");
                header.PerformLayout(); TraceFixture("responsive-after-header"); UpdateWrapWidths(); TraceFixture("responsive-after-wrap");
                if (!helpVisible) trustPanel.SetMetrics(R(compact ? 4 : 8), R(24), R(8));
                TraceFixture("responsive-after-trust");
                Size stopSize = view.RunPresent ? stop.GetPreferredSize(Size.Empty) : Size.Empty;
                int statusWidth = main.ClientSize.Width - footer.Padding.Horizontal - stopSize.Width - status.Margin.Horizontal;
                int contentHeight = Math.Max(stopSize.Height, StatusTextHeight(statusWidth) + status.Margin.Vertical + R(4));
                int footerHeight = Math.Max(R(compact ? 64 : 88), contentHeight + footer.Padding.Vertical);
                if (footer.Height != footerHeight) footer.Height = footerHeight;
                footer.PerformLayout();
                TraceFixture("responsive-after-footer");
                // Footer and scrollbar changes may alter available label width.
                // Reconcile once from this explicit input transaction; child
                // SizeChanged events never schedule another full transaction.
                UpdateWrapWidths();
                TraceFixture("responsive-exit");
            }
            finally { responsiveLayout = false; }
        }
        private void UpdateWrapWidths()
        {
            if (settingWrapWidths) return;
            settingWrapWidths = true;
            HashSet<Control> parents = new HashSet<Control>();
            try
            {
                foreach (Label label in wrappingLabels)
                    if (label.Parent != null && label.Visible && parents.Add(label.Parent)) label.Parent.SuspendLayout();
                foreach (Label label in wrappingLabels)
                {
                    if (label.Parent == null || !label.Visible) continue;
                    int width = Math.Max(P(80), label.Parent.ClientSize.Width - label.Parent.Padding.Horizontal - label.Margin.Horizontal);
                    if (label.MaximumSize.Width != width) label.MaximumSize = new Size(width, 0);
                }
            }
            finally
            {
                foreach (Control parent in parents) parent.ResumeLayout(true);
                settingWrapWidths = false;
            }
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
                approval == null ? "" : approval.ClaimedViewerLabel, approval == null ? "" : approval.ObservedRemoteIPv4,
                PreviewCopy.Status(rawStatus), invitationAvailable, server == null ? !legacyMode.Checked : server.UsesEnrollment);
        }
        private void ApplyCurrentPresentation() { ApplyPresentation(CurrentSnapshot()); }
        private void ApplyPresentation(HostViewSnapshot view)
        {
            bool idle = view.Phase == HostViewPhase.Idle || view.Phase == HostViewPhase.Stopped || view.Phase == HostViewPhase.Failed;
            privacy.Text = PreviewCopy.Privacy(view.EnrollmentMode, allowFiles.Checked);
            if (allowAudio.Checked) privacy.Text += " Windows 재생 소리도 포함해요. 마이크는 공유하지 않아요.";
            badge.Text = "●  " + PreviewCopy.Phase(view.Phase);
            badge.ForeColor = view.Phase == HostViewPhase.Failed ? PreviewStyle.Warning : PreviewStyle.Muted;
            stateStep.Text = view.Phase == HostViewPhase.Failed ? "공유 준비 확인" : idle ? "01  화면 공유" : view.Phase == HostViewPhase.Invitation ? "02  Mac에 코드 보내기" : "03  연결 확인";
            stateTitle.Text = view.Phase == HostViewPhase.Failed ? "공유 준비를 확인해주세요" : view.Phase == HostViewPhase.Stopped ? "새 코드로 다시 연결하세요" : idle ? "Mac에서 이 화면을 사용하세요" : view.Phase == HostViewPhase.Invitation ? "연결 코드를 Mac에 보내세요" : view.Phase == HostViewPhase.Request ? "이 Mac의 연결을 허용할까요?" : view.Phase == HostViewPhase.Sharing ? "Windows 화면을 전송하고 있어요" : view.Phase == HostViewPhase.Stopping ? "화면 공유를 마치고 있어요" : "Windows 화면을 준비하고 있어요";
            stateDescription.Text = view.Phase == HostViewPhase.Failed ? view.Status : view.Phase == HostViewPhase.Stopped ? "이전 연결의 권한은 끝났어요.\r\n공유를 시작하면 새 연결 코드가 만들어져요." : idle ? "공유를 시작하면 연결 코드가 만들어져요.\r\nMac에서 코드를 확인한 뒤 이 PC에서 연결을 허용해주세요." : view.Phase == HostViewPhase.Invitation ? "Mac의 Knot Native Preview에 붙여 넣으세요.\r\n연결 코드는 2분 동안 한 번만 사용할 수 있어요." : view.Phase == HostViewPhase.Request ? "직접 연결을 요청한 Mac인지 이름과 주소를 확인해주세요." : view.Phase == HostViewPhase.Sharing ? "이 PC의 화면과 입력이 공유 중이에요.\r\n등록한 Mac은 저장한 PC로 다시 연결할 수 있어요." : view.Phase == HostViewPhase.Stopping ? "이번 연결의 권한을 종료하고 있어요. 정리가 끝나면 새 코드를 만들 수 있어요." : "연결은 허용됐어요. 인코더와 전송 준비가 끝날 때까지 잠시 기다려주세요.";
            if (view.EnrollmentMode)
            {
                if (idle)
                {
                    stateStep.Text = "1 / 3  Windows에서 공유 시작";
                    stateTitle.Text = view.Phase == HostViewPhase.Failed ? "공유 준비를 확인해주세요" : view.Phase == HostViewPhase.Stopped ? "새 번호로 다시 연결하세요" : PreviewCopy.ShareTitle;
                    if (view.Phase != HostViewPhase.Failed) stateDescription.Text = PreviewCopy.Onboarding;
                }
                else if (view.Phase == HostViewPhase.Invitation)
                {
                    stateStep.Text = "2 → 3 / 3  Mac에서 PC 선택 → 번호 입력";
                    stateTitle.Text = PreviewCopy.NumberTitle;
                    stateDescription.Text = PreviewCopy.NumberInstruction;
                }
            }
            if (view.Phase == HostViewPhase.RegisteredWaiting)
            {
                stateStep.Text = "등록된 Mac 연결 대기";
                stateTitle.Text = "등록된 Mac의 재연결을 기다려요";
                stateDescription.Text = "일회용 번호는 끝났지만 등록한 Mac은 ‘내 PC’에서 연결할 수 있어요. 새 Mac을 등록하려면 공유를 중지한 뒤 다시 시작해주세요.";
            }
            SetViewVisible(requestPanel, view.ViewerLabel.Length > 0 && (view.Phase == HostViewPhase.Request || view.Phase == HostViewPhase.Preparing || view.Phase == HostViewPhase.Sharing));
            requestName.Text = view.ViewerLabel + "  ·  확인되지 않은 이름";
            requestAddress.Text = "연결 주소  " + view.ObservedAddress;
            SetViewVisible(trustPanel, view.Pin.Length != 0 && (!view.EnrollmentMode || networkExpanded));
            if (pin.Text != view.Pin) pin.Text = view.Pin;
            string code = view.EnrollmentMode && view.Phase == HostViewPhase.Invitation ? (fixtureMode ? fixtureCode : server == null ? "" : server.EnrollmentCode) : "";
            enrollmentCode.Text = code.Length == 8 ? code.Substring(0, 4) + " " + code.Substring(4) : "";
            enrollmentCode.AccessibleName = code.Length == 8 ? "연결번호 " + string.Join(" ", Array.ConvertAll<char, string>(code.ToCharArray(), delegate(char c) { return c.ToString(); })) : "8자리 일회용 연결번호";
            SetViewVisible(enrollmentCode, view.EnrollmentMode && view.Phase == HostViewPhase.Invitation);
            bool numberReady = view.EnrollmentMode && view.Phase == HostViewPhase.Invitation;
            AdapterChoice selected = addresses.SelectedItem as AdapterChoice;
            hostIdentity.Text = advertisedName + "\r\n" + (selected == null ? "연결 주소 없음" : selected.Address.ToString());
            SetViewVisible(hostIdentity, numberReady); SetViewVisible(numberLifetime, numberReady);
            SetViewVisible(share, idle); share.Enabled = idle && view.HasAddress && !view.RunPresent;
            bool certificateConversion = idle && !view.RunPresent && !legacyMode.Checked && certificateCompatibilityRequired;
            bool certificateRenewal = idle && !view.RunPresent && !legacyMode.Checked && certificateRenewalRequired;
            share.Text = certificateRenewal ? PreviewCopy.CertificateRenewalAction : certificateConversion ? PreviewCopy.CertificateConversionAction : "화면 공유 시작";
            if (certificateRenewal) {
                stateTitle.Text = PreviewCopy.CertificateRenewalTitle;
                stateDescription.Text = PreviewCopy.CertificateRenewalDisclosure;
            }
            else if (certificateConversion) {
                stateTitle.Text = PreviewCopy.CertificateConversionTitle;
                stateDescription.Text = PreviewCopy.CertificateConversionDisclosure;
            }
            SetViewVisible(copy, !view.EnrollmentMode && view.Phase == HostViewPhase.Invitation); copy.Enabled = !view.EnrollmentMode && view.Phase == HostViewPhase.Invitation && view.CanCopy && view.RunPresent;
            SetViewVisible(approve, !view.EnrollmentMode && view.Phase == HostViewPhase.Request); SetViewVisible(decline, !view.EnrollmentMode && view.Phase == HostViewPhase.Request);
            approve.Enabled = decline.Enabled = !view.EnrollmentMode && view.Phase == HostViewPhase.Request && view.RunPresent;
            SetViewVisible(stop, view.RunPresent); stop.Enabled = view.RunPresent && view.Phase != HostViewPhase.Stopping;
            addresses.Enabled = legacyMode.Enabled = !view.RunPresent; networkDisclosure.Enabled = true;
            qualityProfiles.Enabled = !view.RunPresent;
            SetViewVisible(qualityCard, idle && !view.RunPresent);
            shareScope.Text = allowFiles.Checked ? "화면·입력 + 공유 폴더 ‘" + fileRootName + "’ + 직접 끌어온 탐색기 항목" : "허용 범위: 화면과 입력 · 파일 공유 꺼짐";
            if (allowAudio.Checked) shareScope.Text += " · Windows 재생 소리 (마이크 제외)";
            SetViewVisible(shareScope, idle);
            allowFiles.Enabled = chooseFileFolder.Enabled = !view.RunPresent;
            allowAudio.Enabled = !view.RunPresent;
            chooseFileFolder.Visible = !view.RunPresent;
            openFileFolder.Visible = view.RunPresent && view.Phase == HostViewPhase.Sharing && allowFiles.Checked;
            openFileFolder.Enabled = rawFileStatus.Length == 0;
            fileFolderValue.Text = allowFiles.Checked ? fileRootPath : "파일 공유 꺼짐 · 화면과 입력만 허용해요";
            fileFolderHint.Text = rawFileStatus.Length != 0 ? rawFileStatus : view.Phase == HostViewPhase.Sharing ?
                "Mac의 ‘파일’에서 파일·폴더를 주고받으세요. 탐색기에서 선택한 항목을 화면 밖 Finder로 직접 끌어올 수도 있어요." :
                "Mac에서 보낸 파일·폴더는 여기에 복사돼요. 이 폴더 목록과 직접 끌어온 탐색기 항목만 Mac에 제공해요.";
            fileFolderHint.ForeColor = rawFileStatus.Length == 0 ? PreviewStyle.Muted : PreviewStyle.Warning;
            SetViewVisible(filesCard, idle || view.Phase == HostViewPhase.Sharing);
            if (status.Text != view.Status) status.Text = view.Status;
            ApplyResponsiveLayout(); UpdateWrapWidths();
        }
        internal void SetFixturePresentation(HostViewSnapshot snapshot, bool showHelp)
        {
            if (!fixtureMode) throw new InvalidOperationException("Synthetic presentation is unavailable in the production form.");
            fixture = snapshot; ShowHelp(showHelp); ApplyCurrentPresentation();
        }
        internal bool FixtureMode { get { return fixtureMode; } }
        internal void SetFixtureAudioConsent(bool allowed)
        {
            if (!fixtureMode) throw new InvalidOperationException("Synthetic audio consent requires the inert fixture.");
            allowAudio.Checked = allowed; ApplyCurrentPresentation();
        }
        internal bool FixtureAudioConsentMatches(bool allowed, bool runPresent)
        { return fixtureMode && allowAudio.Checked == allowed && allowAudio.Enabled == !runPresent; }
        internal bool FixtureAudioStartConsent(bool ownerInitiated)
        {
            if (!fixtureMode) throw new InvalidOperationException("Synthetic consent requires the inert fixture.");
            return PrepareAudioForStart(ownerInitiated);
        }
        internal bool FixtureAudioConsentFits { get { return !allowAudio.Visible || scroll.ClientRectangle.Contains(BoundsWithin(allowAudio, scroll)); } }
        internal void SetFixtureCertificateCompatibility(bool required)
        {
            if (!fixtureMode) throw new InvalidOperationException("Synthetic compatibility state requires the inert fixture.");
            certificateCompatibilityRequired = required; ApplyCurrentPresentation();
        }
        internal void SetFixtureEnrollmentCode(string code)
        {
            if (!fixtureMode || code == null || code.Length != 8) throw new InvalidOperationException("Synthetic code requires the inert fixture.");
            foreach (char c in code) if (c < '0' || c > '9') throw new InvalidOperationException("Invalid synthetic code.");
            fixtureCode = code;
        }
        internal string DisplayedEnrollmentCode { get { return enrollmentCode.Text; } }
        internal string DisplayedHostIdentity { get { return hostIdentity.Text; } }
        internal bool FixtureNumberGuidanceVisible { get { return hostIdentity.Visible && numberLifetime.Visible && stateDescription.Text == PreviewCopy.NumberInstruction; } }
        internal bool FixtureOnboardingVisible { get { return stateDescription.Visible && stateDescription.Text == PreviewCopy.Onboarding; } }
        internal bool FixtureFileFolderVisible { get { return filesCard.Visible && fileFolderValue.Visible && allowFiles.Checked; } }
        internal string DisplayedFileFolder { get { return fileFolderValue.Text; } }
        internal bool FixtureFileServiceUnavailable { get { return rawFileStatus.Length != 0 && fileFolderHint.Text == rawFileStatus && !openFileFolder.Enabled; } }
        internal void SetFixtureFileStatus(string value)
        {
            if (!fixtureMode) throw new InvalidOperationException("Synthetic file status is unavailable in the production form.");
            rawFileStatus = value ?? ""; ApplyCurrentPresentation();
        }
        internal bool FixtureOnboardingActionFits { get { return (!share.Visible || scroll.ClientRectangle.Contains(BoundsWithin(share, scroll))) && (!shareScope.Visible || scroll.ClientRectangle.Contains(BoundsWithin(shareScope, scroll))); } }
        internal bool FixtureCertificateConversionVisible { get { return !helpVisible && certificateCompatibilityRequired && share.Visible && share.Enabled &&
            share.Text == PreviewCopy.CertificateConversionAction && stateTitle.Text == PreviewCopy.CertificateConversionTitle &&
            stateDescription.Text == PreviewCopy.CertificateConversionDisclosure; } }
        internal string DisplayedStatus { get { return status.Text; } }
        internal bool HelpVisible { get { return helpVisible; } }
        internal string DisplayedPin { get { return pin.Text; } }
        internal bool ApprovalVisible { get { return approve.Visible; } }
        internal bool StopVisible { get { return stop.Visible; } }
        internal bool ShareVisible { get { return share.Visible; } }
        internal bool ShareEnabled { get { return share.Visible && share.Enabled; } }
        internal bool CopyVisible { get { return copy.Visible; } }
        internal bool CopyEnabled { get { return copy.Visible && copy.Enabled; } }
        internal bool ApprovalEnabled { get { return approve.Visible && approve.Enabled && decline.Visible && decline.Enabled; } }
        internal bool FixtureBrandPainted { get { return brandMark != null && brandMark.Visible && brandMark.DrawCalls > 0 || compactBrandMark != null && compactBrandMark.Visible && compactBrandMark.DrawCalls > 0; } }
        internal bool FixtureCompactMode { get { return compactMode; } }
        internal bool FixtureQualityEditable { get { return qualityProfiles.Enabled; } }
        internal MediaQualityProfile SelectedQuality { get { return qualityProfiles.SelectedItem as MediaQualityProfile ?? MediaQualityProfile.Sharp4K; } }
        internal float FixtureLogicalWidth { get { return ClientSize.Width / CurrentLayoutScale; } }
        private static Rectangle BoundsWithin(Control child, Control ancestor)
        {
            Point point = Point.Empty;
            for (Control cursor = child; cursor != ancestor; cursor = cursor.Parent)
            {
                if (cursor == null) throw new InvalidOperationException("Control does not belong to the fixture ancestor.");
                point.Offset(cursor.Left, cursor.Top);
            }
            return new Rectangle(point, child.Size);
        }
        internal bool FixtureFooterFits
        {
            get { return ClientRectangle.Contains(BoundsWithin(footer, this)) && footer.ClientRectangle.Contains(BoundsWithin(status, footer)) && status.ClientSize.Height >= StatusTextHeight(status.ClientSize.Width) && (!stop.Visible || footer.ClientRectangle.Contains(BoundsWithin(stop, footer))); }
        }
        internal bool FixtureConsentFits
        {
            get
            {
                return trustPanel.Visible && pin.ClientSize.Height >= trustPanel.RequiredPinHeight &&
                    scroll.ClientRectangle.Contains(BoundsWithin(pin, scroll)) && scroll.ClientRectangle.Contains(BoundsWithin(requestName, scroll)) &&
                    scroll.ClientRectangle.Contains(BoundsWithin(requestAddress, scroll)) && scroll.ClientRectangle.Contains(BoundsWithin(approve, scroll)) &&
                    scroll.ClientRectangle.Contains(BoundsWithin(decline, scroll));
            }
        }
        internal bool FixtureEnrollmentCodeFits
        {
            get { return !enrollmentCode.Visible || scroll.ClientRectangle.Contains(BoundsWithin(enrollmentCode, scroll)) && enrollmentCode.ClientSize.Height >= enrollmentCode.Font.GetHeight(96f) && scroll.ClientRectangle.Contains(BoundsWithin(hostIdentity, scroll)) && scroll.ClientRectangle.Contains(BoundsWithin(numberLifetime, scroll)); }
        }
        internal void PrepareFixtureLayout()
        {
            if (!fixtureMode) throw new InvalidOperationException("Synthetic layout preparation is unavailable in production.");
            ApplyResponsiveLayout(); PerformLayout(); UpdateWrapWidths();
        }
        internal string FixtureLayoutDiagnostic
        {
            get { return "client=" + ClientSize + ",compact=" + compactMode + ",header=" + header.Bounds + ",footer=" + footer.Bounds + ",status=" + status.Bounds + ",statusTextHeight=" + StatusTextHeight(status.ClientSize.Width) + ",scroll=" + scroll.ClientRectangle + ",name=" + BoundsWithin(requestName, scroll) + ",pin=" + BoundsWithin(pin, scroll) + ",approve=" + BoundsWithin(approve, scroll) + ",decline=" + BoundsWithin(decline, scroll); }
        }

        private void BindActions()
        {
            share.Click += delegate { StartShareFromButton(); };
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
            chooseFileFolder.Click += delegate
            {
                if (server != null) return;
                using (FolderBrowserDialog picker = new FolderBrowserDialog())
                {
                    picker.Description = "이 폴더의 파일·폴더를 Mac과 주고받아요. 공유 중에는 변경할 수 없어요.";
                    if (System.IO.Directory.Exists(fileRootPath)) picker.SelectedPath = fileRootPath;
                    if (picker.ShowDialog(this) != DialogResult.OK || server != null) return;
                    try
                    {
                        FileSharingOptions options = new FileSharingOptions(picker.SelectedPath);
                        fileRootPath = options.RootPath; fileRootName = options.RootName; ApplyCurrentPresentation();
                    }
                    catch (Exception) { rawStatus = "이 폴더를 공유하도록 준비하지 못했어요. 다른 폴더를 선택해주세요."; ApplyCurrentPresentation(); }
                }
            };
            openFileFolder.Click += delegate
            {
                if (server == null || !server.IsActive || !allowFiles.Checked) return;
                try
                {
                    string explorer = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo { FileName = explorer, Arguments = "\"" + fileRootPath + "\"", UseShellExecute = false });
                }
                catch (Exception) { rawStatus = "공유 폴더를 열지 못했어요. 표시한 경로를 탐색기에서 확인해주세요."; ApplyCurrentPresentation(); }
            };
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
        // The direct primary button is the only migration authorization path.
        // Resume/retry call StartShare directly and can never rotate identity.
        private void StartShareFromButton()
        {
            if (closing || server != null) return;
            if (certificateRenewalRequired && !legacyMode.Checked) {
                try {
                    RunCertificate.RenewExpiredPersistent();
                    certificateRenewalRequired = false; certificateCompatibilityRequired = false;
                }
                catch {
                    FailShareStart("만료 인증서 갱신을 완료하지 못해 공유를 시작하지 않았어요. 등록 초기화가 진행됐을 수 있으므로, 갱신 후 Mac에서 이전 PC를 지우고 새 번호로 다시 등록해주세요.");
                    return;
                }
            }
            else if (certificateCompatibilityRequired && !legacyMode.Checked) {
                try {
                    RunCertificate.ConvertPersistentForCompatibility();
                    certificateCompatibilityRequired = false;
                }
                catch (CertificateRenewalRequiredException) {
                    certificateCompatibilityRequired = false; certificateRenewalRequired = true;
                    FailShareStart("저장된 공유 인증서가 만료됐어요. 갱신 안내를 확인한 뒤 ‘만료 인증서 갱신하고 공유’를 눌러주세요. 아직 인증서와 등록 기기는 변경하지 않았어요.");
                    return;
                }
                catch {
                    FailShareStart("인증서 전환을 완료하지 못해 공유를 시작하지 않았어요. 등록 초기화가 진행됐을 수 있으므로, 전환 후 새 번호로 다시 등록해주세요.");
                    return;
                }
            }
            StartShare(true);
        }
        private bool PrepareAudioForStart(bool ownerInitiated)
        {
            // A fresh automatic host is a new run. Old registration/resume
            // authority never opts the owner into playback capture.
            if (!ownerInitiated) allowAudio.Checked = false;
            return allowAudio.Checked;
        }
        private void StartShare(bool ownerInitiated = false)
        {
            AdapterChoice selected = addresses.SelectedItem as AdapterChoice;
            if (server != null || selected == null) return;
            bool audioAllowed = PrepareAudioForStart(ownerInitiated);
            shareRequested = true;
            try
            {
                HostServer run = new HostServer(selected.Address, 48631, new WindowsMediaFactory(SelectedQuality), new WindowsInputSink(), false, null,
                    !legacyMode.Checked, System.Diagnostics.Stopwatch.GetTimestamp, advertisedName,
                    files: allowFiles.Checked ? new FileSharingOptions(fileRootPath) : null,
                    allowAudio: audioAllowed);
                server = run; rawFileStatus = ""; presentation.Bind(run.Identity); phase = HostViewPhase.Invitation; invitationAvailable = true;
                run.AudioStatusChanged = delegate(string message)
                {
                    OnUi(delegate
                    {
                        if (server != run || !presentation.IsCurrent(run.Identity)) return;
                        rawStatus = message; ApplyCurrentPresentation();
                    });
                };
                run.FileStatusChanged = delegate(string text)
                {
                    OnUi(delegate
                    {
                        if (server != run || !presentation.IsCurrent(run.Identity)) return;
                        // Only the authored file-service notice is displayed here;
                        // media state/status remains owned by the media callbacks.
                        rawFileStatus = "파일 공유 폴더를 준비하지 못했어요. 화면 연결은 계속 사용할 수 있어요.";
                        ApplyCurrentPresentation();
                    });
                };
                run.StatusChanged = delegate(string text)
                {
                    OnUi(delegate
                    {
                        if (server != run || !presentation.IsCurrent(run.Identity)) return;
                        rawStatus = text;
                        if (run.IsActive) phase = HostViewPhase.Sharing;
                        else if (run.WaitingForRegisteredDevice) phase = HostViewPhase.RegisteredWaiting;
                        else if (run.EnrollmentReady && (phase == HostViewPhase.Invitation || phase == HostViewPhase.RegisteredWaiting)) phase = HostViewPhase.Preparing;
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
                run.ClaimAccepted = delegate(ApprovalMetadata metadata)
                {
                    if (!run.UsesEnrollment) return;
                    OnUi(delegate
                    {
                        if (server != run || !presentation.PublishApproval(run.Identity, metadata)) return;
                        invitationAvailable = false; phase = HostViewPhase.Preparing; ShowHelp(false); ApplyCurrentPresentation();
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
                        RegisteredConnectionResume.TryResume(shareRequested, closing, run.MayResumeRegisteredConnection, delegate { StartShare(); });
                    });
                };
                rawStatus = run.UsesEnrollment ? EnrollmentGuidance.Ready : "Mac에서 연결 코드를 입력한 뒤, 이 PC에서 요청을 허용해주세요.";
                ShowHelp(false); ApplyCurrentPresentation(); lifecycleTimer.Start(); run.Start();
            }
            catch (CertificateRenewalRequiredException)
            {
                certificateRenewalRequired = true;
                FailShareStart("저장된 공유 인증서가 만료됐어요. ‘만료 인증서 갱신하고 공유’를 누르면 이전 Mac 등록을 해제하고 새 인증서를 만들어요. Mac에서도 이전 PC를 지우고 새 번호로 등록해주세요.");
            }
            catch (CertificateCompatibilityException)
            {
                certificateCompatibilityRequired = true;
                FailShareStart("기존 인증서의 키 또는 유효기간이 Mac 보안 기준에 맞지 않아요. ‘호환 인증서로 전환하고 공유’를 눌러 새 번호로 연결하세요.");
            }
            catch (System.Security.Cryptography.CryptographicException)
            {
                FailShareStart("저장된 공유 인증서를 확인하지 못했어요. 인증서를 자동으로 교체하지 않습니다. Windows 사용자 계정과 인증서 저장소 접근을 확인해주세요.");
            }
            catch (PairingSetupException)
            {
                FailShareStart(EnrollmentGuidance.For(EnrollmentFailure.Setup));
            }
            catch (Exception)
            {
                FailShareStart("화면 공유를 시작하지 못했어요. 선택한 네트워크와 TCP 48631·48632, UDP 48633의 연결 허용 여부를 확인해주세요.");
            }
        }
        private void FailShareStart(string guidance)
        {
            if (server != null) { presentation.Clear(server.Identity); server.Dispose(); server = null; }
            lifecycleTimer.Stop(); phase = HostViewPhase.Failed; invitationAvailable = false;
            rawStatus = guidance;
            ApplyCurrentPresentation();
        }
        private void Decide(bool allowed)
        {
            if (server == null || server.UsesEnrollment || !presentation.IsCurrent(server.Identity) || phase != HostViewPhase.Request) return;
            phase = allowed ? HostViewPhase.Preparing : HostViewPhase.Stopping;
            server.RespondToApproval(allowed);
            rawStatus = allowed ? "연결을 허용했어요. Windows 화면과 인코더를 준비하고 있어요." : "연결 요청을 거절했어요. 이번 연결 권한을 종료하고 있어요.";
            ApplyCurrentPresentation();
        }
        private void StopShare()
        {
            shareRequested = false;
            if (server != null) { presentation.Clear(server.Identity); server.Stop(); phase = HostViewPhase.Stopping; }
            invitationAvailable = false;
            rawStatus = "화면 공유를 중지했어요. 이번 연결의 입력 해제를 요청했어요.";
            ApplyCurrentPresentation();
        }
        private void UpdateUpdaterPresentation()
        {
            if (updates == null || closing) return;
            updateNotice.Text = updates.Status;
            updateAction.Text = updates.Available ? "업데이트하고 다시 열기" : "업데이트 확인";
            updateAction.Enabled = updates.Configured && !updates.Busy;
        }
        private async void InstallUpdate()
        {
            if (updates == null) return;
            await updates.InstallAsync(delegate {
                NativePreferences.ClearUpdateResume();
                AdapterChoice selected = addresses.SelectedItem as AdapterChoice;
                if (NativePreferences.ShouldRequestUpdateResume(shareRequested, server != null,
                    server != null && server.IsRegisteredSession, server != null && server.HasRegisteredDevices, selected != null))
                    NativePreferences.RequestUpdateResume(allowFiles.Checked, fileRootPath, selected.Address.ToString());
                StopShare();
                Close();
            });
        }
        private void ManageRegisteredDevices()
        {
            if (fixtureMode) return;
            try {
                var devices = NativeTrustedDevices.List();
                if (devices.Count == 0) { MessageBox.Show(this, "등록한 Mac이 없어요. Mac에서 ‘내 PC로 등록’을 선택하고 번호로 연결하세요.", "내 기기"); return; }
                using (Form dialog = new Form { Text = "등록한 Mac", Width = P(460), Height = P(330), StartPosition = FormStartPosition.CenterParent }) {
                    ListBox list = new ListBox { Dock = DockStyle.Fill }; List<string> ids = new List<string>();
                    foreach (var item in devices) { ids.Add(item.Key); list.Items.Add(item.Value); }
                    Button remove = new Button { Text = "선택한 Mac 등록 해제", Dock = DockStyle.Bottom, Height = P(40) };
                    remove.Click += delegate {
                        int selected = list.SelectedIndex; if (selected < 0) return;
                        // Owner intent revokes current capabilities even if the
                        // persistent deletion fails. Keep the row on failure.
                        bool hadRun = server != null;
                        shareRequested = false;
                        try { if (hadRun) StopShare(); NativeTrustedDevices.Revoke(ids[selected]); ids.RemoveAt(selected); list.Items.RemoveAt(selected); }
                        catch { MessageBox.Show(dialog, hadRun ? "공유를 중지했지만 등록 기기를 변경하지 못했어요. 저장소 접근을 확인하고 다시 시도해주세요." :
                            "등록 기기를 변경하지 못했어요. 저장소 접근을 확인하고 다시 시도해주세요.", "내 기기"); }
                    };
                    dialog.Controls.Add(list); dialog.Controls.Add(remove); dialog.ShowDialog(this);
                }
            } catch { MessageBox.Show(this, "등록 기기를 읽거나 변경하지 못했어요.", "내 기기"); }
        }
    }
}
