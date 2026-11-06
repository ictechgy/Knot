// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Diagnostics;
using System.Threading;

namespace Knot.NativePreview
{
    // The barrier is processed by the same ordered reader as the accepted left
    // down/moves. A file connection cannot invent button ownership or a cursor.
    internal sealed partial class InputSession
    {
        private sealed class ExplorerTicket
        {
            internal readonly string Nonce;
            internal readonly long Expires = Stopwatch.GetTimestamp() + 3L * Stopwatch.Frequency;
            internal bool Acquired, Released;
            internal ExplorerTicket(string nonce) { Nonce = nonce; }
        }
        private ExplorerTicket explorerTicket;
        private Timer explorerExpiry;
        private ushort dragPointerX, dragPointerY;
        internal Action ExplorerReleaseFailed;

        private bool AdmitDuringExplorerDrag(Packet packet)
        {
            // Ignore already-in-flight input after the ordered barrier. Release
            // and heartbeat remain admitted; no stale actions are replayed.
            if (explorerTicket == null || packet.Kind == 0x24 || packet.Kind == 0x25 || packet.Kind == 0x26) return true;
            if (packet.Kind == 0x20 && packet.Payload.Length == 4 && packet.Payload[0] == 0) return true;
            if (packet.Kind == 0x22 && packet.Payload.Length == 5 &&
                (packet.Payload[0] == 2 || packet.Payload[0] == 4 || packet.Payload[0] == 6))
            {
                if (!CancelExplorerGesture()) throw new ProtocolException("input");
                return true;
            }
            return false;
        }
        private void ArmExplorerDrag(byte[] nonce)
        {
            if (nonce == null || nonce.Length != 16) throw new ProtocolException("protocol");
            if (!buttons.Contains(1) || explorerTicket != null) return;
            ExplorerTicket ticket = new ExplorerTicket(FileProtocol.Hex(nonce));
            explorerTicket = ticket;
            explorerExpiry = new Timer(delegate
            {
                bool failed = false;
                lock (gate)
                {
                    if (explorerTicket != ticket) return;
                    failed = !CancelExplorerGesture();
                }
                if (failed && ExplorerReleaseFailed != null) ExplorerReleaseFailed();
            }, null, 3000, Timeout.Infinite);
            Monitor.PulseAll(gate);
        }
        internal IExplorerDragInputLease AcquireExplorerDrag(string nonce)
        {
            if (!FileProtocol.Hex(nonce, 32)) throw new FileTransferException("protocol");
            long until = Stopwatch.GetTimestamp() + Stopwatch.Frequency;
            lock (gate)
            {
                while (!closed && explorerTicket == null && Stopwatch.GetTimestamp() < until)
                    Monitor.Wait(gate, 20);
                ExplorerTicket ticket = explorerTicket;
                if (closed || ticket == null || ticket.Acquired || ticket.Nonce != nonce ||
                    Stopwatch.GetTimestamp() >= ticket.Expires || !buttons.Contains(1))
                    throw new FileTransferException("denied");
                ticket.Acquired = true;
                return new ExplorerInputLease(this, ticket, dragPointerX, dragPointerY);
            }
        }
        internal void CancelExplorerDrag(string nonce)
        {
            bool failed = false;
            lock (gate)
            {
                if (explorerTicket != null && explorerTicket.Nonce == nonce) failed = !CancelExplorerGesture();
            }
            if (failed && ExplorerReleaseFailed != null) ExplorerReleaseFailed();
        }
        private bool CancelExplorerGesture()
        {
            ExplorerTicket ticket = explorerTicket;
            if (ticket == null) return true;
            explorerTicket = null;
            if (explorerExpiry != null) { explorerExpiry.Dispose(); explorerExpiry = null; }
            Monitor.PulseAll(gate);
            return ticket.Released || AbortExplorerLeft();
        }
        private bool AbortExplorerLeft()
        {
            if (!buttons.Contains(1)) return true;
            // Cancel the owned gesture before a left-up, so an aborted OLE drag
            // cannot accidentally drop onto an unrelated underlying window.
            if (!keys.Contains(1))
            {
                if (!sink.Key(1, false, true)) return false;
                keys.Add(1);
                if (!sink.Key(1, false, false)) return false;
                keys.Remove(1);
            }
            if (!sink.ReleaseButton(1)) return false;
            buttons.Remove(1); return true;
        }
        private sealed class ExplorerInputLease : IExplorerDragInputLease
        {
            private readonly InputSession owner;
            private readonly ExplorerTicket ticket;
            private readonly ushort x, y;
            private bool disposed;
            internal ExplorerInputLease(InputSession owner, ExplorerTicket ticket, ushort x, ushort y)
            { this.owner = owner; this.ticket = ticket; this.x = x; this.y = y; }
            public int X { get { return owner.rectangle.Left + (int)((long)x * Math.Max(0, owner.rectangle.Width - 1) / 65535); } }
            public int Y { get { return owner.rectangle.Top + (int)((long)y * Math.Max(0, owner.rectangle.Height - 1) / 65535); } }
            private bool Live { get { return !disposed && !owner.closed && owner.explorerTicket == ticket && Stopwatch.GetTimestamp() < ticket.Expires; } }
            public bool IsActive { get { lock (owner.gate) return Live; } }
            public bool Nudge()
            {
                lock (owner.gate)
                {
                    if (!Live || ticket.Released || !owner.buttons.Contains(1)) return false;
                    int width = Math.Max(2, owner.rectangle.Width);
                    int delta = Math.Max(1, (int)Math.Ceiling(65535.0 / (width - 1)));
                    ushort moved = (ushort)(x <= 65535 - delta ? x + delta : x - delta);
                    return owner.sink.Pointer(0, moved, y, owner.rectangle);
                }
            }
            public bool ReleaseLeft()
            {
                bool result;
                lock (owner.gate)
                {
                    if (!Live) return false;
                    result = ticket.Released || !owner.buttons.Contains(1) || owner.sink.ReleaseButton(1);
                    if (result) { owner.buttons.Remove(1); ticket.Released = true; }
                }
                if (!result && owner.ExplorerReleaseFailed != null) owner.ExplorerReleaseFailed();
                return result;
            }
            public bool CancelDrag()
            {
                bool result;
                lock (owner.gate)
                {
                    if (disposed) return true;
                    result = owner.explorerTicket != ticket || owner.CancelExplorerGesture();
                }
                if (!result && owner.ExplorerReleaseFailed != null) owner.ExplorerReleaseFailed();
                return result;
            }
            public void Dispose()
            {
                CancelDrag();
                lock (owner.gate) { disposed = true; }
            }
        }
    }
}
