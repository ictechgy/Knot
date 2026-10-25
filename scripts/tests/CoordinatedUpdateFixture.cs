// SPDX-License-Identifier: GPL-3.0-only
// Inert forms/processes in a fresh test directory; no installer or service runs.
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

internal sealed class CoordinatedUpdateFixture : KnotUpdateForm
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessageW(string text);
    [DllImport("user32.dll")] private static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr action, IntPtr owner);
    private readonly Timer timer = new Timer();
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private bool busy = true;
    private Process child;
    private int nonceChecks;
    internal CoordinatedUpdateFixture(string mode, string receipt) {
        Text = "Knot synthetic coordinated fixture";
        UpdateProtectedWork = delegate { return busy; };
        if (mode == "owner-child" || mode == "orphan") {
            child = Process.Start(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "UnsupportedEngine.exe"), "engine \"" + receipt + "\"");
            File.WriteAllText(receipt + ".child", child.Id.ToString());
            if (child.Handle == IntPtr.Zero) throw new InvalidOperationException();
        }
        Shown += delegate {
            File.WriteAllText(receipt + ".ready", "ready");
            if (mode == "nonce") {
                uint message = RegisterWindowMessageW("Knot.SafeCloseForUpdate.v2");
                Assert(SendMessageW(Handle, message, new IntPtr(1), new IntPtr(111)) == new IntPtr(2) && UpdateCloseRequested);
                Assert(SendMessageW(Handle, message, new IntPtr(1), new IntPtr(222)) == IntPtr.Zero && UpdateCloseRequested);
                Assert(SendMessageW(Handle, message, new IntPtr(2), new IntPtr(222)) == IntPtr.Zero && UpdateCloseRequested);
                Assert(SendMessageW(Handle, message, new IntPtr(2), new IntPtr(111)) == new IntPtr(1) && !UpdateCloseRequested);
                busy = false; UpdateWorkDidFinish();
                BeginInvoke(new Action(delegate {
                    Assert(!IsDisposed && !UpdateCloseRequested);
                    busy = true;
                    Assert(SendMessageW(Handle, message, new IntPtr(1), new IntPtr(333)) == new IntPtr(2));
                    busy = false; UpdateWorkDidFinish();
                }));
            }
        };
        timer.Interval = 50;
        timer.Tick += delegate {
            if (mode == "nonce" || !UpdateCloseRequested) return;
            if (mode == "orphan" && clock.ElapsedMilliseconds > 2000) Environment.Exit(0);
            if (mode == "mixed" || clock.ElapsedMilliseconds < 18000) return;
            if (child != null && !child.HasExited) {
                File.WriteAllText(receipt + ".owner-cleanup", "owner requested close");
                child.Refresh(); child.CloseMainWindow(); return;
            }
            busy = false; UpdateWorkDidFinish();
        };
        timer.Start();
        FormClosed += delegate { File.WriteAllText(receipt + ".closed", nonceChecks.ToString()); timer.Dispose(); if (child != null) child.Dispose(); };
    }
    private void Assert(bool condition) { if (!condition) throw new InvalidOperationException("Synthetic nonce/admission check failed"); nonceChecks++; }
    internal static void RunEngine(string receipt) {
        var form = new Form(); var timer = new Timer(); var clock = Stopwatch.StartNew();
        form.Text = "Synthetic contained engine";
        form.FormClosing += delegate {
            if (!File.Exists(receipt + ".owner-cleanup")) File.WriteAllText(receipt + ".unexpected-signal", "unexpected close");
        };
        timer.Interval = 50; timer.Tick += delegate {
            if (clock.ElapsedMilliseconds > 20000) { File.WriteAllText(receipt + ".owner-cleanup", "synthetic lifetime ended"); form.Close(); }
        }; timer.Start(); Application.Run(form); timer.Dispose();
    }
}
