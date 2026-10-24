#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Import is inert. The explicit operation probes only the fixed local TCP port;
# it does not authenticate Sunshine, send HTTP/TLS data or change a service.
$source = @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace Knot.Setup
{
    internal interface ILocalPortAttempt : IDisposable
    {
        Task ConnectAsync();
    }

    internal sealed class LocalPortAttempt : ILocalPortAttempt
    {
        private readonly TcpClient client = new TcpClient(AddressFamily.InterNetwork);
        public Task ConnectAsync() { return client.ConnectAsync(IPAddress.Loopback, 47990); }
        public void Dispose() { client.Close(); }
    }

    internal static class LocalPortWait
    {
        // Only the attempt factory is injected in offline fixtures. Production
        // never accepts an address, port, HTTP request or certificate callback.
        internal static async Task<bool> WaitAsync(CancellationToken cancel, int deadlineMs,
            int attemptMs, int intervalMs, Func<ILocalPortAttempt> create)
        {
            if (deadlineMs < 1 || deadlineMs > 15000 || attemptMs < 1 || attemptMs > 2000 ||
                intervalMs < 1 || intervalMs > 1000 || create == null)
                throw new ArgumentException("Invalid local port check limits.");
            using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancel))
            {
                deadline.CancelAfter(deadlineMs);
                try
                {
                    while (true)
                    {
                        deadline.Token.ThrowIfCancellationRequested();
                        if (await TryAsync(create, deadline.Token, attemptMs).ConfigureAwait(false))
                        {
                            deadline.Token.ThrowIfCancellationRequested();
                            return true;
                        }
                        await Task.Delay(intervalMs, deadline.Token).ConfigureAwait(false);
                    }
                }
                catch (OperationCanceledException)
                {
                    cancel.ThrowIfCancellationRequested();
                    if (deadline.IsCancellationRequested) return false;
                    throw;
                }
            }
        }

        private static async Task<bool> TryAsync(Func<ILocalPortAttempt> create,
            CancellationToken deadline, int attemptMs)
        {
            using (var attempt = create())
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(deadline))
            {
                timeout.CancelAfter(attemptMs);
                var stopped = new TaskCompletionSource<bool>();
                using (timeout.Token.Register(() => stopped.TrySetResult(true)))
                {
                    Task connect = null;
                    try
                    {
                        timeout.Token.ThrowIfCancellationRequested();
                        connect = attempt.ConnectAsync();
                        if (connect == null) throw new InvalidOperationException("Missing local port task.");
                        if (await Task.WhenAny(connect, stopped.Task).ConfigureAwait(false) != connect)
                            timeout.Token.ThrowIfCancellationRequested();
                        await connect.ConfigureAwait(false);
                        timeout.Token.ThrowIfCancellationRequested();
                        return true;
                    }
                    catch (OperationCanceledException)
                    {
                        deadline.ThrowIfCancellationRequested();
                        return false;
                    }
                    catch (SocketException) { deadline.ThrowIfCancellationRequested(); return false; }
                    catch (ObjectDisposedException) { deadline.ThrowIfCancellationRequested(); return false; }
                    finally
                    {
                        // Dispose closes the socket even if the OS connect has
                        // not completed. Observe a late fault without waiting on
                        // an uncooperative transport beyond the overall budget.
                        if (connect != null) ObserveLateFailure(connect);
                    }
                }
            }
        }

        private static void ObserveLateFailure(Task connect)
        {
            connect.ContinueWith(task => { var ignored = task.Exception; },
                CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted |
                TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        }
    }

    public sealed class LocalPortProbe : IDisposable
    {
        private readonly CancellationTokenSource cancellation = new CancellationTokenSource();
        public Task<bool> Completion { get; private set; }
        public LocalPortProbe(int deadlineMs)
        {
            if (deadlineMs < 1 || deadlineMs > 15000) throw new ArgumentOutOfRangeException("deadlineMs");
            // The fixed-address ConnectAsync does not block on DNS or a socket
            // response. Start the deadline now, rather than after a worker is scheduled.
            Completion = LocalPortWait.WaitAsync(cancellation.Token, deadlineMs,
                750, 250, () => new LocalPortAttempt());
        }
        public void Cancel() { cancellation.Cancel(); }
        public void Dispose()
        {
            cancellation.Cancel();
            if (!Completion.IsCompleted) throw new InvalidOperationException("Local port check is still stopping.");
            cancellation.Dispose();
        }
    }
}
'@
if (-not ('Knot.Setup.LocalPortProbe' -as [type])) { Add-Type -TypeDefinition $source }
function Start-SetupLocalPortProbe([ValidateRange(1,15000)][int] $WaitMilliseconds=2000) {
    return [Knot.Setup.LocalPortProbe]::new($WaitMilliseconds)
}
Export-ModuleMember -Function Start-SetupLocalPortProbe
