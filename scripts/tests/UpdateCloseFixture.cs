// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;
internal sealed class UpdateFixtureForm : Form
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessageW(string message);
    private readonly uint closeMessage = RegisterWindowMessageW("Knot.SafeCloseForUpdate.v1");
    private readonly bool busy;
    internal UpdateFixtureForm(bool busy) { this.busy = busy; Text = "Knot synthetic update fixture"; ShowInTaskbar = false; }
    protected override void WndProc(ref Message message) {
        if (message.Msg == closeMessage) { message.Result = busy ? IntPtr.Zero : new IntPtr(1); if (!busy) BeginInvoke(new Action(Close)); return; }
        base.WndProc(ref message);
    }
    protected override void OnFormClosing(FormClosingEventArgs args) { if (busy) args.Cancel = true; base.OnFormClosing(args); }
}
internal static class UpdateCloseFixture
{
    [STAThread] private static void Main(string[] args) {
        if (args.Length == 1 && args[0] == "child") {
            using (var child = Process.Start(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "DeskBridge-Managed.exe"), "ready")) child.WaitForExit(); return;
        }
        Application.Run(new UpdateFixtureForm(args.Length == 1 && args[0] == "busy"));
    }
}
