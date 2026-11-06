// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;

namespace Knot.NativePreview
{
    internal static partial class NativeChecks
    {
        private static int enrollmentFixtures;
        private static int discoveryFixtures;
        private static void EnrollmentChecks()
        {
            EnrollmentPolicyChecks(); EnrollmentWireChecks(); EnrollmentPreflightChecks(); TrustedProofChecks(); TrustedChallengeChecks();
            EnrollmentOfferDeliveryFailure();
            EnrollmentWrongCodeThenClaim(); EnrollmentWrongName(); EnrollmentExpiredGrant();
            EnrollmentStopBeforeConfirm(); EnrollmentExpiredSlotBeforeConfirm(); EnrollmentAttemptLimit(); EnrollmentLegacyCrossClaim(); EnrollmentWrongSourceBeforeTls(); EnrollmentStopAfterOffer();
        }
        private static void TrustedChallengeChecks()
        {
            byte[] key = new byte[32]; for (int i = 0; i < key.Length; ++i) key[i] = 9;
            string id = NativeProtocol.Base64Url(new byte[32]), previousProof = null, previousNonce = null;
            int issued = 0, registered = 0, revoked = 0;
            using (RunCertificate certificate = new RunCertificate())
            using (TrustedDeviceServer server = new TrustedDeviceServer(IPAddress.Loopback, certificate.Certificate, certificate.Pin,
                delegate(IPAddress peer, string token, string registrationId, string name, string secret) { ++registered; return token == "owned-synthetic-proof"; },
                delegate(IPAddress peer, string name) { ++issued; return "owned-fresh-invitation-" + issued; }, delegate { return true; },
                syntheticLoopback: true, port: 0, lookupKey: delegate(string candidate) { if (candidate != id) throw new ProtocolException("auth"); return (byte[])key.Clone(); },
                revoke: delegate(string candidate) { ++revoked; }))
            {
                server.Start();
                for (int attempt = 0; attempt < 3; ++attempt)
                {
                    using (TcpClient client = new TcpClient())
                    {
                        client.Connect(IPAddress.Loopback, server.ListeningPort); client.ReceiveTimeout = 3000; client.SendTimeout = 3000;
                        using (System.Net.Security.SslStream tls = new System.Net.Security.SslStream(client.GetStream(), false,
                            delegate(object sender, System.Security.Cryptography.X509Certificates.X509Certificate peer,
                                System.Security.Cryptography.X509Certificates.X509Chain chain, System.Net.Security.SslPolicyErrors errors) {
                                return RunCertificate.VerifyPinned(peer, errors, certificate.Pin);
                            }))
                        {
                            tls.AuthenticateAsClient("knot-native", null, System.Security.Authentication.SslProtocols.Tls12, false);
                            TrustedWrite(tls, "{\"op\":\"connect\",\"id\":" + StrictJson.Quote(id) + ",\"name\":\"Synthetic Mac\",\"value\":\"\",\"key\":\"\"}");
                            Packet challenge = NativeProtocol.ReadClient(tls, true);
                            string nonce = StrictJson.String(StrictJson.Parse(challenge.Payload, "nonce"), "nonce");
                            Check(nonce != previousNonce && NativeProtocol.DecodeToken(nonce).Length == 32);
                            string proof = NativeProtocol.Base64Url(NativeTrustedDevices.Proof(key, id, nonce, "Synthetic Mac", certificate.Pin));
                            TrustedWrite(tls, "{\"proof\":" + StrictJson.Quote(attempt == 1 ? previousProof : proof) + "}");
                            if (attempt == 1)
                            {
                                byte[] header = NativeProtocol.ReadExactly(tls, 5);
                                Check(header[0] == 127 && NativeProtocol.U32(header, 1) <= 128);
                                string rejection = StrictJson.String(StrictJson.Parse(NativeProtocol.ReadExactly(tls, (int)NativeProtocol.U32(header, 1)), "code"), "code");
                                Check(rejection == "rejected" && issued == 1);
                            }
                            else {
                                string invitation = StrictJson.String(StrictJson.Parse(NativeProtocol.ReadClient(tls, true).Payload, "invitation"), "invitation");
                                Check(invitation == "owned-fresh-invitation-" + issued);
                            }
                            previousProof = proof; previousNonce = nonce;
                        }
                    }
                }
                Check(issued == 2 && registered == 0 && revoked == 0);
            }
        }
        private static void TrustedWrite(Stream stream, string json)
        {
            byte[] bytes = StrictJson.Utf8.GetBytes(json), header = new byte[5]; header[0] = 1; NativeProtocol.Put32(header, 1, (uint)bytes.Length);
            stream.Write(header, 0, 5); stream.Write(bytes, 0, bytes.Length);
        }
        private static void TrustedProofChecks()
        {
            byte[] key = new byte[32]; for (int i = 0; i < key.Length; ++i) key[i] = 7;
            byte[] proof = NativeTrustedDevices.Proof(key, "synthetic-id", "synthetic-nonce", "Synthetic Mac", "synthetic-pin");
            Check(NativeProtocol.Base64Url(proof) == "5mVsd7kvPLtyBsDnCN5Kq4B1Q9wv7v3xbtcTzu8dOd8");
            Check(!NativeProtocol.Equal(proof, NativeTrustedDevices.Proof(key, "synthetic-id", "changed-nonce", "Synthetic Mac", "synthetic-pin")));
            Check(!NativeProtocol.Equal(proof, NativeTrustedDevices.Proof(key, "changed-id", "synthetic-nonce", "Synthetic Mac", "synthetic-pin")));
            Check(!NativeProtocol.Equal(proof, NativeTrustedDevices.Proof(key, "synthetic-id", "synthetic-nonce", "Other Mac", "synthetic-pin")));
            Check(!NativeProtocol.Equal(proof, NativeTrustedDevices.Proof(key, "synthetic-id", "synthetic-nonce", "Synthetic Mac", "changed-pin")));
        }
        private static void EnrollmentPreflightChecks()
        {
            int preflights = 0, clockReads = 0, grants = 0; EnrollmentServer published = null; bool failed = false;
            try
            {
                published = new EnrollmentServer(IPAddress.Loopback, "Synthetic Windows", true,
                    delegate { ++clockReads; return 0L; },
                    delegate(byte[] slot, string name, IPAddress peer) { ++grants; return null; }, null, null,
                    delegate { ++preflights; throw new PairingSetupException(); });
            }
            catch (PairingSetupException) { failed = true; }
            finally { if (published != null) published.Dispose(); }
            // EnrollmentSlot's constructor reads the clock before it can expose
            // a code or charge an attempt. A lazy loader failure precedes it.
            Check(failed && preflights == 1 && clockReads == 0 && grants == 0 && published == null);
            Check(EnrollmentGuidance.Classify(new ProtocolException("auth")) == EnrollmentFailure.Protocol);
            Check(EnrollmentGuidance.Classify(new ProtocolException("expired")) == EnrollmentFailure.Expired);
            Check(EnrollmentGuidance.For(EnrollmentFailure.Setup) != EnrollmentGuidance.For(EnrollmentFailure.Authentication));
            Check(EnrollmentGuidance.For(EnrollmentFailure.StaleCandidate) != EnrollmentGuidance.For(EnrollmentFailure.Authentication));
            Check(EnrollmentGuidance.For(EnrollmentFailure.Protocol) != EnrollmentGuidance.For(EnrollmentFailure.Authentication));
        }
        private static void EnrollmentOfferDeliveryFailure()
        {
            // A fresh PAKE attempt exercises only the enrollment listener: no
            // HostServer, TLS certificate, desktop, capture or input is created.
            int grants = 0, writes = 0, callbacks = 0, notices = 0;
            bool authenticatedViewer = false, sealedOffer = false;
            EnrollmentFailure terminal = EnrollmentFailure.Unavailable;
            using (ManualResetEvent completed = new ManualResetEvent(false))
            {
                EnrollmentServer server = null;
                using (server = new EnrollmentServer(IPAddress.Loopback, "Synthetic Windows", true, Stopwatch.GetTimestamp,
                    delegate(byte[] slot, string name, IPAddress peer)
                    {
                        server.Slot.Confirm();
                        authenticatedViewer = NativeProtocol.Equal(slot, server.Slot.Id) &&
                            name == "Synthetic viewer" && IPAddress.IsLoopback(peer);
                        Interlocked.Increment(ref grants);
                        return new EnrollmentGrant(slot, new byte[16], "fresh-synthetic-invitation", 30000);
                    },
                    delegate(EnrollmentFailure failure)
                    {
                        terminal = failure; Interlocked.Increment(ref callbacks);
                        // Mirror the owner's terminal callback: revoke and stop,
                        // never reactivate this already consumed enrollment slot.
                        server.Stop(); completed.Set();
                    },
                    delegate(string ignored) { Interlocked.Increment(ref notices); }, null,
                    delegate(Stream ignored, byte[] payload)
                    {
                        sealedOffer = payload.Length > 0; Interlocked.Increment(ref writes);
                        throw new IOException("Fresh synthetic offer delivery failure");
                    }))
                {
                    ++enrollmentFixtures; server.Start();
                    byte[] slot = (byte[])server.Slot.Id.Clone();
                    using (PairingCryptoSession crypto = PairingCryptoSession.Create(false, Bytes(server.Code), slot))
                    using (TcpClient client = new TcpClient())
                    {
                        client.Connect(IPAddress.Loopback, server.Port); client.ReceiveTimeout = client.SendTimeout = 3000;
                        NetworkStream stream = client.GetStream(); stream.Write(EnrollmentProtocol.Preamble, 0, 8);
                        byte[] hello = new byte[48]; Buffer.BlockCopy(slot, 0, hello, 0, 16); Buffer.BlockCopy(crypto.Message, 0, hello, 16, 32);
                        EnrollmentProtocol.Write(stream, 1, hello); Packet response = EnrollmentProtocol.Read(stream, 2);
                        byte[] returnedSlot = new byte[16], message = new byte[32];
                        Buffer.BlockCopy(response.Payload, 0, returnedSlot, 0, 16); Buffer.BlockCopy(response.Payload, 16, message, 0, 32);
                        Check(NativeProtocol.Equal(returnedSlot, slot)); crypto.Process(message);
                        EnrollmentProtocol.Write(stream, 3, crypto.Seal(3, Confirm(slot, "Synthetic viewer")));
                        Check(completed.WaitOne(4000));
                        bool closed = false;
                        try { closed = stream.ReadByte() == -1; }
                        catch (IOException error)
                        {
                            SocketException socket = error.InnerException as SocketException;
                            closed = socket != null && socket.SocketErrorCode == SocketError.ConnectionReset;
                        }
                        Check(closed);
                    }
                    Check(terminal == EnrollmentFailure.Delivery && callbacks == 1 && notices == 0);
                    Check(authenticatedViewer && sealedOffer && grants == 1 && writes == 1);
                    Check(server.Slot.IsConsumed && server.Slot.Attempts == 1 && !server.Slot.Busy && !server.Slot.Available);
                    Check(server.Code == "" && server.Slot.LifetimeRemainingMilliseconds == 0);
                    Reject(delegate { server.Slot.Begin(); }); Reject(delegate { server.Slot.Confirm(); });
                    server.Start(); Check(grants == 1 && writes == 1 && callbacks == 1);
                    Check(EnrollmentGuidance.For(terminal) != EnrollmentGuidance.For(EnrollmentFailure.Unavailable));
                    Check(EnrollmentGuidance.For(terminal) != EnrollmentGuidance.For(EnrollmentFailure.Authentication));
                    Check(EnrollmentGuidance.For(terminal) != EnrollmentGuidance.For(EnrollmentFailure.Expired));
                }
            }
        }
        private static void DiscoveryExclusiveBind(HostServer server)
        {
            using (Socket duplicate = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp))
            {
                duplicate.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                bool blocked = false;
                try { duplicate.Bind(new IPEndPoint(IPAddress.Loopback, server.DiscoveryPort)); }
                catch (SocketException) { blocked = true; }
                Check(blocked);
            }
        }
        private static void EnrollmentPolicyChecks()
        {
            long now = 0;
            using (EnrollmentSlot slot = new EnrollmentSlot(delegate { return now; }))
            {
                Check(slot.Id.Length == 16 && slot.DisplayCode.Length == 8 && slot.Available);
                foreach (char c in slot.DisplayCode) Check(c >= '0' && c <= '9');
                for (int i = 0; i < 4; ++i)
                {
                    byte[] password = slot.Begin(); Check(password.Length == 8 && slot.Busy); Array.Clear(password, 0, password.Length);
                    Reject(delegate { slot.Begin(); }); slot.Failed(); Check(slot.Available && !slot.Busy);
                }
                byte[] last = slot.Begin(); Array.Clear(last, 0, last.Length);
                Check(slot.Attempts == 5 && !slot.Available && slot.LifetimeRemainingMilliseconds > 0);
                slot.Confirm(); Check(slot.IsConsumed && slot.DisplayCode == ""); Reject(delegate { slot.Begin(); }); Reject(delegate { slot.Confirm(); });
            }
            using (EnrollmentSlot slot = new EnrollmentSlot(delegate { return now; }))
            {
                now = 120L * Stopwatch.Frequency; Check(!slot.Available && slot.DisplayCode == ""); Reject(delegate { slot.Begin(); });
            }
            now = 0;
            using (EnrollmentSlot slot = new EnrollmentSlot(delegate { return now; }))
            {
                byte[] password = slot.Begin(); Array.Clear(password, 0, password.Length);
                now = 10L * Stopwatch.Frequency; Reject(delegate { slot.Confirm(); });
                Check(!slot.IsConsumed && slot.Attempts == 1); slot.Failed(); Check(slot.Available);
            }
            now = 0;
            using (EnrollmentSlot slot = new EnrollmentSlot(delegate { return now; }))
            { slot.Begin(); now = -1; Check(!slot.Available); Reject(delegate { slot.Confirm(); }); }
            now = 0; Invitation grant = new Invitation(delegate { return now; }, 30000);
            byte[] token = InvitationToken(grant); now = 29L * Stopwatch.Frequency; Check(!grant.IsExpired);
            now = 30L * Stopwatch.Frequency; Check(grant.IsExpired); Reject(delegate { grant.Claim(token); });
            Array.Clear(token, 0, token.Length); grant.Revoke();
            now = 0; DiscoveryRate rate = new DiscoveryRate(delegate { return now; });
            for (int i = 0; i < 10; ++i) Check(rate.Take()); Check(!rate.Take()); now = Stopwatch.Frequency; Check(rate.Take());
        }
        private static void EnrollmentWireChecks()
        {
            DisplayNameWireChecks();
            byte[] id = new byte[16], nonce = new byte[16]; nonce[0] = 7;
            byte[] query = EnrollmentProtocol.DiscoveryQuery(nonce); Check(query.Length == 24);
            Check(NativeProtocol.Equal(EnrollmentProtocol.DiscoveryNonce(query), nonce));
            query[0] ^= 1; Reject(delegate { EnrollmentProtocol.DiscoveryNonce(query); });
            Reject(delegate { EnrollmentProtocol.DiscoveryNonce(new byte[1025]); });
            byte[] reply = EnrollmentProtocol.DiscoveryReply(nonce, id, "Synthetic Windows", 48632);
            Dictionary<string, object> info = StrictJson.Parse(reply, "v", "nonce", "slot", "name", "port");
            Check(reply.Length <= 1024 && StrictJson.Integer(info, "v", 2, 2) == 2 && StrictJson.Integer(info, "port", 1, 65535) == 48632);
            Check(NativeProtocol.Equal(EnrollmentProtocol.Identifier(StrictJson.String(info, "nonce")), nonce));
            Check(NativeProtocol.Equal(EnrollmentProtocol.Identifier(StrictJson.String(info, "slot")), id));
            Reject(delegate { EnrollmentProtocol.Identifier(NativeProtocol.Base64Url(new byte[32])); });
            Reject(delegate { EnrollmentProtocol.Identifier("!!!!!!!!!!!!!!!!!!!!!!"); });
            byte[] confirm = Confirm(id, "Synthetic viewer");
            Check(EnrollmentProtocol.ConfirmName(confirm, id) == "Synthetic viewer");
            byte[] wrong = new byte[16]; wrong[0] = 1; Reject(delegate { EnrollmentProtocol.ConfirmName(confirm, wrong); });
            Reject(delegate { EnrollmentProtocol.ConfirmName(Bytes("{\"v\":2,\"slot\":\"" + NativeProtocol.Base64Url(id) + "\",\"name\":\"peer\",\"permissions\":\"files\"}"), id); });
            Reject(delegate { EnrollmentProtocol.ConfirmName(Bytes("{\"v\":2,\"slot\":\"" + NativeProtocol.Base64Url(id) + "\",\"name\":\"peer\",\"permissions\":\"screen,input\",\"extra\":true}"), id); });
            Reject(delegate { EnrollmentProtocol.ValidName("bad\nname"); });
            using (MemoryStream memory = new MemoryStream())
            {
                EnrollmentProtocol.Write(memory, 1, new byte[48]); memory.Position = 0; Check(EnrollmentProtocol.Read(memory, 1).Payload.Length == 48);
            }
            using (MemoryStream memory = new MemoryStream(new byte[] { 1, 0, 0, 16, 1 })) Reject(delegate { EnrollmentProtocol.Read(memory, 1); });
            using (MemoryStream memory = new MemoryStream(new byte[] { 3, 0, 0, 0, 48 })) Reject(delegate { EnrollmentProtocol.Read(memory, 1); });
            Reject(delegate { EnrollmentProtocol.Offer(id, id, "knot-native:v1:synthetic", 30001); });
        }
        private static void DisplayNameWireChecks()
        {
            // Pure policy/parser fixtures: no discovery, enrollment or TLS
            // connection is made and no network-fixture counter is incremented.
            byte[] slot = new byte[16], nonce = new byte[16], expectedToken = new byte[32];
            string helloPrefix = "{\"v\":1,\"token\":" + StrictJson.Quote(NativeProtocol.Base64Url(expectedToken)) + ",\"name\":";
            string[] valid = { "A", "My Mac", "개발 Mac", "مرحبا", "שלום", "e\u0301", "\U0001F600", "A\U0001F600Z",
                new string('a', 64), new string('한', 21) + "a", new string('a', 60) + "\U0001F600" };
            foreach (string name in valid)
            {
                NativeProtocol.ValidDisplayName(name); EnrollmentProtocol.ValidName(name);
                byte[] token;
                Check(NativeProtocol.HelloName(Bytes(helloPrefix + StrictJson.Quote(name) + "}"), out token) == name &&
                    NativeProtocol.Equal(token, expectedToken));
                Check(EnrollmentProtocol.ConfirmName(Confirm(slot, name), slot) == name);
                byte[] reply = EnrollmentProtocol.DiscoveryReply(nonce, slot, name, 48632);
                Check(StrictJson.String(StrictJson.Parse(reply, "v", "nonce", "slot", "name", "port"), "name") == name);
            }
            string[] invalid = { "", "bad\nname", "bad\tname", "bad\0name", "bad\u0085name", "bad\u2028name", "bad\u2029name",
                "bad\u202Ename", "bad\u2066name", "bad\u200Dname", "bad\U000E0001name",
                new string('a', 65), new string('한', 22), new string('a', 61) + "\U0001F600" };
            foreach (string name in invalid)
            {
                Reject(delegate { NativeProtocol.ValidDisplayName(name); });
                Reject(delegate { EnrollmentProtocol.ValidName(name); });
                byte[] token;
                Reject(delegate { NativeProtocol.HelloName(Bytes(helloPrefix + StrictJson.Quote(name) + "}"), out token); });
                Reject(delegate { EnrollmentProtocol.ConfirmName(Confirm(slot, name), slot); });
                Reject(delegate { EnrollmentProtocol.DiscoveryReply(nonce, slot, name, 48632); });
            }
            foreach (string invalidUnicode in new string[] { null, "\uD800", "\uDC00", "\uD800x", "\uDC00\uD800" })
            {
                Reject(delegate { NativeProtocol.ValidDisplayName(invalidUnicode); });
                Reject(delegate { EnrollmentProtocol.ValidName(invalidUnicode); });
            }
            foreach (string escapedName in new string[] { "\"\\ud800\"", "\"\\udc00\"", "\"\\ud800x\"", "\"\\udc00\\ud800\"" })
            {
                byte[] token;
                Reject(delegate { NativeProtocol.HelloName(Bytes(helloPrefix + escapedName + "}"), out token); });
                Reject(delegate { EnrollmentProtocol.ConfirmName(Bytes("{\"v\":2,\"slot\":" + StrictJson.Quote(NativeProtocol.Base64Url(slot)) +
                    ",\"name\":" + escapedName + ",\"permissions\":\"screen,input\"}"), slot); });
            }
        }
        private static byte[] Confirm(byte[] slot, string name)
        { return Bytes("{\"v\":2,\"slot\":" + StrictJson.Quote(NativeProtocol.Base64Url(slot)) + ",\"name\":" + StrictJson.Quote(name) + ",\"permissions\":\"screen,input\"}"); }
        private static HostServer EnrollmentHost(FakeMediaFactory media, FakeInput sink, Func<long> clock)
        { return new HostServer(IPAddress.Loopback, 0, media, sink, true, null, true, clock, "Synthetic Windows"); }
        private static byte[] Discover(HostServer server, bool fileFixture = false)
        {
            if (fileFixture) ++fileDiscoveryFixtures; else ++discoveryFixtures;
            using (UdpClient udp = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0)))
            {
                udp.Client.ReceiveTimeout = 3000; byte[] nonce = EnrollmentProtocol.Random(16), request = EnrollmentProtocol.DiscoveryQuery(nonce);
                udp.Send(request, request.Length, new IPEndPoint(IPAddress.Loopback, server.DiscoveryPort));
                IPEndPoint source = new IPEndPoint(IPAddress.Any, 0); byte[] bytes = udp.Receive(ref source);
                Dictionary<string, object> reply = StrictJson.Parse(bytes, "v", "nonce", "slot", "name", "port");
                Check(source.Address.Equals(IPAddress.Loopback) && bytes.Length <= 1024);
                Check(StrictJson.Integer(reply, "v", 2, 2) == 2 && StrictJson.Integer(reply, "port", 1, 65535) == server.EnrollmentPort);
                Check(NativeProtocol.Equal(EnrollmentProtocol.Identifier(StrictJson.String(reply, "nonce")), nonce));
                return EnrollmentProtocol.Identifier(StrictJson.String(reply, "slot"));
            }
        }
        private static string Enroll(HostServer server, byte[] slot, string code, bool tamper, bool requestFiles = false, bool fileFixture = false)
        {
            if (fileFixture) ++fileEnrollmentFixtures; else ++enrollmentFixtures;
            using (TcpClient client = new TcpClient())
            using (PairingCryptoSession crypto = PairingCryptoSession.Create(false, Bytes(code), slot))
            {
                client.Connect(IPAddress.Loopback, server.EnrollmentPort); client.ReceiveTimeout = client.SendTimeout = 3000;
                NetworkStream stream = client.GetStream(); stream.Write(EnrollmentProtocol.Preamble, 0, 8);
                byte[] hello = new byte[48]; Buffer.BlockCopy(slot, 0, hello, 0, 16); Buffer.BlockCopy(crypto.Message, 0, hello, 16, 32);
                EnrollmentProtocol.Write(stream, 1, hello);
                Packet response = EnrollmentProtocol.Read(stream, 2);
                byte[] returnedSlot = new byte[16], message = new byte[32]; Buffer.BlockCopy(response.Payload, 0, returnedSlot, 0, 16); Buffer.BlockCopy(response.Payload, 16, message, 0, 32);
                Check(NativeProtocol.Equal(returnedSlot, slot)); crypto.Process(message);
                byte[] confirm = requestFiles ? Bytes("{\"v\":2,\"slot\":" + StrictJson.Quote(NativeProtocol.Base64Url(slot)) + ",\"name\":\"Synthetic viewer\",\"permissions\":\"screen,input,files\"}") : Confirm(slot, "Synthetic viewer");
                byte[] sealedConfirm = crypto.Seal(3, confirm);
                if (tamper) sealedConfirm[sealedConfirm.Length - 1] ^= 1;
                EnrollmentProtocol.Write(stream, 3, sealedConfirm);
                byte[] plain = crypto.Open(4, EnrollmentProtocol.Read(stream, 4).Payload);
                try
                {
                    Dictionary<string, object> offer = StrictJson.Parse(plain, "v", "slot", "grant", "invitation", "ttlMs");
                    Check(StrictJson.Integer(offer, "v", 2, 2) == 2 && NativeProtocol.Equal(EnrollmentProtocol.Identifier(StrictJson.String(offer, "slot")), slot));
                    Check(EnrollmentProtocol.Identifier(StrictJson.String(offer, "grant")).Length == 16);
                    Check(StrictJson.Integer(offer, "ttlMs", 1, 30000) > 0);
                    string invitation = StrictJson.String(offer, "invitation");
                    Dictionary<string, object> fields = InvitationObject(invitation);
                    Check(StrictJson.String(fields, "address") == IPAddress.Loopback.ToString());
                    Check(StrictJson.Integer(fields, "port", 1, 65535) == server.Port);
                    Check(StrictJson.String(fields, "certificateSHA256") == server.Pin);
                    byte[] token = NativeProtocol.DecodeToken(StrictJson.String(fields, "token"));
                    Check(token.Length == 32); Array.Clear(token, 0, token.Length);
                    return invitation;
                }
                finally { Array.Clear(plain, 0, plain.Length); }
            }
        }
        private static string OfferedPin(string invitation)
        { return StrictJson.String(InvitationObject(invitation), "certificateSHA256"); }
        private static void WaitFor(Func<bool> result)
        {
            long until = Stopwatch.GetTimestamp() + 4L * Stopwatch.Frequency;
            while (!result() && Stopwatch.GetTimestamp() < until) Thread.Sleep(5);
            Check(result());
        }
        private static void EnrollmentWrongCodeThenClaim()
        {
            FakeMediaFactory media = new FakeMediaFactory(); FakeInput sink = new FakeInput();
            using (HostServer server = EnrollmentHost(media, sink, Stopwatch.GetTimestamp))
            {
                string notice = null;
                int approvals = 0; server.ApprovalRequested = delegate { Interlocked.Increment(ref approvals); };
                server.StatusChanged = delegate(string text)
                {
                    if (text == EnrollmentGuidance.For(EnrollmentFailure.Authentication) ||
                        text == EnrollmentGuidance.For(EnrollmentFailure.StaleCandidate) ||
                        text == EnrollmentGuidance.For(EnrollmentFailure.Protocol)) Interlocked.Exchange(ref notice, text);
                }; server.Start();
                DiscoveryExclusiveBind(server);
                byte[] slot = Discover(server); string code = server.EnrollmentCode;
                string wrong = (code[0] == '0' ? "1" : "0") + code.Substring(1);
                Reject(delegate { Enroll(server, slot, wrong, false); }); WaitFor(delegate { return !server.EnrollmentBusy; });
                Check(server.EnrollmentGrantsIssued == 0 && media.Opened == 0 && sink.Events.Count == 0 && approvals == 0 && server.EnrollmentAttempts == 1);
                Check(Interlocked.CompareExchange(ref notice, null, null) == EnrollmentGuidance.For(EnrollmentFailure.Authentication));
                byte[] wrongSlot = (byte[])slot.Clone(); wrongSlot[0] ^= 1;
                Reject(delegate { Enroll(server, wrongSlot, code, false); }); WaitFor(delegate { return !server.EnrollmentBusy; });
                Check(server.EnrollmentGrantsIssued == 0 && media.Opened == 0 && approvals == 0);
                Check(Interlocked.CompareExchange(ref notice, null, null) == EnrollmentGuidance.For(EnrollmentFailure.StaleCandidate));
                ++enrollmentFixtures;
                using (TcpClient malformed = new TcpClient())
                {
                    malformed.Connect(IPAddress.Loopback, server.EnrollmentPort); malformed.ReceiveTimeout = malformed.SendTimeout = 3000;
                    NetworkStream stream = malformed.GetStream(); stream.Write(new byte[8], 0, 8);
                    Packet error = EnrollmentProtocol.Read(stream, 127);
                    Check(StrictJson.String(StrictJson.Parse(error.Payload, "code"), "code") == "protocol");
                }
                WaitFor(delegate { return !server.EnrollmentBusy; });
                Check(Interlocked.CompareExchange(ref notice, null, null) == EnrollmentGuidance.For(EnrollmentFailure.Protocol));
                Reject(delegate { Enroll(server, slot, code, true); }); WaitFor(delegate { return !server.EnrollmentBusy; });
                Check(server.EnrollmentGrantsIssued == 0 && media.Opened == 0 && approvals == 0);
                Check(Interlocked.CompareExchange(ref notice, null, null) == EnrollmentGuidance.For(EnrollmentFailure.Authentication));
                string invite = Enroll(server, slot, code, false);
                Check(server.EnrollmentGrantsIssued == 1 && media.Opened == 0 && server.EnrollmentCode == "");
                Reject(delegate { server.GetInvitation(); });
                string token = StrictJson.String(InvitationObject(invite), "token"); ++tlsFixtures;
                using (TlsClient client = new TlsClient(server, OfferedPin(invite)))
                {
                    client.Send(1, Hello(token)); Check(client.ReadNonHeartbeat().Kind == 2); WaitFor(delegate { return server.IsActive; });
                    Check(media.Opened == 1 && approvals == 0);
                    server.Stop(); Check(server.WaitStopped(4000));
                }
                Check(!server.IsActive && server.EnrollmentCode == "");
            }
        }
        private static void EnrollmentWrongName()
        {
            FakeMediaFactory media = new FakeMediaFactory(); FakeInput sink = new FakeInput();
            using (HostServer server = EnrollmentHost(media, sink, Stopwatch.GetTimestamp))
            {
                int approvals = 0; server.ApprovalRequested = delegate { ++approvals; }; server.Start();
                string invite = Enroll(server, Discover(server), server.EnrollmentCode, false);
                string token = StrictJson.String(InvitationObject(invite), "token"); ++tlsFixtures;
                using (TlsClient client = new TlsClient(server, OfferedPin(invite)))
                {
                    client.Send(1, Bytes("{\"v\":1,\"token\":" + StrictJson.Quote(token) + ",\"name\":\"different viewer\"}"));
                    Check(client.ReadNonHeartbeat().Kind == 127);
                }
                Check(media.Opened == 0 && sink.Events.Count == 0 && approvals == 0); server.Stop(); Check(server.WaitStopped(4000));
            }
        }
        private static void EnrollmentExpiredGrant()
        {
            long now = 0; FakeMediaFactory media = new FakeMediaFactory(); FakeInput sink = new FakeInput();
            using (HostServer server = EnrollmentHost(media, sink, delegate { return Interlocked.Read(ref now); }))
            {
                server.Start(); string invite = Enroll(server, Discover(server), server.EnrollmentCode, false);
                string token = StrictJson.String(InvitationObject(invite), "token"); ++tlsFixtures;
                using (TlsClient client = new TlsClient(server, OfferedPin(invite)))
                {
                    Interlocked.Exchange(ref now, 31L * Stopwatch.Frequency); client.Send(1, Hello(token));
                    Check(client.ReadNonHeartbeat().Kind == 127);
                }
                Check(server.WaitStopped(4000) && media.Opened == 0 && sink.Events.Count == 0);
            }
        }
        private static void EnrollmentStopBeforeConfirm()
        {
            FakeMediaFactory media = new FakeMediaFactory(); FakeInput sink = new FakeInput();
            using (HostServer server = EnrollmentHost(media, sink, Stopwatch.GetTimestamp))
            {
                ++enrollmentFixtures;
                server.Start(); byte[] slot = Discover(server);
                using (PairingCryptoSession crypto = PairingCryptoSession.Create(false, Bytes(server.EnrollmentCode), slot))
                using (TcpClient client = new TcpClient())
                {
                    client.Connect(IPAddress.Loopback, server.EnrollmentPort); client.ReceiveTimeout = client.SendTimeout = 3000;
                    NetworkStream stream = client.GetStream(); stream.Write(EnrollmentProtocol.Preamble, 0, 8);
                    byte[] hello = new byte[48]; Buffer.BlockCopy(slot, 0, hello, 0, 16); Buffer.BlockCopy(crypto.Message, 0, hello, 16, 32);
                    EnrollmentProtocol.Write(stream, 1, hello); EnrollmentProtocol.Read(stream, 2);
                    server.Stop(); Check(server.WaitStopped(4000));
                }
                Check(server.EnrollmentGrantsIssued == 0 && media.Opened == 0 && sink.Events.Count == 0 && server.EnrollmentCode == "");
            }
        }
        private static void EnrollmentAttemptLimit()
        {
            FakeMediaFactory media = new FakeMediaFactory(); FakeInput sink = new FakeInput();
            using (HostServer server = EnrollmentHost(media, sink, Stopwatch.GetTimestamp))
            {
                server.Start(); byte[] slot = Discover(server); string code = server.EnrollmentCode;
                string wrong = (code[0] == '0' ? "1" : "0") + code.Substring(1);
                for (int i = 0; i < 5; ++i)
                {
                    Reject(delegate { Enroll(server, slot, wrong, false); });
                    WaitFor(delegate { return !server.EnrollmentBusy; });
                }
                Check(server.WaitStopped(4000) && server.EnrollmentAttempts == 5 && server.EnrollmentGrantsIssued == 0);
                Check(media.Opened == 0 && sink.Events.Count == 0 && server.EnrollmentCode == "");
            }
        }
        private static void EnrollmentExpiredSlotBeforeConfirm()
        {
            long now = 0; FakeMediaFactory media = new FakeMediaFactory(); FakeInput sink = new FakeInput();
            using (HostServer server = EnrollmentHost(media, sink, delegate { return Interlocked.Read(ref now); }))
            {
                ++enrollmentFixtures; server.Start(); byte[] slot = Discover(server);
                using (PairingCryptoSession crypto = PairingCryptoSession.Create(false, Bytes(server.EnrollmentCode), slot))
                using (TcpClient client = new TcpClient())
                {
                    client.Connect(IPAddress.Loopback, server.EnrollmentPort); client.ReceiveTimeout = client.SendTimeout = 3000;
                    NetworkStream stream = client.GetStream(); stream.Write(EnrollmentProtocol.Preamble, 0, 8);
                    byte[] hello = new byte[48]; Buffer.BlockCopy(slot, 0, hello, 0, 16); Buffer.BlockCopy(crypto.Message, 0, hello, 16, 32);
                    EnrollmentProtocol.Write(stream, 1, hello); Packet response = EnrollmentProtocol.Read(stream, 2);
                    byte[] message = new byte[32]; Buffer.BlockCopy(response.Payload, 16, message, 0, 32); crypto.Process(message);
                    Interlocked.Exchange(ref now, 120L * Stopwatch.Frequency);
                    // The host may close before a completed authenticated confirm can
                    // be written. Either outcome must leave no grant or media.
                    try { EnrollmentProtocol.Write(stream, 3, crypto.Seal(3, Confirm(slot, "Synthetic viewer"))); }
                    catch (IOException) { } catch (SocketException) { } catch (ObjectDisposedException) { }
                    Check(server.WaitStopped(4000));
                }
                Check(server.EnrollmentGrantsIssued == 0 && media.Opened == 0 && sink.Events.Count == 0 && server.EnrollmentCode == "");
            }
        }
        private static void EnrollmentLegacyCrossClaim()
        {
            FakeMediaFactory media = new FakeMediaFactory(); FakeInput sink = new FakeInput();
            Invitation original = new Invitation(); byte[] originalToken = InvitationToken(original);
            string oldToken = NativeProtocol.Base64Url(originalToken); Array.Clear(originalToken, 0, originalToken.Length);
            using (HostServer server = new HostServer(IPAddress.Loopback, 0, media, sink, true, original, true, Stopwatch.GetTimestamp, "Synthetic Windows"))
            {
                server.Start(); string invite = Enroll(server, Discover(server), server.EnrollmentCode, false); ++tlsFixtures;
                Check(StrictJson.String(InvitationObject(invite), "token") != oldToken);
                using (TlsClient client = new TlsClient(server, OfferedPin(invite)))
                { client.Send(1, Hello(oldToken)); Check(client.ReadNonHeartbeat().Kind == 127); }
                Check(media.Opened == 0 && sink.Events.Count == 0); server.Stop(); Check(server.WaitStopped(4000));
            }
        }
        private static void EnrollmentWrongSourceBeforeTls()
        {
            FakeMediaFactory media = new FakeMediaFactory(); FakeInput sink = new FakeInput();
            using (HostServer server = EnrollmentHost(media, sink, Stopwatch.GetTimestamp))
            {
                server.Start(); string invite = Enroll(server, Discover(server), server.EnrollmentCode, false);
                using (TcpClient unrelated = new TcpClient(new IPEndPoint(IPAddress.Parse("127.0.0.2"), 0)))
                {
                    unrelated.Connect(IPAddress.Loopback, server.Port); unrelated.ReceiveTimeout = 1000;
                    bool closed = false;
                    try { closed = unrelated.GetStream().Read(new byte[1], 0, 1) == 0; }
                    catch (IOException error)
                    {
                        SocketException socket = error.InnerException as SocketException;
                        closed = socket != null && socket.SocketErrorCode == SocketError.ConnectionReset;
                    }
                    Check(closed && media.Opened == 0 && sink.Events.Count == 0 && !server.IsActive);
                }
                ++tlsFixtures;
                using (TlsClient legitimate = new TlsClient(server, OfferedPin(invite)))
                {
                    legitimate.Send(1, Hello(StrictJson.String(InvitationObject(invite), "token")));
                    Check(legitimate.ReadNonHeartbeat().Kind == 2); WaitFor(delegate { return server.IsActive; });
                    Check(media.Opened == 1); server.Stop(); Check(server.WaitStopped(4000));
                }
            }
        }
        private static void EnrollmentStopAfterOffer()
        {
            FakeMediaFactory media = new FakeMediaFactory(); FakeInput sink = new FakeInput();
            using (HostServer server = EnrollmentHost(media, sink, Stopwatch.GetTimestamp))
            {
                int approvals = 0; server.ApprovalRequested = delegate { Interlocked.Increment(ref approvals); };
                server.Start(); string invite = Enroll(server, Discover(server), server.EnrollmentCode, false);
                string token = StrictJson.String(InvitationObject(invite), "token"), pin = OfferedPin(invite);
                Check(server.EnrollmentGrantsIssued == 1 && media.Opened == 0 && sink.Events.Count == 0 && approvals == 0);
                server.Stop(); Check(server.WaitStopped(4000)); ++tlsFixtures;
                bool rejected = false;
                try { using (TlsClient replay = new TlsClient(server, pin)) { replay.Send(1, Hello(token)); replay.ReadNonHeartbeat(); } }
                catch (SocketException) { rejected = true; } catch (IOException) { rejected = true; }
                catch (System.Security.Authentication.AuthenticationException) { rejected = true; } catch (ObjectDisposedException) { rejected = true; }
                Check(rejected && !server.IsActive && server.EnrollmentCode == "" && media.Opened == 0 && sink.Events.Count == 0 && approvals == 0);
            }
        }
    }
}
