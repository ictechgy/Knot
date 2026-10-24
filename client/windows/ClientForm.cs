// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace DeskBridge.Reverse
{
    internal sealed class ClientForm : Form
    {
        private readonly EngineStore store;
        private readonly HostPlatform platform;
        private readonly StatusTextBox status = new StatusTextBox();
        private readonly TextBox link = new TextBox();
        private readonly TextBox manual = new TextBox();
        private readonly ComboBox candidates = new ComboBox();
        private readonly ComboBox resolution = new ComboBox();
        private readonly ComboBox fps = new ComboBox();
        private readonly ComboBox bitrate = new ComboBox();
        private readonly CheckBox fullscreen = new CheckBox();
        private readonly CheckBox macCommandKeys = new CheckBox();
        private readonly CheckBox advanced = new CheckBox();
        private readonly FlowLayoutPanel manualPanel = new FlowLayoutPanel();
        private readonly Label target = new Label();
        private readonly Button install = new Button(), pair = new Button(), connect = new Button(), cancel = new Button();
        private readonly ProgressBar progress = new ProgressBar();
        private readonly List<Control> changing = new List<Control>();
        private readonly List<Label> wrapping = new List<Label>();
        private readonly TableLayoutPanel content = new TableLayoutPanel();
        private CancellationTokenSource operation;
        private EngineProcess ownedProcess;
        private string selectedAddress;
        private long selectionGeneration;
        private bool busy, closing, allowClose, qrReading;

        internal ClientForm(HostPlatform platform = HostPlatform.Mac)
        {
            this.platform = platform;
            Text = HostText(ClientMessage.Title);
            var applicationIcon = System.Drawing.Icon.ExtractAssociatedIcon(System.Reflection.Assembly.GetExecutingAssembly().Location);
            Icon = applicationIcon;
            Disposed += delegate { if (applicationIcon != null) applicationIcon.Dispose(); };
            Font = new Font("Malgun Gothic", 9.5f);
            AutoScaleMode = AutoScaleMode.Dpi; AutoScaleDimensions = new SizeF(96, 96);
            StartPosition = FormStartPosition.CenterScreen;
            Size = new Size(1000, 790); MinimumSize = new Size(720, 540);
            BackColor = SystemColors.Control; ForeColor = SystemColors.ControlText;
            store = new EngineStore();
            Build();
            SetStatus(HostText(ClientMessage.Initial));
            Shown += delegate
            {
                Rectangle area = Screen.FromControl(this).WorkingArea;
                MinimumSize = new Size(Math.Min(MinimumSize.Width, area.Width), Math.Min(MinimumSize.Height, area.Height));
                Size = new Size(Math.Min(Width, area.Width), Math.Min(Height, area.Height));
                Location = new Point(Math.Max(area.Left, Math.Min(Left, area.Right - Width)), Math.Max(area.Top, Math.Min(Top, area.Bottom - Height)));
                UpdateWrapping();
            };
            FormClosing += OnClosing;
            UpdateControls();
        }

        private string HostText(ClientMessage message)
        { return ReverseClientText.Get(message, platform); }

        private void Build()
        {
            var footer = new Panel { Dock = DockStyle.Bottom, Height = 118, Padding = new Padding(20, 10, 20, 14), BackColor = SystemColors.Control, ForeColor = SystemColors.ControlText };
            cancel.Text = "작업 취소"; cancel.AutoSize = true; cancel.Dock = DockStyle.Right; cancel.MinimumSize = new Size(110, 0);
            cancel.Click += delegate { CancelOwned(); };
            status.ReadOnly = true; status.Multiline = true; status.ScrollBars = ScrollBars.Vertical; status.Dock = DockStyle.Fill;
            status.BorderStyle = BorderStyle.None; status.BackColor = SystemColors.Window; status.ForeColor = SystemColors.WindowText; status.AccessibleName = "현재 작업 상태";
            status.AccessibleDescription = "현재 작업 상태와 다음 단계 안내입니다. 내용을 선택해 복사할 수 있습니다.";
            footer.Controls.Add(status); footer.Controls.Add(cancel); Controls.Add(footer);
            var sidebar = new Panel { Dock = DockStyle.Left, Width = 168, BackColor = SystemColors.Control, ForeColor = SystemColors.ControlText, Padding = new Padding(20, 26, 12, 0) };
            sidebar.Controls.Add(new Label { Dock = DockStyle.Top, AutoSize = true, Text = HostText(ClientMessage.Sidebar), Font = new Font(Font, FontStyle.Bold) });
            Controls.Add(sidebar);
            var scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true, Padding = new Padding(24) };
            content.ColumnCount = 1; content.RowCount = 0; content.AutoSize = true; content.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            content.Dock = DockStyle.Top; content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            scroll.Controls.Add(content); Controls.Add(scroll); scroll.BringToFront();
            scroll.ClientSizeChanged += delegate { UpdateWrapping(); };
            Add(Heading(HostText(ClientMessage.Heading)));
            Add(Description(HostText(ClientMessage.Setup)));

            Add(Heading(HostText(ClientMessage.AddressHeading)));
            Add(Description("QR·검색 결과는 미확인 주소 안내입니다. 선택만으로 페어링하거나 접속하지 않습니다."));
            link.Multiline = true; link.Height = 65; link.MaxLength = 1536; link.Dock = DockStyle.Fill; link.AccessibleName = HostText(ClientMessage.LinkName);
            link.AccessibleDescription = "QR 이미지나 연결 링크는 주소 후보만 표시합니다. 주소를 선택한 뒤 PIN 승인이 필요합니다.";
            link.TextChanged += delegate { selectionGeneration++; };
            Add(link); changing.Add(link);
            var entryButtons = Row();
            entryButtons.Controls.Add(ActionButton("링크 미리보기", delegate { PreviewLink(); }));
            entryButtons.Controls.Add(ActionButton("QR 이미지 가져오기…", async delegate { await ImportQrAsync(); }));
            entryButtons.Controls.Add(ActionButton("같은 Wi-Fi에서 찾기", async delegate { await DiscoverAsync(); }));
            Add(entryButtons);
            candidates.DropDownStyle = ComboBoxStyle.DropDownList; candidates.Dock = DockStyle.Fill;
            candidates.AccessibleName = HostText(ClientMessage.CandidateName); candidates.AccessibleDescription = "선택한 주소 사용을 눌러야 연결 대상이 바뀝니다. 아직 연결하거나 기기를 신뢰하지 않았습니다."; Add(candidates); changing.Add(candidates);
            var choose = Row(); choose.Controls.Add(ActionButton("선택한 주소 사용", delegate { ChooseCandidate(); })); Add(choose);
            advanced.Text = "고급: IPv4 주소 직접 입력"; advanced.AutoSize = true;
            advanced.CheckedChanged += delegate { manualPanel.Visible = advanced.Checked; }; changing.Add(advanced); Add(advanced);
            manual.Width = 190; manual.MaxLength = 15; manual.AccessibleName = HostText(ClientMessage.ManualName);
            manualPanel.AutoSize = true; manualPanel.WrapContents = true; manualPanel.Visible = false;
            manualPanel.Controls.Add(manual); manualPanel.Controls.Add(ActionButton("이 주소 사용", delegate { ChooseManual(); }));
            changing.Add(manual); Add(manualPanel);
            target.AutoSize = true; target.Text = HostText(ClientMessage.NoTarget); target.AccessibleName = "현재 선택한 연결 대상"; target.AccessibleDescription = target.Text; target.Font = new Font(Font, FontStyle.Bold); wrapping.Add(target); Add(target);
            Add(Description("LAN과 Tailscale 주소는 별도 연결로 보관해 각각 PIN 승인이 필요할 수 있습니다. 저장된 인증서를 다른 주소로 자동 복사하지 않습니다."));

            Add(Heading("2. 화면 엔진과 PIN 연결"));
            Add(Description("처음 한 번 공식 Moonlight Portable " + EnginePin.Version + "를 인터넷에서 받습니다. 고정 크기·SHA-256과 모든 엔진 파일을 확인하며 관리자 권한은 사용하지 않습니다. 기존 Moonlight 설정과 분리해 이 앱 전용 폴더에 저장합니다."));
            Add(Description(HostText(ClientMessage.EngineNetwork)));
            var engineActions = Row();
            install.Text = "화면 엔진 받기"; install.AutoSize = true; install.Click += async delegate { await InstallAsync(); }; engineActions.Controls.Add(install);
            pair.Text = HostText(ClientMessage.PairButton); pair.AutoSize = true; pair.Click += async delegate { await LaunchAsync(true); }; engineActions.Controls.Add(pair); Add(engineActions);
            progress.Minimum = 0; progress.Maximum = 100; progress.Visible = false; progress.Dock = DockStyle.Fill; progress.AccessibleName = "화면 엔진 다운로드와 검증 진행률"; Add(progress);
            Add(Description(HostText(ClientMessage.PinInstructions)));

            Add(Heading(HostText(ClientMessage.StreamHeading)));
            var settings = Row();
            ConfigureChoice(resolution, StreamQualityPolicy.Resolutions, 185, "해상도");
            ConfigureChoice(fps, StreamQualityPolicy.FrameRates, 65, "초당 프레임");
            ConfigureChoice(bitrate, StreamQualityPolicy.BitratesKbps, 100, "전송률 Mbps");
            settings.Controls.Add(QualitySetting("해상도", resolution));
            settings.Controls.Add(QualitySetting("FPS", fps));
            settings.Controls.Add(QualitySetting("전송률", bitrate));
            fullscreen.Text = "전체 화면"; fullscreen.AutoSize = true; fullscreen.Checked = true; settings.Controls.Add(fullscreen); changing.Add(fullscreen); Add(settings);
            Add(Description("4K 원본 화질에는 호스트의 4K 캡처·인코딩과 이 PC의 4K 디코딩 지원이 필요합니다. 높은 해상도·전송률은 네트워크 부하를 늘립니다. 호스트 디스플레이 설정은 자동으로 바꾸지 않습니다."));
            macCommandKeys.Text = HostText(ClientMessage.CommandOption);
            macCommandKeys.Visible = platform == HostPlatform.Mac; macCommandKeys.AutoSize = true; changing.Add(macCommandKeys); Add(macCommandKeys);
            fullscreen.CheckedChanged += delegate { if (!fullscreen.Checked) macCommandKeys.Checked = false; macCommandKeys.Enabled = !busy && !closing && fullscreen.Checked && platform == HostPlatform.Mac; };
            var streamActions = Row(); connect.Text = HostText(ClientMessage.StreamButton); connect.AutoSize = true; connect.Click += async delegate { await LaunchAsync(false); }; streamActions.Controls.Add(connect); Add(streamActions);
            Add(Description(HostText(ClientMessage.Keyboard)));
            Add(Description(HostText(ClientMessage.Shortcuts)));
            Add(Description(HostText(ClientMessage.Availability)));
        }

        private void Add(Control control)
        {
            control.Margin = new Padding(0, 0, 0, 12);
            content.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            content.Controls.Add(control, 0, content.RowCount++);
        }
        private Label Heading(string text) { return new Label { Text = text, AutoSize = true, Font = new Font(Font.FontFamily, 13f, FontStyle.Bold) }; }
        private Label Description(string text) { var label = new Label { Text = text, AutoSize = true, ForeColor = SystemColors.ControlText }; wrapping.Add(label); return label; }
        private FlowLayoutPanel Row() { return new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = true, Dock = DockStyle.Fill, Margin = new Padding(0) }; }
        private Button ActionButton(string text, EventHandler handler)
        { var button = new Button { Text = text, AutoSize = true, Padding = new Padding(4) }; button.Click += handler; changing.Add(button); return button; }
        private void ConfigureChoice<T>(ComboBox box, IEnumerable<StreamQualityChoice<T>> values, int width, string name)
        { box.DropDownStyle = ComboBoxStyle.DropDownList; foreach (StreamQualityChoice<T> value in values) box.Items.Add(value); box.SelectedIndex = 0; box.Width = width; box.AccessibleName = name; changing.Add(box); }
        private FlowLayoutPanel QualitySetting(string caption, ComboBox choice)
        {
            var row = Row(); row.Dock = DockStyle.None; row.WrapContents = false; row.Margin = new Padding(0, 0, 8, 0);
            row.Controls.Add(new Label { Text = caption, AutoSize = true, Margin = new Padding(0, 7, 6, 0) });
            row.Controls.Add(choice); return row;
        }
        private void UpdateWrapping()
        {
            if (content.Parent == null) return;
            int width = Math.Max(180, content.Parent.ClientSize.Width - content.Parent.Padding.Horizontal - SystemInformation.VerticalScrollBarWidth - 8);
            content.Width = width;
            foreach (Label label in wrapping) label.MaximumSize = new Size(width, 0);
        }

        private void PreviewLink()
        {
            if (busy) return;
            try
            {
                ReverseInvitation invitation = ConnectionPolicy.Parse(link.Text);
                ConnectionPolicy.RequireRole(invitation, platform);
                PreviewInvitation(invitation);
            }
            catch (Exception error) { ShowFailure(error); }
        }
        private void PreviewInvitation(ReverseInvitation invitation)
        {
            ClearSelectedTarget();
            candidates.Items.Clear();
            foreach (string address in invitation.Addresses) candidates.Items.Add(new CandidateItem(invitation.Name, address));
            candidates.SelectedIndex = 0;
            SetStatus(HostText(ClientMessage.LinkPreview));
        }
        private void ClearSelectedTarget()
        {
            selectedAddress = null;
            selectionGeneration++;
            target.Text = HostText(ClientMessage.NoTarget);
            target.AccessibleDescription = target.Text;
            UpdateControls();
        }
        private async Task ImportQrAsync()
        {
            if (busy || closing) return;
            string path;
            using (var dialog = new OpenFileDialog { Title = HostText(ClientMessage.QrTitle), Filter = "QR 이미지|*.png;*.jpg;*.jpeg;*.bmp", CheckFileExists = true, Multiselect = false, DereferenceLinks = false })
            {
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                path = dialog.FileName;
            }
            var request = new QrImportRequest(platform, selectedAddress, link.Text, selectionGeneration);
            qrReading = true;
            if (!Begin("선택한 QR 이미지를 이 PC에서 읽는 중입니다. ‘QR 결과 사용 취소’로 결과를 버릴 수 있습니다. 이미지 판독은 즉시 중단할 수 없어 취소·창 닫기는 판독이 끝날 때까지 기다립니다.")) { qrReading = false; return; }
            CancellationTokenSource pending = operation;
            try
            {
                QrImportResult result = await request.ReadAsync(path, pending.Token);
                if (closing || IsDisposed || Disposing || operation != pending) return;
                if (pending.IsCancellationRequested)
                {
                    SetStatus("QR 이미지 판독이 끝났습니다. 취소한 결과는 사용하지 않았습니다. 새 QR 이미지나 링크를 선택할 수 있습니다.");
                    return;
                }
                if (!request.Matches(platform, selectedAddress, link.Text, selectionGeneration))
                {
                    SetStatus("QR을 읽는 동안 연결 대상이나 링크가 바뀌어 결과를 사용하지 않았습니다. QR 이미지를 다시 선택하세요.");
                    return;
                }
                // Decoding and role validation finished for this exact source. Loading
                // candidates still requires an explicit address choice and PIN action.
                ConnectionPolicy.RequireRole(result.Invitation, platform);
                link.Text = result.Link;
                PreviewInvitation(result.Invitation);
            }
            catch (Exception error)
            {
                if (!closing && !IsDisposed && !Disposing && operation == pending &&
                    request.Matches(platform, selectedAddress, link.Text, selectionGeneration))
                {
                    if (pending.IsCancellationRequested) SetStatus("QR 이미지 판독이 끝났습니다. 취소한 결과는 사용하지 않았습니다. 새 QR 이미지나 링크를 선택할 수 있습니다.");
                    else ShowFailure(error);
                }
            }
            finally { qrReading = false; End(); }
        }
        private void ChooseCandidate()
        {
            if (busy) return;
            var item = candidates.SelectedItem as CandidateItem;
            if (item == null) { SetStatus("QR/링크 또는 검색으로 주소 후보를 먼저 불러오세요."); return; }
            Choose(item.Name, item.Address);
        }
        private void ChooseManual()
        {
            if (busy) return;
            try { Choose(HostText(ClientMessage.ManualTarget), ConnectionPolicy.Address(manual.Text)); }
            catch (Exception error) { ShowFailure(error); }
        }
        private void Choose(string name, string address)
        {
            selectedAddress = ConnectionPolicy.Address(address);
            selectionGeneration++;
            target.Text = name + " · " + selectedAddress + " · 연결 미확인";
            target.AccessibleDescription = target.Text;
            SetStatus(HostText(ClientMessage.AddressSelected));
            UpdateControls();
        }
        private async Task DiscoverAsync()
        {
            if (!Begin("같은 Wi-Fi의 Sunshine 주소 안내를 최대 8초 동안 찾는 중입니다. 기기에 접속하거나 포트를 스캔하지 않습니다.")) return;
            try
            {
                IList<ReverseCandidate> found = await ReverseDiscovery.FindAsync(operation.Token);
                if (closing) return;
                ClearSelectedTarget();
                candidates.Items.Clear();
                foreach (ReverseCandidate item in found)
                    if (ConnectionPolicy.ValidName(item.Name)) candidates.Items.Add(new CandidateItem(item.Name, ConnectionPolicy.Address(item.Address)));
                if (candidates.Items.Count != 0) candidates.SelectedIndex = 0;
                SetStatus(candidates.Items.Count == 0 ? HostText(ClientMessage.DiscoveryEmpty) : HostText(ClientMessage.DiscoveryFound));
            }
            catch (Exception error) { ShowFailure(error); }
            finally { End(); }
        }
        private async Task InstallAsync()
        {
            if (!Begin("고정 버전 Moonlight 화면 엔진을 다운로드하고 검증하는 중입니다.")) return;
            progress.Value = 0; progress.Visible = true;
            try
            {
                await store.InstallAsync(new Progress<int>(value => {
                    if (closing || IsDisposed) return;
                    progress.Value = Math.Max(0, Math.Min(100, value));
                    progress.Style = value >= 95 && value < 100 ? ProgressBarStyle.Marquee : ProgressBarStyle.Continuous;
                    if (value >= 95 && value < 100) SetStatus("다운로드 완료 · 화면 엔진의 압축을 풀고 모든 파일을 검증하는 중입니다.");
                }), operation.Token);
                SetStatus(HostText(ClientMessage.EngineReady));
            }
            catch (Exception error) { ShowFailure(error); }
            finally { progress.Visible = false; progress.Style = ProgressBarStyle.Continuous; End(); }
        }
        private async Task LaunchAsync(bool pairing)
        {
            if (selectedAddress == null || !store.Installed || busy) return;
            string address = selectedAddress;
            string[] arguments;
            try
            {
                arguments = pairing ? EngineCommands.Pair(address) : EngineCommands.Stream(address, ((StreamQualityChoice<string>)resolution.SelectedItem).Value,
                    ((StreamQualityChoice<int>)fps.SelectedItem).Value, ((StreamQualityChoice<int>)bitrate.SelectedItem).Value, fullscreen.Checked, ConnectionPolicy.MacCommandAllowed(platform, fullscreen.Checked, macCommandKeys.Checked));
            }
            catch (Exception error) { ShowFailure(error); return; }
            if (!Begin("화면 엔진의 모든 파일을 검증하는 중입니다.")) return;
            try
            {
                using (EngineLease lease = await Task.Run(() => store.Verify(operation.Token), operation.Token))
                {
                    SetStatus("로컬 연결 프로필과 사용 잠금을 확인하는 중입니다.");
                    using (ProfileLease profile = await Task.Run(() => EngineProfile.Prepare(store.Root, address), operation.Token))
                    {
                    operation.Token.ThrowIfCancellationRequested();
                    using (var child = new EngineProcess())
                    {
                        ownedProcess = child;
                        SetStatus(pairing ? HostText(ClientMessage.PairStarted) : "Moonlight 화면 창을 실행했습니다. 연결 상태는 그 창에서 확인하세요. ‘작업 취소’는 이 앱이 실행한 로컬 화면 엔진만 종료합니다.");
                        int exit = await child.RunAsync(lease, profile.Path, arguments, operation.Token);
                        SetStatus(exit == 0 ? (pairing ? HostText(ClientMessage.PairFinished) : HostText(ClientMessage.StreamFinished)) : HostText(ClientMessage.EngineFailed));
                    }
                    }
                }
            }
            catch (Exception error) { ShowFailure(error); }
            finally { ownedProcess = null; End(); }
        }

        private bool Begin(string message)
        { if (busy || closing) return false; busy = true; operation = new CancellationTokenSource(); SetStatus(message); UpdateControls(); return true; }
        private void End()
        {
            if (operation != null) { operation.Dispose(); operation = null; }
            busy = false;
            if (IsDisposed || Disposing) return;
            UpdateControls();
            if (closing) { allowClose = true; Close(); }
        }
        private void CancelOwned()
        {
            if (operation != null && !operation.IsCancellationRequested)
            {
                SetStatus(qrReading ? "QR 결과 사용을 취소했습니다. 이미지 판독은 즉시 중단할 수 없어 완료될 때까지 기다리는 중입니다. 결과는 주소 후보에 적용하지 않습니다." : "작업을 취소하고 이 앱이 실행한 로컬 작업만 정리하는 중입니다.");
                operation.Cancel();
            }
            if (ownedProcess != null) ownedProcess.Stop();
            cancel.Enabled = false;
        }
        private void OnClosing(object sender, FormClosingEventArgs args)
        {
            if (allowClose || !busy) return;
            args.Cancel = true; closing = true; CancelOwned();
        }
        private void UpdateControls()
        {
            if (IsDisposed || Disposing) return;
            foreach (Control control in changing) control.Enabled = !busy && !closing;
            if (platform != HostPlatform.Mac) macCommandKeys.Checked = false;
            macCommandKeys.Enabled = !busy && !closing && fullscreen.Checked && platform == HostPlatform.Mac;
            install.Enabled = !busy && !closing; install.Text = store.Installed ? "화면 엔진 파일 다시 확인" : "화면 엔진 받기";
            pair.Enabled = connect.Enabled = !busy && !closing && store.Installed && selectedAddress != null;
            cancel.Enabled = busy && !closing; cancel.Visible = busy;
            cancel.Text = qrReading ? "QR 결과 사용 취소" : "작업 취소";
        }
        private void SetStatus(string text) { if (!IsDisposed && !Disposing) status.SetMessage(text); }
        private void ShowFailure(Exception error)
        {
            SetStatus(ReverseErrors.ForOperation(error, platform));
        }
        private sealed class StatusTextBox : TextBox
        {
            internal void SetMessage(string text)
            {
                Text = text;
                // Framework 4.8 supports MSAA value changes; no newer UIA live-region
                // API is required. Actual Narrator behavior remains a device check.
                if (IsHandleCreated) AccessibilityNotifyClients(AccessibleEvents.ValueChange, -1);
            }
        }
        private sealed class CandidateItem
        {
            internal readonly string Name, Address;
            internal CandidateItem(string name, string address) { Name = name; Address = address; }
            public override string ToString() { return Name + " · " + Address + " · 미확인"; }
        }
    }
}
