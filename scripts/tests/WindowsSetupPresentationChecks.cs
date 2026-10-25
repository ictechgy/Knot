// SPDX-License-Identifier: GPL-3.0-only
// Construct the actual packaged form without showing it or running its Shown handler.
// Only new in-memory session/control values are supplied; no API, vault or host is opened.
using System;
using System.Reflection;
using System.Windows.Forms;

internal static class WindowsSetupPresentationChecks
{
    private static int checks;
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    private static void Expect(bool value, string message) { if (!value) throw new Exception(message); checks++; }
    private static object Field(object target, string name) { return target.GetType().GetField(name, Private).GetValue(target); }
    private static void Set(object target, string name, object value) { target.GetType().GetField(name, Private).SetValue(target, value); }
    private static void Call(object target, string name) { target.GetType().GetMethod(name, Private).Invoke(target, null); }
    private static void Click(Button button) { typeof(Button).GetMethod("OnClick", Private).Invoke(button, new object[] { EventArgs.Empty }); }
    // Control.Visible includes invisible ancestors. Inspect each control's local
    // visibility bit on the supported Framework runtime while the form stays hidden.
    private static bool LocallyVisible(Control control)
    { return (bool)typeof(Control).GetMethod("GetState", Private).Invoke(control, new object[] { 2 }); }
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 2) return 2;
        var assembly = Assembly.LoadFrom(args[0]);
        Type formType = assembly.GetType("SunshineQuickSetupForm", true);
        Type sessionType = assembly.GetType("SunshineSetupSession", true);
        Type requestType = assembly.GetType("SunshinePendingPair", true);
        using (var form = (Form)Activator.CreateInstance(formType, Private, null, new object[] { args[1] }, null))
        {
            var prepare = (Button)Field(form, "prepare"); var refresh = (Button)Field(form, "refresh");
            var pending = (ComboBox)Field(form, "pending"); var pin = (TextBox)Field(form, "pin"); var pair = (Button)Field(form, "pair");
            var requests = (Control)Field(form, "requestFields"); var details = (Control)Field(form, "connectionDetails");
            var status = (TextBox)Field(form, "status");
            var detailsToggle = (Button)Field(form, "detailsToggle");
            Expect(refresh.Text == (string)assembly.GetType("SunshineSetupPolicy", true).GetField("RefreshPendingLabel", BindingFlags.Static | BindingFlags.NonPublic).GetRawConstantValue(), "Recovery instructions and visible refresh share one action label");
            Expect(!form.IsHandleCreated, "Construction must not show or initialize production setup");
            Expect(!LocallyVisible(prepare) && !LocallyVisible(refresh) && !LocallyVisible(requests) && !LocallyVisible(details), "Only contextual actions belong on the initial screen");
            Expect(status.ReadOnly && status.Parent is TableLayoutPanel && status.Parent != requests.Parent, "Selectable status stays outside scrolling content");
            object session = Activator.CreateInstance(sessionType, Private, null, new object[] { null, null, 45000 }, null);
            sessionType.GetProperty("PairingReady", Private).SetValue(session, true, null);
            Set(form, "session", session); Call(form, "RestoreAvailability");
            Expect(!LocallyVisible(requests) && !LocallyVisible(refresh) && !LocallyVisible(prepare), "Ready without requests does not ask for PIN or refresh");
            Expect(!LocallyVisible(details), "Ordinary readiness does not expand technical details");
            object request = Activator.CreateInstance(requestType, true); pending.Items.Add(request);
            Call(form, "UpdatePresentation");
            Expect(LocallyVisible(requests) && pending.SelectedIndex == -1 && !pin.Enabled && !pair.Enabled, "A request requires explicit peer selection");
            pending.SelectedIndex = 0;
            Expect(pin.Enabled && !pair.Enabled, "Selecting a peer enables PIN entry but cannot approve without a PIN");
            pin.Text = "123"; Expect(!pair.Enabled, "Incomplete PIN cannot approve");
            pin.Text = "abcd"; Expect(!pair.Enabled, "Non-digit PIN cannot approve");
            pin.Text = "1234"; Expect(pair.Enabled, "Exact four-digit PIN and selected peer enables approval");
            Set(form, "busy", true); Call(form, "UpdatePresentation");
            Expect(!pin.Enabled && !pair.Enabled, "Busy work blocks duplicate pairing");
            Call(form, "RestoreAvailability"); Click(detailsToggle);
            Expect(!pending.Enabled && !refresh.Enabled && !LocallyVisible(details), "Busy update cancellation does not re-enable inputs or disclosure actions");
            Set(form, "busy", false); Call(form, "RestoreAvailability");
            Expect(pin.Enabled && pair.Enabled, "Control availability recovers after work");
            form.GetType().BaseType.GetProperty("UpdateCloseRequested").SetValue(form, true, null);
            Click(detailsToggle); Call(form, "UpdatePresentation");
            Expect(!LocallyVisible(details) && !pair.Enabled && !pin.Enabled, "Update admission also blocks queued disclosure and pairing actions");
            form.GetType().BaseType.GetProperty("UpdateCloseRequested").SetValue(form, false, null);
            Click(detailsToggle); Expect(LocallyVisible(details), "Idle disclosure remains available");
            Click(detailsToggle); Expect(!LocallyVisible(details), "Idle disclosure can close again");
            pending.Items.Clear(); Call(form, "UpdatePresentation");
            Expect(!LocallyVisible(requests) && !pair.Enabled, "An expired or completed request cannot remain actionable");
            status.Text = "synthetic retained status"; Set(form, "pendingWarning", true); Call(form, "UpdatePresentation");
            Expect(LocallyVisible(refresh) && status.Text == "synthetic retained status", "Polling recovery appears without overwriting operation status");
            Set(form, "session", null);
            formType.GetProperty("HadFailure", Private | BindingFlags.Public).SetValue(form, true, null);
            Call(form, "RestoreAvailability");
            Expect(LocallyVisible(prepare) && prepare.Enabled, "Initialization failure offers an enabled retry even without a session");
            Set(form, "session", session);
            sessionType.GetProperty("NeedsSecurityReapply", Private).SetValue(session, true, null);
            Call(form, "UpdatePresentation");
            Expect(LocallyVisible(details), "Required security recovery is not hidden behind a disclosure");
            Expect(!form.IsHandleCreated, "Presentation checks must never start the Shown/network handler");
        }
        Console.WriteLine("{\"status\":\"passed\",\"checks\":" + checks + ",\"actualPackagedForm\":true,\"freshSyntheticOnly\":true,\"shown\":false,\"network\":false,\"vaultAccess\":false}");
        return 0;
    }
}
