using System;
using System.IO;
using System.Runtime.InteropServices;

namespace Knot.NativePreview
{
    // One short-code attempt owns one context/module reference. Never resolve an
    // ambient crypto DLL, and never reuse a failed native context.
    internal sealed class PairingCryptoSession : IDisposable
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryEx(string file, IntPtr reserved, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32.dll")] private static extern bool FreeLibrary(IntPtr module);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate uint VersionDelegate();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate IntPtr CreateDelegate(uint role,
            [In] byte[] password, uint passwordLength, [In] byte[] slot, uint slotLength);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int MessageDelegate(IntPtr value,
            [Out] byte[] output, uint capacity, out uint written);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int ProcessDelegate(IntPtr value,
            [In] byte[] peer, uint length);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int CryptDelegate(IntPtr value,
            byte kind, [In] byte[] input, uint length, [Out] byte[] output, uint capacity, out uint written);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void CloseDelegate(IntPtr value);

        private readonly object gate = new object();
        private IntPtr module, context;
        private MessageDelegate message;
        private ProcessDelegate process;
        private CryptDelegate seal, open;
        private CloseDelegate close;
        private byte[] publicMessage;

        private PairingCryptoSession(bool server, byte[] password, byte[] slot)
        {
            if (password == null || password.Length != 8 || slot == null || slot.Length != 16)
                throw new ProtocolException("protocol");
            foreach (byte digit in password)
                if (digit < (byte)'0' || digit > (byte)'9') throw new ProtocolException("protocol");
            try
            {
                string path = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "KnotNativePairing.dll"));
                module = LoadLibraryEx(path, IntPtr.Zero, 0x00000100 | 0x00000800);
                if (module == IntPtr.Zero || Export<VersionDelegate>("kn_pair_abi_version")() != 2)
                    throw new ProtocolException("protocol");
                CreateDelegate create = Export<CreateDelegate>("kn_pair_create");
                message = Export<MessageDelegate>("kn_pair_message");
                process = Export<ProcessDelegate>("kn_pair_process");
                seal = Export<CryptDelegate>("kn_pair_seal");
                open = Export<CryptDelegate>("kn_pair_open");
                close = Export<CloseDelegate>("kn_pair_close");
                context = create(server ? 1u : 0u, password, 8, slot, 16);
                if (context == IntPtr.Zero) throw new ProtocolException("auth");
                publicMessage = new byte[32]; uint n;
                if (message(context, publicMessage, 32, out n) != 0 || n != 32)
                    throw new ProtocolException("protocol");
            }
            catch { Dispose(); throw; }
        }
        private T Export<T>(string name) where T : class
        {
            IntPtr address = GetProcAddress(module, name);
            if (address == IntPtr.Zero) throw new ProtocolException("protocol");
            return Marshal.GetDelegateForFunctionPointer(address, typeof(T)) as T;
        }
        internal static PairingCryptoSession Create(bool server, byte[] password, byte[] slot)
        {
            return new PairingCryptoSession(server, password, slot);
        }
        internal byte[] Message
        {
            get { lock (gate) { RequireOpen(); return (byte[])publicMessage.Clone(); } }
        }
        private void RequireOpen()
        {
            if (context == IntPtr.Zero) throw new ProtocolException("protocol");
        }
        private void Failed(int status)
        {
            Dispose();
            throw new ProtocolException(status == -2 ? "auth" : "protocol");
        }
        internal void Process(byte[] peer)
        {
            lock (gate)
            {
                RequireOpen();
                if (peer == null || peer.Length != 32) Failed(-1);
                int status = process(context, peer, 32);
                if (status != 0) Failed(status);
            }
        }
        internal byte[] Seal(byte kind, byte[] plaintext) { return Crypt(true, kind, plaintext); }
        internal byte[] Open(byte kind, byte[] sealedBytes) { return Crypt(false, kind, sealedBytes); }
        private byte[] Crypt(bool encrypt, byte kind, byte[] input)
        {
            lock (gate)
            {
                RequireOpen();
                int maximum = kind == 3 ? 484 : kind == 4 ? 3072 : 0;
                if (input == null || maximum == 0 || (encrypt ? input.Length < 1 || input.Length > maximum :
                    input.Length < 29 || input.Length > maximum + 28)) Failed(-1);
                int expected = encrypt ? input.Length + 28 : input.Length - 28;
                byte[] output = new byte[expected]; uint n;
                int status = (encrypt ? seal : open)(context, kind, input, (uint)input.Length,
                    output, (uint)output.Length, out n);
                if (status != 0 || n != output.Length)
                {
                    Array.Clear(output, 0, output.Length); Failed(status == 0 ? -1 : status);
                }
                return output;
            }
        }
        public void Dispose()
        {
            lock (gate)
            {
                if (context != IntPtr.Zero) { close(context); context = IntPtr.Zero; }
                if (module != IntPtr.Zero) { FreeLibrary(module); module = IntPtr.Zero; }
            }
            GC.SuppressFinalize(this);
        }
        ~PairingCryptoSession() { Dispose(); }
    }
}
