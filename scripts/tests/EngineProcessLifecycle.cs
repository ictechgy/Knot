// SPDX-License-Identifier: GPL-3.0-only
// Actual EngineProcess owner + fresh inert executables only: no Moonlight, GUI, network, settings or accounts.
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace DeskBridge.Reverse
{
    public static class EngineProcessLifecycle
    {
        private static int checks;
        private static void Check(bool condition, string label) { checks++; if (!condition) throw new Exception("FAIL " + label); }
        private static string Executable { get { return System.Reflection.Assembly.GetExecutingAssembly().Location; } }
        public static int Main(string[] args)
        {
            try
            {
                if (args.Length == 2 && args[0].StartsWith("--", StringComparison.Ordinal)) return Child(args[0], args[1]);
                if (args.Length != 1) throw new ArgumentException("Supply one fresh fixture directory");
                Run(args[0]);
                Console.WriteLine("{\"status\":\"passed\",\"checks\":" + checks + ",\"freshSyntheticOnly\":true,\"windowsJobRuntimeTested\":true}");
                return 0;
            }
            catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
        }
        private static int Child(string mode, string directory)
        {
            if (mode == "--foreign") { Publish(directory, "foreign", "ready"); Thread.Sleep(30000); return 0; }
            bool inJob;
            if (!IsProcessInJob(GetCurrentProcess(), IntPtr.Zero, out inJob) || !inJob) return 82;
            if (mode == "--descendant")
            { Publish(directory, "descendant", Process.GetCurrentProcess().Id.ToString()); Thread.Sleep(30000); return 0; }
            if (mode != "--primary" && mode != "--finite") return 83;
            if (Environment.CurrentDirectory != directory || Environment.GetEnvironmentVariable("KNOT_SYNTHETIC_UNSAFE") != null ||
                Environment.GetEnvironmentVariable("TEMP") != Path.Combine(directory, "temp") ||
                Environment.GetEnvironmentVariable("QML_DISABLE_DISK_CACHE") != "1") return 84;
            Publish(directory, "primary", Process.GetCurrentProcess().Id.ToString());
            using (Process descendant = Process.Start(StartInfo("--descendant", directory)))
            {
                WaitForFile(Path.Combine(directory, "descendant"));
                if (mode == "--finite") return 0;
                Thread.Sleep(30000);
            }
            return 0;
        }
        private static void Publish(string directory, string name, string text)
        {
            string path = Path.Combine(directory, name);
            File.WriteAllText(path + ".new", text); File.Move(path + ".new", path);
        }
        private static ProcessStartInfo StartInfo(string mode, string directory)
        {
            var start = new ProcessStartInfo(Executable, EngineCommands.Join(new[] { mode, directory }));
            start.UseShellExecute = false; start.CreateNoWindow = true; start.WorkingDirectory = directory;
            EngineProcess.CleanEnvironment(start, Path.GetDirectoryName(Executable), directory);
            return start;
        }
        private static void WaitForFile(string path)
        {
            var timer = Stopwatch.StartNew();
            while (!File.Exists(path)) { if (timer.ElapsedMilliseconds > 10000) throw new TimeoutException("Synthetic marker timeout"); Thread.Sleep(10); }
        }
        private static Process Capture(string marker)
        {
            WaitForFile(marker);
            // Marker publication may precede the final buffered flush by a few instructions.
            var timer = Stopwatch.StartNew(); int pid;
            while (!Int32.TryParse(File.ReadAllText(marker), out pid))
            { if (timer.ElapsedMilliseconds > 5000) throw new TimeoutException("Synthetic PID timeout"); Thread.Sleep(10); }
            var child = Process.GetProcessById(pid); var ignored = child.Handle; return child;
        }
        private static void Await(Task<int> run, bool cancelled)
        {
            bool wasCancelled = false;
            try { Check(run.GetAwaiter().GetResult() == 0 || !cancelled, "completed child exit"); }
            catch (OperationCanceledException) { wasCancelled = true; }
            Check(wasCancelled == cancelled, "cancellation result");
        }
        private static void Run(string root)
        {
            string profileRoot = Path.Combine(root, "profile-case");
            PrivateFiles.CreatePrivate(profileRoot);
            using (ProfileLease first = EngineProfile.Prepare(profileRoot, "192.168.1.20"))
            {
                bool refused = false;
                try { using (ProfileLease second = EngineProfile.Prepare(profileRoot, "192.168.1.20")) { } }
                catch (ReverseUserException error) { refused = error.Message == ReverseErrors.Fixed(ReverseFailure.ProfilePolicy); }
                Check(refused, "an occupied profile gives local profile guidance");
                Check(Directory.Exists(first.Path), "profile contention preserves the first identity");
            }
            using (ProfileLease reopened = EngineProfile.Prepare(profileRoot, "192.168.1.20"))
                Check(Directory.Exists(reopened.Path), "a released profile can be reopened");
            string foreignDirectory = Path.Combine(root, "foreign-case"); Directory.CreateDirectory(foreignDirectory);
            using (Process foreign = Process.Start(StartInfo("--foreign", foreignDirectory)))
            {
                try
                {
                    WaitForFile(Path.Combine(foreignDirectory, "foreign"));
                    Environment.SetEnvironmentVariable("KNOT_SYNTHETIC_UNSAFE", "must-not-inherit");
                    foreach (string mode in new[] { "cancel", "stop", "dispose", "finite" })
                    {
                        string directory = Path.Combine(root, mode); Directory.CreateDirectory(directory);
                        using (var cancel = new CancellationTokenSource())
                        using (var owner = new EngineProcess())
                        {
                            Task<int> run = owner.RunExecutableAsync(Executable, Path.GetDirectoryName(Executable), directory,
                                new[] { mode == "finite" ? "--finite" : "--primary", directory }, cancel.Token);
                            Process primary = null, descendant = null;
                            try
                            {
                                // For finite mode, capture descendant first; the primary exits after its marker exists.
                                if (mode != "finite") primary = Capture(Path.Combine(directory, "primary"));
                                if (mode == "finite")
                                {
                                    Await(run, false);
                                    WaitForFile(Path.Combine(directory, "descendant"));
                                    int pid = Int32.Parse(File.ReadAllText(Path.Combine(directory, "descendant")));
                                    try { descendant = Process.GetProcessById(pid); Check(descendant.WaitForExit(5000), "finite parent exit kills descendant"); }
                                    catch (ArgumentException) { Check(true, "finite descendant already reaped"); }
                                }
                                else
                                {
                                    descendant = Capture(Path.Combine(directory, "descendant"));
                                    if (mode == "cancel") cancel.Cancel();
                                    else if (mode == "dispose") owner.Dispose();
                                    else owner.Stop();
                                    Await(run, mode == "cancel");
                                    Check(primary.WaitForExit(5000), "primary terminated on " + mode);
                                    Check(descendant.WaitForExit(5000), "descendant terminated on " + mode);
                                }
                                Check(!foreign.HasExited, "foreign process survives " + mode);
                            }
                            finally
                            {
                                owner.Stop();
                                try { run.GetAwaiter().GetResult(); } catch (OperationCanceledException) { }
                                if (primary != null) primary.Dispose(); if (descendant != null) descendant.Dispose();
                            }
                        }
                    }
                    foreach (string failure in new[] { "assign", "resume", "cancel-before-resume", "inspect-before-resume" })
                    {
                        string directory = Path.Combine(root, failure); Directory.CreateDirectory(directory);
                        IntPtr observed = IntPtr.Zero, expectedJob = IntPtr.Zero;
                        using (var cancel = new CancellationTokenSource())
                        using (var owner = new EngineProcess((job, process) =>
                        {
                            expectedJob = job;
                            if (!DuplicateHandle(GetCurrentProcess(), process, GetCurrentProcess(), out observed, 0, false, 2)) throw new Exception("Duplicate synthetic handle");
                            Check(!File.Exists(Path.Combine(directory, "primary")), "primary has not executed before assignment");
                            if (failure == "assign") return false;
                            bool assigned = AssignProcessToJobObject(job, process);
                            if (failure == "cancel-before-resume") cancel.Cancel();
                            return assigned;
                        }, thread =>
                        {
                            bool inExpectedJob;
                            Check(IsProcessInJob(observed, expectedJob, out inExpectedJob) && inExpectedJob, "specific owned job contains primary before resume");
                            Check(!File.Exists(Path.Combine(directory, "primary")), "primary remains suspended until containment");
                            if (failure == "resume") return UInt32.MaxValue;
                            return ResumeThread(thread);
                        }))
                        {
                            try
                            {
                                Task<int> run = owner.RunExecutableAsync(Executable, Path.GetDirectoryName(Executable), directory,
                                    new[] { "--primary", directory }, cancel.Token);
                                if (failure == "inspect-before-resume") { WaitForFile(Path.Combine(directory, "primary")); owner.Stop(); Await(run, false); }
                                else
                                {
                                    bool failed = false;
                                    try { run.GetAwaiter().GetResult(); } catch (ReverseUserException) { failed = true; } catch (OperationCanceledException) { failed = true; }
                                    Check(failed, failure + " fails closed");
                                    Check(!File.Exists(Path.Combine(directory, "primary")), failure + " never executes primary code");
                                }
                                Check(observed != IntPtr.Zero && WaitForSingleObject(observed, 5000) == 0, "failed or stopped primary is reaped");
                                Check(!foreign.HasExited, "foreign survives startup path");
                            }
                            finally { if (observed != IntPtr.Zero) CloseHandle(observed); }
                        }
                    }
                }
                finally { Environment.SetEnvironmentVariable("KNOT_SYNTHETIC_UNSAFE", null); if (!foreign.HasExited) foreign.Kill(); foreign.WaitForExit(); }
            }
        }
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsProcessInJob(IntPtr process, IntPtr job, [MarshalAs(UnmanagedType.Bool)] out bool result);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DuplicateHandle(IntPtr sourceProcess, IntPtr source, IntPtr targetProcess, out IntPtr target, uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint options);
    }
}
