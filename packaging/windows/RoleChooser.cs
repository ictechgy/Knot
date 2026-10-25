// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Drawing;
using System.Windows.Forms;

namespace DeskBridge.Reverse
{
    internal enum WindowsRole { Cancel, ShareWindows, OpenMac, OpenLinux }
    internal static class WindowsRoleChooser
    {
        internal static void ShowUpdates()
        {
            using (var icon = Icon.ExtractAssociatedIcon(System.Reflection.Assembly.GetExecutingAssembly().Location))
            using (var form = new Form { Text = "Knot · 업데이트", Icon = icon, StartPosition = FormStartPosition.CenterScreen, ClientSize = new Size(620, 260), AutoScroll = true })
            {
                var layout = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 1, Padding = new Padding(24) };
                layout.Controls.Add(new Label { AutoSize = true, Text = "Knot " + Knot.Updates.KnotUpdateConfiguration.DisplayVersion });
                KnotUpdates.AttachControls(layout);
                var close = new Button { AutoSize = true, Text = "닫기" }; close.Click += delegate { form.Close(); }; layout.Controls.Add(close);
                form.Controls.Add(layout); form.ShowDialog();
            }
        }
        internal static WindowsRole Choose()
        {
            using (var applicationIcon = System.Drawing.Icon.ExtractAssociatedIcon(System.Reflection.Assembly.GetExecutingAssembly().Location))
            using (var form = new Form())
            {
                form.Text = "Knot"; form.StartPosition = FormStartPosition.CenterScreen;
                form.Icon = applicationIcon;
                form.AutoScaleDimensions = new SizeF(96, 96); form.AutoScaleMode = AutoScaleMode.Dpi;
                form.ClientSize = new Size(660, 530); form.MinimumSize = new Size(400, 300);
                var layout = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(24), ColumnCount = 1, RowCount = 6 };
                layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
                layout.RowStyles.Add(new RowStyle(SizeType.AutoSize)); layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                layout.RowStyles.Add(new RowStyle(SizeType.AutoSize)); layout.RowStyles.Add(new RowStyle(SizeType.AutoSize)); layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                var title = new Label { Text = "어느 컴퓨터에서 작업할까요?", AutoSize = true, Font = new Font(SystemFonts.MessageBoxFont.FontFamily, 19, FontStyle.Bold), Margin = new Padding(0, 0, 0, 12) };
                var help = new Label { Text = "같은 네트워크 또는 Tailscale로 연결합니다. 기기 선택 후 페어링을 확인하세요.", AutoSize = true, Margin = new Padding(0, 0, 0, 22) };
                var host = new Button { Text = "이 Windows 공유\r\nMac에서 이 Windows에 접속하기", AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Dock = DockStyle.Top, Padding = new Padding(16), Margin = new Padding(0, 0, 0, 12), AccessibleName = "이 Windows 공유: Mac에서 접속" };
                var client = new Button { Text = "Mac 열기\r\n이 Windows에서 Mac에 접속하기", AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Dock = DockStyle.Top, Padding = new Padding(16), Margin = new Padding(0, 0, 0, 12), AccessibleName = "Mac 열기: Windows에서 접속" };
                var linux = new Button { Text = "Linux 열기\r\n이 Windows에서 Ubuntu X11에 접속하기", AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Dock = DockStyle.Top, Padding = new Padding(16), Margin = new Padding(0, 0, 0, 12), AccessibleName = "Linux 열기: Windows에서 접속" };
                var note = new Label { Text = "공유와 접속은 별도로 켭니다. Mac 공유를 켜도 파일 접근이나 클립보드 동기화는 자동으로 허용되지 않습니다.", AutoSize = true, ForeColor = SystemColors.GrayText, Margin = new Padding(0, 8, 0, 0) };
                host.Click += delegate { form.DialogResult = DialogResult.Yes; form.Close(); };
                client.Click += delegate { form.DialogResult = DialogResult.No; form.Close(); };
                linux.Click += delegate { form.DialogResult = DialogResult.Retry; form.Close(); };
                layout.Controls.Add(title); layout.Controls.Add(help); layout.Controls.Add(host); layout.Controls.Add(client); layout.Controls.Add(linux); layout.Controls.Add(note);
                KnotUpdates.AttachControls(layout);
                var scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true }; scroll.Controls.Add(layout); form.Controls.Add(scroll);
                Action wrap = delegate { int width = Math.Max(240, form.ClientSize.Width - layout.Padding.Horizontal - 24); title.MaximumSize = new Size(width, 0); help.MaximumSize = new Size(width, 0); note.MaximumSize = new Size(width, 0); };
                form.Resize += delegate { wrap(); };
                form.Shown += delegate { Rectangle area = Screen.FromControl(form).WorkingArea; form.MinimumSize = new Size(Math.Min(form.MinimumSize.Width, area.Width), Math.Min(form.MinimumSize.Height, area.Height)); form.Size = new Size(Math.Min(form.Width, area.Width), Math.Min(form.Height, area.Height)); wrap(); host.Focus(); };
                DialogResult choice = form.ShowDialog();
                return choice == DialogResult.Yes ? WindowsRole.ShareWindows : choice == DialogResult.No ? WindowsRole.OpenMac : choice == DialogResult.Retry ? WindowsRole.OpenLinux : WindowsRole.Cancel;
            }
        }
    }
}
