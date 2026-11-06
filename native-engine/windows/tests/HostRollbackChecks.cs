// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        private static void HostRollbackChecks()
        {
            // Each attempt owns new loopback sockets, a new run certificate and
            // the actual pairing-module preflight. No worker, TLS client, app
            // store, capture, input injection or user directory is involved.
            for (int attempt = 0; attempt < 4; ++attempt)
            {
                FakeMediaFactory media = new FakeMediaFactory(); FakeInput input = new FakeInput();
                IOException injected = new IOException("Owned synthetic post-enrollment constructor failure.");
                int mediaPort = 0, enrollmentPort = 0, discoveryPort = 0;
                bool observed = false;
                HostServer unexpected = null;
                try
                {
                    unexpected = new HostServer(IPAddress.Loopback, 0, media, input, true, null, true,
                        Stopwatch.GetTimestamp, "Synthetic rollback PC", syntheticAfterEnrollment: delegate(int boundMedia, int boundEnrollment, int boundDiscovery)
                        {
                            mediaPort = boundMedia; enrollmentPort = boundEnrollment; discoveryPort = boundDiscovery;
                            throw injected;
                        });
                }
                catch (IOException failure) { observed = object.ReferenceEquals(failure, injected); }
                finally { if (unexpected != null) unexpected.Dispose(); }
                Check(observed && unexpected == null);
                Check(mediaPort > 0 && enrollmentPort > 0 && discoveryPort > 0);
                Check(mediaPort != enrollmentPort);
                Check(media.Opened == 0 && media.Closed == 0 && input.Events.Count == 0);
                // Rebind immediately with exclusive ownership, keeping all three
                // sockets open together. There is deliberately no GC, retry,
                // sleep or finalizer assistance between failure and this check.
                using (Socket mediaSocket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp))
                using (Socket enrollmentSocket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp))
                using (Socket discoverySocket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp))
                {
                    mediaSocket.ExclusiveAddressUse = true; enrollmentSocket.ExclusiveAddressUse = true; discoverySocket.ExclusiveAddressUse = true;
                    mediaSocket.Bind(new IPEndPoint(IPAddress.Loopback, mediaPort)); mediaSocket.Listen(1);
                    enrollmentSocket.Bind(new IPEndPoint(IPAddress.Loopback, enrollmentPort)); enrollmentSocket.Listen(1);
                    discoverySocket.Bind(new IPEndPoint(IPAddress.Loopback, discoveryPort));
                    Check(mediaSocket.IsBound && enrollmentSocket.IsBound && discoverySocket.IsBound);
                }
            }
            // Production callers cannot install a constructor hook, even if no
            // sockets have yet been opened; validation precedes all ownership.
            bool rejected = false;
            try
            {
                using (HostServer host = new HostServer(IPAddress.Parse("192.168.50.123"), 48631,
                    new FakeMediaFactory(), new FakeInput(), false, null, true, Stopwatch.GetTimestamp,
                    "Synthetic validation", syntheticAfterEnrollment: delegate { throw new InvalidOperationException("Unreachable hook"); })) { }
            }
            catch (ArgumentException) { rejected = true; }
            Check(rejected);
        }
    }
}
