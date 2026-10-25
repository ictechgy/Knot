// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// Shared by the managed client and the PowerShell-hosted setup dialog. Only an
// explicit update request latches admission; ordinary window-close stays normal.
public class KnotUpdateForm : Form
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessageW(string message);
    private static readonly uint UpdateMessage = RegisterWindowMessageW("Knot.SafeCloseForUpdate.v2");
    private bool closePosted;
    private IntPtr requestOwner;
    public bool UpdateCloseRequested { get; private set; }
    public Func<bool> UpdateProtectedWork { get; set; }
    public event EventHandler UpdateCloseStateChanged;

    public void UpdateWorkDidFinish()
    {
        if (!UpdateCloseRequested || closePosted || IsDisposed || Disposing || !IsHandleCreated ||
            (UpdateProtectedWork != null && UpdateProtectedWork())) return;
        closePosted = true;
        BeginInvoke(new Action(delegate {
            closePosted = false;
            if (UpdateCloseRequested && !IsDisposed && !Disposing &&
                (UpdateProtectedWork == null || !UpdateProtectedWork())) Close();
        }));
    }

    protected override void WndProc(ref Message message)
    {
        if (UpdateMessage != 0 && message.Msg == UpdateMessage)
        {
            if (message.LParam == IntPtr.Zero) { message.Result = IntPtr.Zero; return; }
            if (message.WParam == new IntPtr(1) && (!UpdateCloseRequested || requestOwner == message.LParam))
            {
                requestOwner = message.LParam;
                UpdateCloseRequested = true;
                if (UpdateCloseStateChanged != null) UpdateCloseStateChanged(this, EventArgs.Empty);
                message.Result = new IntPtr(2); // Acknowledged; allow the bounded drain budget.
                UpdateWorkDidFinish();
            }
            else if (message.WParam == new IntPtr(2) && requestOwner == message.LParam)
            {
                UpdateCloseRequested = false;
                requestOwner = IntPtr.Zero;
                if (UpdateCloseStateChanged != null) UpdateCloseStateChanged(this, EventArgs.Empty);
                message.Result = new IntPtr(1);
            }
            else message.Result = IntPtr.Zero;
            return;
        }
        base.WndProc(ref message);
    }
}
