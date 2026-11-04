// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Threading;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        private static void DeadlineChecks()
        {
            DeadlineCompletionAndDispose(); DeadlineClockBoundaries();
            DeadlineExpirationDoesNotBlockHandoffRejection(); DeadlineWinnerRaces(); DeadlineActualTimer();
        }
        private static void DeadlineCompletionAndDispose()
        {
            int closes = 0;
            using (ConnectionDeadline deadline = new ConnectionDeadline(10, delegate { ++closes; }, delegate { return 0L; }, 1000, false))
            using (ManualResetEvent queued = new ManualResetEvent(false))
            using (ManualResetEvent invoke = new ManualResetEvent(false))
            {
                Thread callback = new Thread(delegate { queued.Set(); invoke.WaitOne(); deadline.Expire(); });
                callback.IsBackground = true; callback.Start();
                try
                {
                    Check(queued.WaitOne(4000)); Check(deadline.TryComplete());
                    deadline.Dispose(); invoke.Set(); Check(callback.Join(4000));
                    Check(closes == 0 && !deadline.TryComplete());
                }
                finally { invoke.Set(); callback.Join(4000); }
            }
            using (ConnectionDeadline deadline = new ConnectionDeadline(10, delegate { ++closes; }, delegate { return 0L; }, 1000, false))
            {
                deadline.Dispose(); deadline.Dispose(); deadline.Expire();
                Check(!deadline.TryComplete() && closes == 0);
            }
            long now = 0;
            using (ConnectionDeadline deadline = new ConnectionDeadline(10, delegate { ++closes; }, delegate { return now; }, 1000, false))
            {
                now = 10; deadline.Expire(); deadline.Expire();
                Check(!deadline.TryComplete() && closes == 1);
                deadline.Dispose(); deadline.Expire(); Check(closes == 1);
            }
        }
        private static void DeadlineClockBoundaries()
        {
            long now = 1000; int closes = 0;
            using (ConnectionDeadline deadline = new ConnectionDeadline(10, delegate { ++closes; }, delegate { return now; }, 1000, false))
            { now = 1009; Check(deadline.TryComplete()); }
            long[] starts = { 1000, 1000, long.MinValue, 0 };
            long[] ends = { 1010, 999, long.MaxValue, long.MaxValue };
            long[] frequencies = { 1000, 1000, 1000, long.MaxValue };
            int[] budgets = { 10, 10, 10, 1 };
            for (int i = 0; i < starts.Length; ++i)
            {
                now = starts[i];
                using (ConnectionDeadline deadline = new ConnectionDeadline(budgets[i], delegate { ++closes; }, delegate { return now; }, frequencies[i], false))
                {
                    now = ends[i]; Check(!deadline.TryComplete());
                    // A delayed timer cannot revive a late/backwards handshake;
                    // normal failed-handshake cleanup owns its close instead.
                    deadline.Expire(); Check(closes == 0);
                }
            }
            now = 0;
            using (ConnectionDeadline deadline = new ConnectionDeadline(10000, delegate { ++closes; }, delegate { return now; }, long.MaxValue, false))
            { now = long.MaxValue; Check(deadline.TryComplete() && closes == 0); }
            bool badMilliseconds = false, badFrequency = false;
            try { using (new ConnectionDeadline(0, delegate { }, delegate { return 0L; }, 1000, false)) { } }
            catch (ArgumentOutOfRangeException) { badMilliseconds = true; }
            try { using (new ConnectionDeadline(10, delegate { }, delegate { return 0L; }, 0, false)) { } }
            catch (ArgumentOutOfRangeException) { badFrequency = true; }
            Check(badMilliseconds && badFrequency);
        }
        private static void DeadlineExpirationDoesNotBlockHandoffRejection()
        {
            int closes = 0;
            using (ManualResetEvent entered = new ManualResetEvent(false))
            using (ManualResetEvent unblockClose = new ManualResetEvent(false))
            using (ManualResetEvent disposed = new ManualResetEvent(false))
            using (ConnectionDeadline deadline = new ConnectionDeadline(10, delegate
            {
                Interlocked.Increment(ref closes); entered.Set(); unblockClose.WaitOne();
            }, delegate { return 0L; }, 1000, false))
            {
                Thread callback = new Thread(deadline.Expire), disposer = null;
                callback.IsBackground = true; callback.Start();
                try
                {
                    Check(entered.WaitOne(4000)); Check(!deadline.TryComplete());
                    disposer = new Thread(delegate { deadline.Dispose(); disposed.Set(); });
                    disposer.IsBackground = true; disposer.Start();
                    // Close is deliberately blocked: Dispose must not wait for
                    // arbitrary callback/OS work which already owns expiration.
                    Check(disposed.WaitOne(4000));
                    Check(closes == 1 && !deadline.TryComplete());
                }
                finally
                {
                    unblockClose.Set(); callback.Join(4000);
                    if (disposer != null) disposer.Join(4000);
                }
            }
        }
        private static void DeadlineWinnerRaces()
        {
            for (int i = 0; i < 32; ++i)
            {
                int closes = 0; bool completed = false;
                using (ManualResetEvent go = new ManualResetEvent(false))
                using (ConnectionDeadline deadline = new ConnectionDeadline(10, delegate { Interlocked.Increment(ref closes); }, delegate { return 0L; }, 1000, false))
                {
                    Thread completion = new Thread(delegate { go.WaitOne(); completed = deadline.TryComplete(); });
                    Thread expiration = new Thread(delegate { go.WaitOne(); deadline.Expire(); });
                    completion.IsBackground = expiration.IsBackground = true;
                    completion.Start(); expiration.Start(); go.Set();
                    Check(completion.Join(4000)); Check(expiration.Join(4000));
                    Check(completed ? closes == 0 : closes == 1);
                    deadline.Dispose(); deadline.Expire();
                    Check(completed ? closes == 0 : closes == 1);
                }
            }
        }
        private static void DeadlineActualTimer()
        {
            int closes = 0;
            using (ManualResetEvent expired = new ManualResetEvent(false))
            using (ConnectionDeadline deadline = new ConnectionDeadline(10, delegate { Interlocked.Increment(ref closes); expired.Set(); }))
            {
                Check(expired.WaitOne(4000)); Check(closes == 1 && !deadline.TryComplete());
                deadline.Dispose(); deadline.Expire(); Check(closes == 1);
            }
        }
    }
}
