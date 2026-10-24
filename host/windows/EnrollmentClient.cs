// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Knot.Enrollment {
    public sealed class Link {
        public readonly string Address, SessionID, Pin, Capability;
        public readonly int Port;
        private Link(string address, int port, string id, string pin, string capability) {
            Address=address; Port=port; SessionID=id; Pin=pin; Capability=capability;
        }
        public static Link Parse(string text) {
            if (text == null || text.Length > 512) throw Invalid();
            var match=Regex.Match(text, @"\Aknot-enroll://([0-9.]+):([0-9]{4,5})/([0-9a-f-]{36})#([0-9a-f]{64})\.([0-9a-f]{64})\z", RegexOptions.CultureInvariant);
            IPAddress ip; int port; Guid id;
            if (!match.Success || !IPAddress.TryParse(match.Groups[1].Value,out ip) ||
                ip.AddressFamily != AddressFamily.InterNetwork || ip.ToString() != match.Groups[1].Value ||
                !Int32.TryParse(match.Groups[2].Value,out port) || port < 1024 || port > 65535 ||
                port.ToString(System.Globalization.CultureInfo.InvariantCulture) != match.Groups[2].Value ||
                !Guid.TryParseExact(match.Groups[3].Value,"D",out id) || id.ToString("D") != match.Groups[3].Value) throw Invalid();
            if (!PrivateIPv4(ip)) throw Invalid();
            return new Link(ip.ToString(),port,id.ToString("D"),match.Groups[4].Value,match.Groups[5].Value);
        }
        internal static bool PrivateIPv4(IPAddress address) {
            if (address == null || address.AddressFamily != AddressFamily.InterNetwork) return false;
            var b=address.GetAddressBytes();
            return b[0]==10 || (b[0]==172 && b[1]>=16 && b[1]<=31) || (b[0]==192 && b[1]==168) || (b[0]==100 && b[1]>=64 && b[1]<=127);
        }
        internal static string LocalAddressFromEndpoint(EndPoint endpoint) {
            var value=endpoint as IPEndPoint;
            if (value==null || !PrivateIPv4(value.Address)) throw Invalid();
            return value.Address.ToString();
        }
        internal static Exception Invalid() { return new InvalidOperationException("Automatic file setup failed. Start a new setup connection on the Mac; existing settings are retained."); }
        internal static bool MatchesPin(byte[] certificate, string expected) {
            if (certificate == null || certificate.Length == 0 || expected == null || expected.Length != 64) return false;
            byte[] digest;
            using (var hash=SHA256.Create()) digest=hash.ComputeHash(certificate);
            string actual=BitConverter.ToString(digest).Replace("-","").ToLowerInvariant();
            int difference=0;
            for (int i=0;i<64;i++) difference |= actual[i] ^ expected[i];
            return difference==0;
        }
    }
    internal static class Frames {
        internal const int Maximum=16384;
        internal static async Task<byte[]> ReadAsync(Stream stream,CancellationToken cancel) {
            var header=await ExactAsync(stream,4,cancel).ConfigureAwait(false);
            uint length=((uint)header[0]<<24)|((uint)header[1]<<16)|((uint)header[2]<<8)|header[3];
            if (length==0 || length>Maximum) throw Link.Invalid();
            return await ExactAsync(stream,(int)length,cancel).ConfigureAwait(false);
        }
        private static async Task<byte[]> ExactAsync(Stream stream,int length,CancellationToken cancel) {
            var data=new byte[length]; int offset=0;
            while (offset<length) {
                cancel.ThrowIfCancellationRequested();
                int count=await stream.ReadAsync(data,offset,length-offset,cancel).ConfigureAwait(false);
                if (count<=0) throw Link.Invalid();
                offset+=count;
            }
            return data;
        }
        internal static async Task WriteAsync(Stream stream,byte[] data,CancellationToken cancel) {
            if (data==null || data.Length==0 || data.Length>Maximum) throw Link.Invalid();
            int length=data.Length;
            var header=new byte[]{(byte)(length>>24),(byte)(length>>16),(byte)(length>>8),(byte)length};
            await stream.WriteAsync(header,0,4,cancel).ConfigureAwait(false);
            await stream.WriteAsync(data,0,length,cancel).ConfigureAwait(false);
            await stream.FlushAsync(cancel).ConfigureAwait(false);
        }
    }
    /// Monotonic admission/reply state also checks expiry synchronously, so a
    /// delayed CancellationTokenSource timer cannot renew an expired session.
    internal sealed class ReplyWindow {
        private double expires, observed;
        private bool authorized, closed;
        internal ReplyWindow(double now) {
            if (Double.IsNaN(now) || Double.IsInfinity(now) || now<0) throw Link.Invalid();
            observed=now; expires=now+120;
        }
        private bool ActiveLocked(double now) {
            if (closed) return false;
            if (Double.IsNaN(now) || Double.IsInfinity(now) || now<observed || now>=expires) { closed=true; return false; }
            observed=now; return true;
        }
        internal bool Active(double now) { return ActiveLocked(now); }
        internal bool CanReply(double now) { return ActiveLocked(now) && authorized; }
        internal void Authorize(double now) {
            if (!ActiveLocked(now) || authorized) throw Link.Invalid();
            authorized=true; expires=now+600;
        }
        internal void Cancel() { closed=true; }
    }
    /// One outbound TLS connection, private address only, exact temporary-cert pin.
    /// No global certificate callback, proxy, listener, shell URL, or trust store.
    public sealed class Client : IDisposable {
        private readonly TcpClient tcp=new TcpClient(AddressFamily.InterNetwork);
        private readonly CancellationTokenSource deadline=new CancellationTokenSource();
        private readonly ReplyWindow window=new ReplyWindow(MonotonicNow);
        private readonly CancellationTokenRegistration abort;
        private SslStream tls;
        private int replied, disposed;
        public Link Connection { get; private set; }
        public Task<byte[]> Request { get; private set; }
        public string LocalAddress { get; private set; }
        private static double MonotonicNow { get { return Stopwatch.GetTimestamp()/(double)Stopwatch.Frequency; } }
        // Sample the clock inside the same lock as the state transition: racing
        // UI/task calls must not present out-of-order timestamp observations.
        public bool Active { get { lock(window) { return !deadline.IsCancellationRequested && Volatile.Read(ref disposed)==0 && window.Active(MonotonicNow); } } }
        private bool CanReply { get { lock(window) { return window.CanReply(MonotonicNow); } } }
        public Client(string text) {
            Connection=Link.Parse(text);
            deadline.CancelAfter(120000);
            abort=deadline.Token.Register(delegate { tcp.Close(); });
            Request=Task.Run(() => FetchAsync());
        }
        private async Task<byte[]> FetchAsync() {
            try {
                await tcp.ConnectAsync(IPAddress.Parse(Connection.Address),Connection.Port).ConfigureAwait(false);
                deadline.Token.ThrowIfCancellationRequested();
                LocalAddress=Link.LocalAddressFromEndpoint(tcp.Client.LocalEndPoint);
                tls=new SslStream(tcp.GetStream(),false,delegate(object sender,X509Certificate certificate,X509Chain chain,SslPolicyErrors errors) {
                    return certificate != null && Link.MatchesPin(certificate.GetRawCertData(),Connection.Pin);
                });
                await tls.AuthenticateAsClientAsync("knot-enrollment.invalid",null,SslProtocols.Tls12,false).ConfigureAwait(false);
                deadline.Token.ThrowIfCancellationRequested();
                string auth="{\"kind\":\"knot.enroll.auth\",\"version\":1,\"sessionID\":\""+Connection.SessionID+"\",\"capability\":\""+Connection.Capability+"\"}";
                await Frames.WriteAsync(tls,Encoding.UTF8.GetBytes(auth),deadline.Token).ConfigureAwait(false);
                return await Frames.ReadAsync(tls,deadline.Token).ConfigureAwait(false);
            } catch { Cancel(); throw Link.Invalid(); }
        }
        public static string SelectLocalAddress(string localAddress,string[] available) {
            IPAddress value;
            if (!IPAddress.TryParse(localAddress,out value) || value.ToString()!=localAddress || !Link.PrivateIPv4(value) || available==null) throw Link.Invalid();
            foreach (string candidate in available) if (String.Equals(localAddress,candidate,StringComparison.Ordinal)) return localAddress;
            throw Link.Invalid();
        }
        // Called only after the UI has validated the complete canonical request
        // and selected the actual local peer address. Fetching bytes alone must
        // not extend the initial connection/authentication budget.
        public void AuthorizeReply(string requestID,string[] allowedClientAddresses) {
            if (!Request.IsCompleted || Request.IsFaulted || Request.IsCanceled || !Active ||
                !String.Equals(requestID,Connection.SessionID,StringComparison.Ordinal) || allowedClientAddresses==null) throw Link.Invalid();
            bool allowed=false;
            foreach (string address in allowedClientAddresses) if (String.Equals(address,Connection.Address,StringComparison.Ordinal)) allowed=true;
            if (!allowed) throw Link.Invalid();
            lock(window) { window.Authorize(MonotonicNow); }
            deadline.Token.ThrowIfCancellationRequested();
            deadline.CancelAfter(600000);
            deadline.Token.ThrowIfCancellationRequested();
        }
        public Task SendReplyAsync(string reply) {
            if (reply==null || !Request.IsCompleted || Request.IsFaulted || Request.IsCanceled || !Active || !CanReply || Interlocked.Exchange(ref replied,1)!=0) throw Link.Invalid();
            return Task.Run(async delegate {
                try {
                    await Frames.WriteAsync(tls,new UTF8Encoding(false,true).GetBytes(reply),deadline.Token).ConfigureAwait(false);
                    var ack=await Frames.ReadAsync(tls,deadline.Token).ConfigureAwait(false);
                    if (Encoding.UTF8.GetString(ack)!="received") throw Link.Invalid();
                } catch { throw Link.Invalid(); }
                finally { Cancel(); }
            });
        }
        public void Cancel() { if (Volatile.Read(ref disposed)==0) { lock(window) { window.Cancel(); } deadline.Cancel(); tcp.Close(); } }
        public void Dispose() {
            if (Interlocked.Exchange(ref disposed,1)!=0) return;
            lock(window) { window.Cancel(); } deadline.Cancel(); tcp.Close(); abort.Dispose();
            // Cancellation can race an awaiting TLS read. The stream is owned by
            // the closed TcpClient; do not dispose the CTS while tasks use it.
        }
    }
}
