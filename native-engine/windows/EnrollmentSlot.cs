// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Diagnostics;

namespace Knot.NativePreview
{
    internal sealed class EnrollmentSlot : IDisposable
    {
        private readonly object gate = new object();
        private readonly Func<long> clock;
        private readonly long started;
        private readonly byte[] code;
        internal readonly byte[] Id;
        private int attempts;
        private long attemptStarted;
        private int attemptBudgetMilliseconds;
        private bool busy, consumed, revoked;
        internal EnrollmentSlot() : this(Stopwatch.GetTimestamp) { }
        internal EnrollmentSlot(Func<long> clock)
        {
            if (clock == null) throw new ArgumentException("Invalid monotonic clock.");
            this.clock = clock; started = clock(); Id = EnrollmentProtocol.Random(16); code = EnrollmentProtocol.NewCode();
        }
        internal int RemainingMilliseconds
        {
            get { lock (gate) return consumed ? 0 : LifetimeRemainingMilliseconds; }
        }
        internal int LifetimeRemainingMilliseconds
        {
            get { lock (gate) { long now = clock(); return revoked || now < started ? 0 :
                (int)Math.Max(0, Math.Min(120000, 120000 - ((double)now - started) * 1000.0 / Stopwatch.Frequency)); } }
        }
        internal bool IsConsumed { get { lock (gate) return consumed; } }
        internal int Attempts { get { lock (gate) return attempts; } }
        internal bool Busy { get { lock (gate) return busy; } }
        internal bool Available { get { lock (gate) return RemainingMilliseconds > 0 && attempts < 5; } }
        internal string DisplayCode
        {
            get { lock (gate) return RemainingMilliseconds > 0 && (attempts < 5 || busy) ? StrictJson.Utf8.GetString(code) : ""; }
        }
        internal byte[] Begin()
        {
            lock (gate)
            {
                if (busy) throw new ProtocolException("busy");
                int remaining = RemainingMilliseconds;
                if (remaining <= 0 || attempts >= 5) throw new ProtocolException("expired");
                attemptStarted = clock(); attemptBudgetMilliseconds = Math.Min(10000, remaining);
                ++attempts; busy = true; return (byte[])code.Clone();
            }
        }
        internal void Confirm()
        {
            lock (gate)
            {
                // The active fifth attempt may finish; no sixth attempt is admitted.
                long now = clock();
                if (!busy || revoked || consumed || now < started || now < attemptStarted ||
                    ((double)now - started) * 1000.0 / Stopwatch.Frequency >= 120000 ||
                    ((double)now - attemptStarted) * 1000.0 / Stopwatch.Frequency >= attemptBudgetMilliseconds) throw new ProtocolException("expired");
                consumed = true; busy = false; Array.Clear(code, 0, code.Length);
            }
        }
        internal void Failed() { lock (gate) busy = false; }
        public void Dispose() { lock (gate) { revoked = true; busy = false; Array.Clear(code, 0, code.Length); } }
    }
}
