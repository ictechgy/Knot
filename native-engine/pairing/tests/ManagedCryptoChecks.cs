using System;
using System.Linq;
using System.Text;

namespace Knot.NativePreview
{
    // Separate inert entry; never calls the production Program, sockets, media
    // capture, clipboard, certificate stores or SendInput.
    internal static class NativePairingBridgeChecks
    {
        private static int checks;
        private static void Need(bool value) { ++checks; if (!value) throw new InvalidOperationException("Synthetic managed crypto check failed."); }
        private static void Reject(Action action, string code)
        {
            bool rejected = false;
            try { action(); } catch (ProtocolException e) { rejected = e.Code == code; }
            Need(rejected);
        }
        private static int Main()
        {
            try
            {
                byte[] slot = new byte[16], code = Encoding.ASCII.GetBytes("01234567");
                using (PairingCryptoSession client = PairingCryptoSession.Create(false, code, slot))
                using (PairingCryptoSession server = PairingCryptoSession.Create(true, code, slot))
                {
                    Need(client.Message.Length == 32 && server.Message.Length == 32);
                    client.Process(server.Message); server.Process(client.Message);
                    byte[] confirm = Encoding.ASCII.GetBytes("fresh synthetic confirmation");
                    byte[] wire = client.Seal(3, confirm);
                    Need(server.Open(3, wire).SequenceEqual(confirm));
                    byte[] offer = new byte[3072]; offer[0] = 0x35;
                    byte[] offered = server.Seal(4, offer);
                    Need(client.Open(4, offered).SequenceEqual(offer));
                    Reject(delegate { client.Open(4, offered); }, "protocol");
                }
                using (PairingCryptoSession client = PairingCryptoSession.Create(false, code, slot))
                using (PairingCryptoSession server = PairingCryptoSession.Create(true, Encoding.ASCII.GetBytes("01234568"), slot))
                {
                    client.Process(server.Message); server.Process(client.Message);
                    byte[] wire = client.Seal(3, Encoding.ASCII.GetBytes("fresh synthetic proof"));
                    Reject(delegate { server.Open(3, wire); }, "auth");
                    Reject(delegate { server.Process(client.Message); }, "protocol");
                    client.Dispose(); client.Dispose();
                    Reject(delegate { client.Process(new byte[32]); }, "protocol");
                }
                Console.WriteLine("{\"schema\":1,\"status\":\"passed\",\"freshSyntheticOnly\":true,\"managedBridge\":true,\"networkInvoked\":false,\"captureInvoked\":false,\"actualInputInvoked\":false,\"checks\":" + checks + "}");
                return 0;
            }
            catch { Console.Error.WriteLine("Synthetic managed crypto bridge failed."); return 1; }
        }
    }
}
