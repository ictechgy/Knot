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
        private readonly ComboBox addresses = new ComboBox();
        private readonly Button share = new Button(), copy = new Button(), stop = new Button();
        private readonly Button approve = new Button(), decline = new Button();
        private readonly Label status = new Label(), peer = new Label();
        private readonly TextBox pin = new TextBox();
        private readonly RunPresentation presentation = new RunPresentation();
        private readonly List<Label> wrappingLabels = new List<Label>();
        private Icon ownedIcon;
        private HostServer server;
        private bool closing;
        internal PreviewForm()
        {
            Text = "Knot Native Preview"; ClientSize = new Size(720, 620);
            try { ownedIcon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath); if (ownedIcon != null) Icon = ownedIcon; }
            catch (ArgumentException) { }
            catch (System.Runtime.InteropServices.ExternalException) { }
            catch (NotSupportedException) { }
            catch (System.IO.FileNotFoundException) { }
            MinimumSize = new Size(620, 520); StartPosition = FormStartPosition.CenterScreen;
            AutoScaleDimensions = new SizeF(96, 96); AutoScaleMode = AutoScaleMode.Dpi;
            Font = new Font("Segoe UI", 10);
            Panel scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true };
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(20), ColumnCount = 1 };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            scroll.Controls.Add(layout); Controls.Add(scroll);
            Label title = Wrapped("Knot Native Preview"); title.Font = new Font("Segoe UI", 18, FontStyle.Bold); layout.Controls.Add(title);
            layout.Controls.Add(Wrapped("Experimental Windows 11 Home SDR primary desktop host. Temporary trust only: every session needs a fresh invitation and your approval. No saved pairing or automatic reconnect."));
            layout.Controls.Add(Wrapped("Share on this private network adapter:"));
            addresses.DropDownStyle = ComboBoxStyle.DropDownList; addresses.Dock = DockStyle.Top; addresses.DropDownWidth = 760;
            foreach (AdapterChoice address in PrivateAddresses()) addresses.Items.Add(address);
            if (addresses.Items.Count > 0) addresses.SelectedIndex = 0;
            layout.Controls.Add(addresses);
            FlowLayoutPanel actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, WrapContents = true };
            share.Text = "Share"; copy.Text = "Copy invitation"; stop.Text = "Stop / revoke all";
            foreach (Button button in new Button[] { share, copy, stop, approve, decline }) { button.AutoSize = true; button.Padding = new Padding(8, 3, 8, 3); }
            copy.Enabled = stop.Enabled = false; actions.Controls.AddRange(new Control[] { share, copy, stop }); layout.Controls.Add(actions);
            layout.Controls.Add(Wrapped("Current session certificate SHA-256 — compare this exact value with the Mac:"));
            pin.ReadOnly = true; pin.Dock = DockStyle.Top; pin.Font = new Font("Consolas", 9); pin.BackColor = Color.White;
            pin.BorderStyle = BorderStyle.FixedSingle; pin.ShortcutsEnabled = true; pin.AccessibleName = "Current session certificate SHA-256"; layout.Controls.Add(pin);
            status.UseMnemonic = peer.UseMnemonic = false;
            status.Text = addresses.Items.Count == 0 ? "No private IPv4 or Tailscale address is available. Connect to your private network, then reopen this preview." : "Stopped. Click Share to create a secret invitation valid for 120 seconds.";
            ConfigureWrapped(status); layout.Controls.Add(status);
            peer.Text = "No active peer."; ConfigureWrapped(peer); layout.Controls.Add(peer);
            FlowLayoutPanel approval = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, WrapContents = true };
            approve.Text = "Approve"; decline.Text = "Decline"; approve.Enabled = decline.Enabled = false;
            approval.Controls.AddRange(new Control[] { approve, decline }); layout.Controls.Add(approval);
            Label footer = Wrapped("No audio, files, prelogin, lock screen or UAC secure desktop. A hardware H.264 encoder is required. Keep the invitation secret. Copy replaces the current clipboard and requests Windows history/cloud exclusion; other software can still read the current clipboard.");
            footer.ForeColor = Color.DimGray; layout.Controls.Add(footer);
            layout.SizeChanged += delegate
            {
                int width = Math.Max(180, layout.ClientSize.Width - layout.Padding.Horizontal - 12);
                foreach (Label label in wrappingLabels) label.MaximumSize = new Size(width, 0);
            };
            share.Enabled = addresses.Items.Count > 0;
            share.Click += delegate { StartShare(); };
            copy.Click += delegate
            {
                try { if (server != null && presentation.IsCurrent(server.Identity)) { SecretClipboard.CopyOwnInvitation(server.GetInvitation()); status.Text = "Secret invitation copied with Windows history/cloud exclusion requested. It expires 120 seconds after Share and works once."; } }
                catch (ProtocolException) { copy.Enabled = false; status.Text = "This invitation is no longer available. Stop, then click Share for a fresh invitation."; }
                catch (System.Runtime.InteropServices.ExternalException) { status.Text = "Clipboard is busy or exclusion could not be applied. Try Copy invitation again."; }
            };
            stop.Click += delegate { StopShare(); }; approve.Click += delegate { Decide(true); }; decline.Click += delegate { Decide(false); };
            FormClosing += delegate { closing = true; if (server != null) { presentation.Clear(server.Identity); pin.Clear(); server.Dispose(); server = null; } };
            FormClosed += delegate { if (ownedIcon != null) { ownedIcon.Dispose(); ownedIcon = null; } };
        }
        private Label Wrapped(string text) { Label label = new Label { Text = text }; ConfigureWrapped(label); return label; }
        private void ConfigureWrapped(Label label)
        {
            label.UseMnemonic = false; label.AutoSize = true; label.Dock = DockStyle.Top; label.Margin = new Padding(3, 4, 3, 8);
            label.MaximumSize = new Size(660, 0); wrappingLabels.Add(label);
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
                server = run; presentation.Bind(run.Identity); pin.Text = presentation.Pin;
                run.StatusChanged = delegate(string text) { OnUi(delegate { if (server == run && presentation.IsCurrent(run.Identity)) status.Text = text; }); };
                run.ApprovalRequested = delegate(ApprovalMetadata metadata)
                {
                    OnUi(delegate
                    {
                        if (server != run || !presentation.PublishApproval(run.Identity, metadata)) return;
                        copy.Enabled = false; peer.Text = metadata.DisplayText; approve.Enabled = decline.Enabled = true;
                    });
                };
                run.Finished = delegate
                {
                    OnUi(delegate
                    {
                        if (server != run) return;
                        presentation.Clear(run.Identity); pin.Text = presentation.Pin; run.Dispose(); server = null;
                        share.Enabled = true; addresses.Enabled = true; copy.Enabled = stop.Enabled = false;
                        approve.Enabled = decline.Enabled = false; peer.Text = "No active peer.";
                    });
                };
                share.Enabled = false; addresses.Enabled = false; copy.Enabled = stop.Enabled = true;
                status.Text = "Invitation ready. Compare the certificate pin with the Mac. Capture starts only after approval."; run.Start();
            }
            catch (Exception)
            {
                if (server != null) { presentation.Clear(server.Identity); server.Dispose(); server = null; }
                pin.Text = presentation.Pin; share.Enabled = true; addresses.Enabled = true; copy.Enabled = stop.Enabled = false;
                status.Text = "Sharing could not start. Ensure the private address and port 48631 are available.";
            }
        }
        private void Decide(bool allowed)
        {
            approve.Enabled = decline.Enabled = false;
            if (server != null && presentation.IsCurrent(server.Identity)) server.RespondToApproval(allowed);
            peer.Text = allowed ? "Host approved this temporary connection; waiting for media readiness." : "Host declined the viewer request.";
        }
        private void StopShare()
        {
            if (server != null) { presentation.Clear(server.Identity); pin.Text = presentation.Pin; server.Stop(); }
            copy.Enabled = approve.Enabled = decline.Enabled = false;
            status.Text = "Stopped. Temporary trust revoked and this session's accepted input released."; peer.Text = "No active peer.";
        }
    }
}
