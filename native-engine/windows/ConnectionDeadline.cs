// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Diagnostics;
using System.Threading;

namespace Knot.NativePreview
{
    // Timer.Dispose does not retract an already queued callback. Only the
    // Active winner owns expiration or handoff; no callback is joined and no
    // lock is held while expiration closes a possibly blocked connection.
    internal sealed class ConnectionDeadline : IDisposable
    {
        private const int Active = 0, Completed = 1, Expired = 2, Disposed = 3;
        private readonly Func<long> clock;
        private readonly Action expire;
        private readonly long started, frequency;
        private readonly int milliseconds;
        private readonly Timer timer;
        private int state;
        internal ConnectionDeadline(int milliseconds, Action expire)
            : this(milliseconds, expire, Stopwatch.GetTimestamp, Stopwatch.Frequency, true) { }
        internal ConnectionDeadline(int milliseconds, Action expire, Func<long> clock, long frequency, bool armTimer)
        {
            if (milliseconds < 1 || frequency < 1) throw new ArgumentOutOfRangeException();
            if (clock == null || expire == null) throw new ArgumentNullException();
            this.clock = clock; this.expire = expire; this.frequency = frequency; this.milliseconds = milliseconds;
            started = clock();
            if (armTimer) timer = new Timer(delegate { Expire(); }, null, milliseconds, Timeout.Infinite);
        }
        internal bool TryComplete()
        {
            long now = clock();
            // Decimal keeps both elapsed subtraction and the unit conversion
            // exact across the full signed timestamp range without overflow.
            if (now < started || ((decimal)now - started) * 1000 >= (decimal)milliseconds * frequency)
            {
                Interlocked.CompareExchange(ref state, Expired, Active);
                // The failed handshake owner performs its normal close. Do not
                // invoke arbitrary expiration work inside a caller's gate.
                return false;
            }
            return Interlocked.CompareExchange(ref state, Completed, Active) == Active;
        }
        internal void Expire()
        {
            if (Interlocked.CompareExchange(ref state, Expired, Active) != Active) return;
            try { expire(); } catch { }
        }
        public void Dispose()
        {
            Interlocked.CompareExchange(ref state, Disposed, Active);
            if (timer != null) timer.Dispose();
        }
    }
}
