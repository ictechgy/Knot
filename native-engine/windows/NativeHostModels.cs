using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;

namespace Knot.NativePreview
{
    internal sealed class RunIdentity
    {
        internal readonly Guid Id = Guid.NewGuid();
        internal readonly string Pin;
        internal RunIdentity(string pin)
        {
            if (pin == null || pin.Length != 64) throw new ArgumentException("Invalid run certificate pin.");
            foreach (char c in pin) if (!(c >= '0' && c <= '9' || c >= 'a' && c <= 'f')) throw new ArgumentException("Invalid run certificate pin.");
            Pin = pin;
        }
    }

    internal sealed class ApprovalMetadata
    {
        internal readonly Guid RunId;
        internal readonly string ClaimedViewerLabel, ObservedRemoteIPv4;
        internal ApprovalMetadata(RunIdentity run, string claimedViewerLabel, IPAddress observedAddress)
        {
            if (observedAddress.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) throw new ProtocolException("auth");
            RunId = run.Id; ClaimedViewerLabel = claimedViewerLabel; ObservedRemoteIPv4 = observedAddress.ToString();
        }
        internal string DisplayText
        {
            get { return "Observed remote IPv4: " + ObservedRemoteIPv4 + "\r\nClaimed viewer label (UNVERIFIED): " + ClaimedViewerLabel + "\r\nThis is connection context, not a verified viewer identity. Approve within 60 seconds."; }
        }
    }

    // This same binding gate is used by the WinForms callbacks and inert tests.
    internal sealed class RunPresentation
    {
        private RunIdentity current;
        internal string Pin { get { return current == null ? "" : current.Pin; } }
        internal ApprovalMetadata Approval { get; private set; }
        internal void Bind(RunIdentity run) { current = run; Approval = null; }
        internal bool IsCurrent(RunIdentity run) { return current != null && object.ReferenceEquals(current, run); }
        internal bool PublishApproval(RunIdentity run, ApprovalMetadata metadata)
        {
            if (!IsCurrent(run) || metadata.RunId != run.Id) return false;
            Approval = metadata; return true;
        }
        internal bool Clear(RunIdentity run)
        {
            if (!IsCurrent(run)) return false;
            current = null; Approval = null; return true;
        }
    }

    internal sealed class InputRateLimiter
    {
        internal const int AveragePerSecond = 500, Burst = 1000;
        private readonly Func<long> clock;
        private readonly long frequency;
        private long last;
        private double tokens = Burst;
        internal InputRateLimiter() : this(Stopwatch.GetTimestamp, Stopwatch.Frequency) { }
        internal InputRateLimiter(Func<long> clock, long frequency)
        {
            if (clock == null || frequency <= 0) throw new ArgumentException("Invalid monotonic clock.");
            this.clock = clock; this.frequency = frequency; last = clock();
        }
        internal bool TryConsume()
        {
            long now = clock();
            if (now < last) return false;
            double elapsed = (double)now - last;
            tokens = Math.Min(Burst, tokens + elapsed * AveragePerSecond / frequency); last = now;
            if (tokens < 1) return false;
            tokens -= 1; return true;
        }
    }

    internal sealed class AdapterChoice
    {
        internal readonly IPAddress Address;
        internal readonly string FriendlyName;
        internal readonly NetworkInterfaceType Type;
        internal readonly bool HasGateway, IsVirtual, IsOverlay;
        internal AdapterChoice(IPAddress address, string friendlyName, NetworkInterfaceType type, bool hasGateway)
        {
            if (!NativeProtocol.IsPrivate(address)) throw new ArgumentException("Choose a private IPv4 address.");
            Address = address; FriendlyName = friendlyName ?? "Network adapter"; Type = type; HasGateway = hasGateway;
            byte[] b = address.GetAddressBytes(); IsOverlay = b[0] == 100 && b[1] >= 64 && b[1] <= 127;
            string lower = FriendlyName.ToLowerInvariant();
            IsVirtual = type == NetworkInterfaceType.Tunnel || lower.Contains("vethernet") || lower.Contains("hyper-v") || lower.Contains("wsl") || lower.Contains("virtual");
        }
        private int Rank
        {
            get
            {
                bool physical = Type == NetworkInterfaceType.Ethernet || Type == NetworkInterfaceType.Wireless80211;
                if (!IsOverlay && HasGateway && !IsVirtual) return physical ? 0 : 1;
                if (IsOverlay) return 2;
                if (!IsVirtual) return physical ? 3 : 4;
                return 5;
            }
        }
        internal static List<AdapterChoice> Ordered(IEnumerable<AdapterChoice> choices)
        {
            List<AdapterChoice> result = new List<AdapterChoice>(choices);
            result.Sort(delegate(AdapterChoice a, AdapterChoice b)
            {
                int rank = a.Rank.CompareTo(b.Rank); if (rank != 0) return rank;
                int name = string.Compare(a.FriendlyName, b.FriendlyName, StringComparison.OrdinalIgnoreCase); if (name != 0) return name;
                byte[] aa = a.Address.GetAddressBytes(), bb = b.Address.GetAddressBytes();
                for (int i = 0; i < aa.Length; ++i) { int part = aa[i].CompareTo(bb[i]); if (part != 0) return part; }
                return ((int)a.Type).CompareTo((int)b.Type);
            });
            return result;
        }
        public override string ToString()
        {
            return FriendlyName + " · " + Type + " · " + (IsOverlay ? "Tailscale/private overlay" : "LAN/private network") + " · " + Address + (HasGateway ? " · gateway" : " · no gateway");
        }
    }
}
