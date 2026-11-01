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
        private HostServer server;
        private bool closing;
        internal PreviewForm()
        {
            Text = "Knot Native Preview"; ClientSize = new Size(600, 420);
            MinimumSize = new Size(600, 440); StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 10);
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(20), ColumnCount = 1, RowCount = 8 };
            Controls.Add(layout);
            layout.Controls.Add(new Label { Text = "Knot Native Preview", AutoSize = true, Font = new Font("Segoe UI", 18, FontStyle.Bold) });
            layout.Controls.Add(new Label { Text = "Experimental Windows 11 Home SDR primary desktop host. Temporary trust only: every session needs a fresh invitation and your approval. No saved pairing or automatic reconnect.", AutoSize = true, MaximumSize = new Size(550, 0) });
            addresses.DropDownStyle = ComboBoxStyle.DropDownList; addresses.Width = 250;
            foreach (IPAddress address in PrivateAddresses()) addresses.Items.Add(address.ToString());
            if (addresses.Items.Count > 0) addresses.SelectedIndex = 0;
            layout.Controls.Add(addresses);
            FlowLayoutPanel actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill };
            share.Text = "Share"; copy.Text = "Copy invitation"; copy.Width = 135;
            stop.Text = "Stop / revoke all"; stop.Width = 155; copy.Enabled = stop.Enabled = false;
            actions.Controls.AddRange(new Control[] { share, copy, stop }); layout.Controls.Add(actions);
            status.Text = addresses.Items.Count == 0 ? "No private IPv4 or Tailscale address is available. Connect to your private network, then reopen this preview." : "Stopped. Click Share to create a secret invitation valid for 120 seconds.";
            status.AutoSize = true; status.MaximumSize = new Size(550, 0); layout.Controls.Add(status);
            peer.Text = "No active peer."; peer.AutoSize = true; peer.MaximumSize = new Size(550, 0); layout.Controls.Add(peer);
            FlowLayoutPanel approval = new FlowLayoutPanel { AutoSize = true };
            approve.Text = "Approve"; decline.Text = "Decline"; approve.Enabled = decline.Enabled = false;
            approval.Controls.AddRange(new Control[] { approve, decline }); layout.Controls.Add(approval);
            layout.Controls.Add(new Label { Text = "No audio, files, prelogin, lock screen or UAC secure desktop. A hardware H.264 encoder is required. Keep the invitation secret; copying it replaces the clipboard with this run's invitation.", AutoSize = true, MaximumSize = new Size(550, 0), ForeColor = Color.DimGray });
            share.Enabled = addresses.Items.Count > 0;
            share.Click += delegate { StartShare(); };
            copy.Click += delegate
            {
                try { if (server != null) { Clipboard.SetText(server.GetInvitation()); status.Text = "Secret invitation copied. It expires 120 seconds after Share and works once."; } }
                catch (ProtocolException) { copy.Enabled = false; status.Text = "This invitation is no longer available. Stop, then click Share for a fresh invitation."; }
                catch (System.Runtime.InteropServices.ExternalException) { status.Text = "Clipboard is busy. Try Copy invitation again."; }
            };
            stop.Click += delegate { StopShare(); };
            approve.Click += delegate { Decide(true); };
            decline.Click += delegate { Decide(false); };
            FormClosing += delegate { closing = true; if (server != null) { server.Dispose(); server = null; } };
        }
        private static List<IPAddress> PrivateAddresses()
        {
            List<IPAddress> result = new List<IPAddress>();
            foreach (NetworkInterface adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (adapter.OperationalStatus != OperationalStatus.Up) continue;
                foreach (UnicastIPAddressInformation entry in adapter.GetIPProperties().UnicastAddresses)
                    if (NativeProtocol.IsPrivate(entry.Address) && !result.Contains(entry.Address)) result.Add(entry.Address);
            }
            result.Sort(delegate(IPAddress a, IPAddress b) { return string.CompareOrdinal(a.ToString(), b.ToString()); });
            return result;
        }
        private void OnUi(Action action)
        {
            if (closing || IsDisposed || !IsHandleCreated) return;
            try { BeginInvoke(new MethodInvoker(delegate { if (!closing && !IsDisposed) action(); })); }
            catch (InvalidOperationException) { }
        }
        private void StartShare()
        {
            if (server != null || addresses.SelectedItem == null) return;
            try
            {
                HostServer run = new HostServer(IPAddress.Parse(addresses.SelectedItem.ToString()), 48631, new WindowsMediaFactory(), new WindowsInputSink(), false, null);
                server = run;
                run.StatusChanged = delegate(string text) { OnUi(delegate { if (server == run) status.Text = text; }); };
                run.ApprovalRequested = delegate(string name)
                {
                    OnUi(delegate
                    {
                        if (server != run) return;
                        copy.Enabled = false; peer.Text = "Pending viewer: " + name + " — approve within 60 seconds.";
                        approve.Enabled = decline.Enabled = true;
                    });
                };
                run.Finished = delegate
                {
                    OnUi(delegate
                    {
                        if (server != run) return;
                        run.Dispose(); server = null;
                        share.Enabled = true; addresses.Enabled = true; copy.Enabled = stop.Enabled = false;
                        approve.Enabled = decline.Enabled = false; peer.Text = "No active peer.";
                    });
                };
                share.Enabled = false; addresses.Enabled = false; copy.Enabled = stop.Enabled = true;
                status.Text = "Creating a fresh temporary session. Capture starts only after viewer approval.";
                run.Start();
            }
            catch (Exception)
            {
                if (server != null) { server.Dispose(); server = null; }
                share.Enabled = true; addresses.Enabled = true; copy.Enabled = stop.Enabled = false;
                status.Text = "Sharing could not start. Ensure the private address and port 48631 are available.";
            }
        }
        private void Decide(bool allowed)
        {
            approve.Enabled = decline.Enabled = false;
            if (server != null) server.RespondToApproval(allowed);
            peer.Text = allowed ? "Approved viewer; waiting for media readiness." : "Viewer declined.";
        }
        private void StopShare()
        {
            if (server != null) server.Stop();
            copy.Enabled = approve.Enabled = decline.Enabled = false;
            status.Text = "Stopped. Temporary trust revoked and this session's accepted input released.";
            peer.Text = "No active peer.";
        }
    }
}
