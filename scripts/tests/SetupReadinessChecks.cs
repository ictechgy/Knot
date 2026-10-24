// SPDX-License-Identifier: GPL-3.0-only
// Compile alongside the exact production implementation. No socket is created.
namespace Knot.Setup
{
    public static class SetupReadinessChecks
    {
        private static int checks;
        private static void Expect(bool value, string message)
        {
            if (!value) throw new System.Exception(message);
            checks++;
        }

        private sealed class Attempt : ILocalPortAttempt
        {
            internal readonly System.Threading.Tasks.TaskCompletionSource<bool> Pending =
                new System.Threading.Tasks.TaskCompletionSource<bool>();
            internal int Connects, Disposes;
            internal string Mode;
            internal Attempt(string mode) { Mode = mode; }
            public System.Threading.Tasks.Task ConnectAsync()
            {
                Connects++;
                if (Mode == "success") return System.Threading.Tasks.Task.FromResult(true);
                if (Mode == "socket") throw new System.Net.Sockets.SocketException(10061);
                if (Mode == "unexpected") throw new System.InvalidOperationException("synthetic unexpected failure");
                if (Mode == "cancelled") Pending.TrySetCanceled();
                return Pending.Task;
            }
            public void Dispose()
            {
                Disposes++;
                if (Mode == "pending") Pending.TrySetException(new System.ObjectDisposedException("synthetic socket"));
            }
        }

        private static T Within<T>(System.Threading.Tasks.Task<T> task)
        {
            var winner = System.Threading.Tasks.Task.WhenAny(task,
                System.Threading.Tasks.Task.Delay(2000)).GetAwaiter().GetResult();
            Expect(object.ReferenceEquals(winner, task), "Local port operation exceeded the fixture watchdog.");
            return task.GetAwaiter().GetResult();
        }

        public static int Run()
        {
            checks = 0;
            var none = System.Threading.CancellationToken.None;
            var first = new Attempt("success"); int calls = 0;
            Expect(Within(LocalPortWait.WaitAsync(none, 500, 50, 1,
                () => { calls++; return first; })), "An immediate TCP completion should be reported.");
            Expect(calls == 1 && first.Connects == 1 && first.Disposes == 1,
                "A successful attempt must be disposed once without another probe.");

            foreach (var failure in new[] { "socket", "cancelled", "pending" })
            {
                var a = new Attempt(failure); var b = new Attempt("success"); calls = 0;
                Expect(Within(LocalPortWait.WaitAsync(none, 500, 20, 1,
                    () => ++calls == 1 ? a : b)), "An unavailable attempt must permit a later response.");
                Expect(calls == 2 && a.Connects == 1 && b.Connects == 1,
                    "Recovery must use exactly one new attempt.");
                Expect(a.Disposes == 1 && b.Disposes == 1,
                    "Unavailable, timed out, cancelled and successful attempts must all be disposed.");
            }

            var attempts = new System.Collections.Generic.List<Attempt>();
            Expect(!Within(LocalPortWait.WaitAsync(none, 80, 20, 2, () => {
                var attempt = new Attempt("ignore-close"); attempts.Add(attempt); return attempt;
            })), "The overall deadline must return false even for transports that ignore close.");
            Expect(attempts.Count > 0 && attempts.Count < 20, "Bounded polling must not spin without a delay.");
            foreach (var attempt in attempts)
                Expect(attempt.Disposes == 1, "Every globally timed out attempt must be closed.");
            // A late fault after the deadline is observed by production's continuation.
            foreach (var attempt in attempts) attempt.Pending.TrySetException(new System.Exception("synthetic late connect fault"));

            using (var cancel = new System.Threading.CancellationTokenSource())
            {
                calls = 0; cancel.Cancel(); bool cancelled = false;
                try { Within(LocalPortWait.WaitAsync(cancel.Token, 500, 20, 1,
                    () => { calls++; return new Attempt("success"); })); }
                catch (System.OperationCanceledException) { cancelled = true; }
                Expect(cancelled && calls == 0, "Already cancelled work must not create a connection attempt.");
            }
            using (var cancel = new System.Threading.CancellationTokenSource())
            {
                var a = new Attempt("ignore-close"); bool cancelled = false;
                var task = LocalPortWait.WaitAsync(cancel.Token, 500, 500, 1, () => a);
                cancel.Cancel();
                try { Within(task); } catch (System.OperationCanceledException) { cancelled = true; }
                Expect(cancelled && a.Disposes == 1,
                    "User cancellation must surface as cancellation and close the active socket.");
                a.Pending.TrySetException(new System.Exception("synthetic late cancellation fault"));
            }

            var bad = new Attempt("unexpected"); bool failed = false;
            try { Within(LocalPortWait.WaitAsync(none, 500, 50, 1, () => bad)); }
            catch (System.InvalidOperationException) { failed = true; }
            Expect(failed && bad.Disposes == 1, "Unexpected errors must propagate after disposal, not claim a response.");
            foreach (var limits in new[] { new[] { 0, 20, 1 }, new[] { 15001, 20, 1 },
                new[] { 500, 0, 1 }, new[] { 500, 2001, 1 }, new[] { 500, 20, 0 }, new[] { 500, 20, 1001 } })
            {
                calls = 0; failed = false;
                try { Within(LocalPortWait.WaitAsync(none, limits[0], limits[1], limits[2],
                    () => { calls++; return new Attempt("success"); })); }
                catch (System.ArgumentException) { failed = true; }
                Expect(failed && calls == 0, "Invalid limits must be refused before any transport is created.");
            }
            return checks;
        }
    }
}
