// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Threading;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        private static void LiveTrustResumeChecks()
        {
            ResumeOwnerAndTerminalGates();
            foreach (bool silence in new bool[] { false, true })
            {
                ResumeAfterAuthenticatedRevocation(false, silence, false);
                ResumeAfterAuthenticatedRevocation(true, silence, false);
            }
            ResumeAfterAuthenticatedRevocation(true, false, true);
        }
        private static void ResumeOwnerAndTerminalGates()
        {
            int reads = 0, constructions = 0;
            Func<bool> live = delegate { ++reads; return true; };
            Action construct = delegate { ++constructions; };
            Check(!RegisteredConnectionResume.TryResume(false, false, true, construct, live));
            Check(!RegisteredConnectionResume.TryResume(true, true, true, construct, live));
            Check(!RegisteredConnectionResume.TryResume(true, false, false, construct, live));
            Check(reads == 0 && constructions == 0);
            Check(!RegisteredConnectionResume.TryResume(true, false, true, construct,
                delegate { ++reads; throw new IOException("Fresh synthetic trust-read failure."); }));
            Check(reads == 1 && constructions == 0);
        }
        private static void ResumeAfterAuthenticatedRevocation(bool anotherRemains, bool silence, bool failRead)
        {
            byte[] key = new byte[32]; for (int i = 0; i < key.Length; ++i) key[i] = 17;
            string id = NativeProtocol.Base64Url(new byte[32]);
            byte[] otherIdBytes = new byte[32]; otherIdBytes[0] = 1;
            string otherId = NativeProtocol.Base64Url(otherIdBytes);
            object storeGate = new object();
            Dictionary<string, byte[]> store = new Dictionary<string, byte[]>(StringComparer.Ordinal);
            store.Add(id, (byte[])key.Clone());
            if (anotherRemains) store.Add(otherId, (byte[])key.Clone());
            FakeInput sink = new FakeInput(); long inputTicks = 0;
            int reads = 0, constructions = 0, registrations = 0, revocations = 0, connectGrants = 0;
            using (TerminalStatusMediaFactory media = new TerminalStatusMediaFactory())
            using (HostServer host = RecoveryHost(media, sink, true, delegate { return Interlocked.Read(ref inputTicks); }))
            using (RunCertificate certificate = new RunCertificate())
            using (TrustedDeviceServer trusted = new TrustedDeviceServer(IPAddress.Loopback, certificate.Certificate, certificate.Pin,
                delegate(IPAddress peer, string token, string candidate, string name, string secret) { ++registrations; return false; },
                delegate(IPAddress peer, string name) { ++connectGrants; throw new ProtocolException("busy"); },
                delegate { return host.IsActive; }, syntheticLoopback: true, port: 0,
                lookupKey: delegate(string candidate) {
                    lock (storeGate) {
                        byte[] secret;
                        if (!store.TryGetValue(candidate, out secret)) throw new ProtocolException("auth");
                        return (byte[])secret.Clone();
                    }
                },
                revoke: delegate(string candidate) {
                    lock (storeGate) {
                        byte[] secret;
                        if (store.TryGetValue(candidate, out secret)) { store.Remove(candidate); Array.Clear(secret, 0, secret.Length); ++revocations; }
                    }
                }))
            {
                string offer = RecoveryNumberOffer(host); trusted.Start(); ++tlsFixtures;
                try
                {
                    using (TlsClient client = new TlsClient(host, OfferedPin(offer)))
                    {
                        client.Send(1, Hello(StrictJson.String(InvitationObject(offer), "token")));
                        Check(client.ReadNonHeartbeat().Kind == 2 && media.Entered.WaitOne(3000));
                        Check(host.IsActive && !host.IsRegisteredSession && host.HasRegisteredDevices);
                        // Revoke saved Mac A with a real fresh challenge while
                        // temporary number Mac B is latched in fake capture.
                        Check(RecoveryTrustedRequest(trusted, certificate.Pin, id, key, "revoke", false, false).Kind == 1);
                        lock (storeGate) Check(!store.ContainsKey(id) && store.Count == (anotherRemains ? 1 : 0));
                        Check(revocations == 1 && registrations == 0 && connectGrants == 0);
                        Check(host.HasRegisteredDevices && host.IsActive);
                        if (silence) Interlocked.Exchange(ref inputTicks, 11L * Stopwatch.Frequency);
                        else client.Client.Close();
                        WaitFor(delegate { return !host.IsActive; });
                        Check(host.MayResumeRegisteredConnection);
                        media.Continue.Set(); Check(host.WaitStopped(4000));
                        bool resumed = RegisteredConnectionResume.TryResume(true, false, host.MayResumeRegisteredConnection,
                            delegate {
                                // This is the same admission seam as Program's
                                // StartShare callback; construct only owned
                                // synthetic listeners after the live check.
                                ++constructions;
                                using (HostServer next = RecoveryHost(new FakeMediaFactory(), new FakeInput(), true))
                                    Check(next.Port > 0 && !next.IsActive);
                            },
                            delegate {
                                ++reads;
                                if (failRead) throw new IOException("Fresh synthetic trust-read failure.");
                                lock (storeGate) return store.Count != 0;
                            });
                        Check(resumed == (anotherRemains && !failRead));
                        Check(reads == 1 && constructions == (resumed ? 1 : 0));
                        Check(!host.IsActive && !host.IsRegisteredSession && media.Closed == 1 && sink.Events.Count == 0);
                        lock (storeGate) Check(!store.ContainsKey(id) && store.Count == (anotherRemains ? 1 : 0));
                    }
                }
                finally { media.Continue.Set(); }
            }
            Array.Clear(key, 0, key.Length);
            lock (storeGate) foreach (byte[] secret in store.Values) Array.Clear(secret, 0, secret.Length);
        }
    }
}
