#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compile actual Windows client sources and execute only offline pure checks.

The temporary .NET 8 runner loads the Framework assembly without calling any app
entrypoint. Windows forms, Win32, child processes, network and user preferences
are never invoked. Framework references and compilers are supplied explicitly.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import tempfile

from build_snapshot import source_snapshot
from update_windows import configuration_source
from reverse_client import client_sources, generate_engine_pin, generate_qr_loader
from reverse_qr import compile_decoder

ROOT = Path(__file__).resolve().parent.parent

RUNNER = r'''using System;
using System.Reflection;
using System.Text.Json;
internal static class OfflineRunner {
    private static int Invoke(Assembly assembly, string name) {
        var type = assembly.GetType(name, true)!;
        var method = type.GetMethod("Run", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic)!;
        return (int)method.Invoke(null, null)!;
    }
    static void Main(string[] args) {
        if (args.Length != 1) throw new ArgumentException("Expected fixture assembly only");
        Assembly assembly = Assembly.LoadFile(System.IO.Path.GetFullPath(args[0]));
        int client = Invoke(assembly, "DeskBridge.Reverse.ReverseClientTests");
        int discovery = Invoke(assembly, "ReverseDiscoveryChecks");
        Console.WriteLine(JsonSerializer.Serialize(new { status = "passed", clientChecks = client,
            discoveryChecks = discovery, freshSyntheticOnly = true, windowsRuntimeTested = false }));
    }
}'''


def run(dotnet, compiler, references):
    snapshot = source_snapshot(ROOT)
    references = Path(references).resolve()
    refs = [references / (name + ".dll") for name in (
        "mscorlib", "System", "System.Core", "System.Drawing", "System.Windows.Forms",
        "System.IO.Compression", "System.IO.Compression.FileSystem")]
    if any(not p.is_file() for p in refs):
        raise ValueError("Supply .NET Framework 4.8 reference assemblies for reverse client checks")
    sources = [*client_sources(ROOT), ROOT / "client/windows/Tests.cs",
               ROOT / "scripts/tests/ReverseDiscoveryChecks.cs"]
    source_hashes = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    invocations = []
    with tempfile.TemporaryDirectory(prefix="deskbridge-reverse-client-checks-") as temporary:
        temporary = Path(temporary)
        env = dict(os.environ, DOTNET_CLI_HOME=str(temporary / "cli"), NUGET_PACKAGES=str(temporary / "packages"),
                   DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1", DOTNET_NOLOGO="1")
        prefix = [str(dotnet), str(compiler)] if str(compiler).lower().endswith(".dll") else [str(compiler)]
        decoder = temporary / "DeskBridge.QrDecoder.dll"
        # compile_decoder verifies all pinned upstream source; output is a fresh fixture.
        decoder_record = compile_decoder(ROOT, prefix, references, decoder)
        pin = temporary / "EnginePin.cs"
        pin_record = generate_engine_pin(ROOT, pin)
        loader = temporary / "ReverseQrLibrary.cs"
        generate_qr_loader(decoder_record["sha256"], loader)
        updater_config = temporary / "KnotUpdateConfiguration.cs"
        updater_config.write_text(configuration_source(ROOT, 'a' * 64, 'b' * 64))
        assembly = temporary / "ReverseClientChecks.dll"

        def invoke(label, argv, timeout=180):
            result = subprocess.run(list(map(str, argv)), cwd=temporary, env=env, capture_output=True, timeout=timeout)
            record = {"label": label, "argv": list(map(str, argv)), "exitCode": result.returncode,
                      "stdout": result.stdout.decode(errors="replace"), "stderr": result.stderr.decode(errors="replace")}
            invocations.append(record)
            if result.returncode:
                raise RuntimeError(label + " failed:\n" + record["stdout"] + record["stderr"])
            return record

        invoke("compile-actual-reverse-client", prefix + [
            "-nologo", "-target:library", "-platform:anycpu", "-langversion:5", "-nostdlib+", "-optimize+", "-deterministic+",
            "-out:" + str(assembly), *["-r:" + str(p) for p in refs], "-r:" + str(decoder),
            "-resource:" + str(decoder) + "," + decoder_record["resourceName"],
            *map(str, sources), str(pin), str(loader), str(updater_config), str(ROOT / "packaging/windows/KnotUpdateHandoff.cs")])
        runner = temporary / "runner"
        runner.mkdir()
        (runner / "Runner.csproj").write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>'
            '<OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><Nullable>enable</Nullable>'
            '<UseSharedCompilation>false</UseSharedCompilation></PropertyGroup></Project>')
        (runner / "Runner.cs").write_text(RUNNER)
        config = temporary / "NuGet.Config"
        config.write_text('<configuration><packageSources><clear /></packageSources></configuration>')
        invoke("restore-offline-runner", [dotnet, "restore", runner / "Runner.csproj", "--configfile", config])
        invoke("compile-offline-runner", [dotnet, "build", runner / "Runner.csproj", "--no-restore", "-c", "Release", "--nologo", "--verbosity", "quiet"])
        result = invoke("execute-pure-reverse-checks", [dotnet, runner / "bin/Release/net8.0/Runner.dll", assembly], timeout=60)
        lines = result["stdout"].strip().splitlines()
        if not lines:
            raise ValueError("Reverse client checker returned no terminal result")
        terminal = json.loads(lines[-1])
        if (terminal.get("status") != "passed" or type(terminal.get("clientChecks")) is not int or terminal["clientChecks"] < 124 or
                type(terminal.get("discoveryChecks")) is not int or terminal["discoveryChecks"] < 195 or
                terminal.get("freshSyntheticOnly") is not True or terminal.get("windowsRuntimeTested") is not False):
            raise ValueError("Reverse client/discovery checker returned incomplete results")
        record = {"schema": 1, "status": "passed", "suites": ["reverse-client", "reverse-discovery"],
                  "counts": {"reverse-client": terminal["clientChecks"], "reverse-discovery": terminal["discoveryChecks"]},
                  "sourceManifest": snapshot, "sourceSha256": source_hashes, "generatedEnginePin": pin_record,
                  "qrDecoder": decoder_record, "compiledAssemblySha256": hashlib.sha256(assembly.read_bytes()).hexdigest(),
                  "runnerSha256": hashlib.sha256(RUNNER.encode()).hexdigest(), "invocations": invocations,
                  "freshSyntheticOnly": True, "windowsRuntimeTested": False,
                  "windowsImageCodecRuntimeTested": False}
    if source_snapshot(ROOT) != snapshot:
        raise ValueError("Source changed during reverse client checks; rerun")
    return record


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dotnet", required=True, help="Explicit .NET 8 SDK executable")
    parser.add_argument("--compiler", required=True, help="csc.exe or SDK Roslyn csc.dll")
    parser.add_argument("--references", required=True, help=".NET Framework 4.8 reference directory")
    args = parser.parse_args()
    print(json.dumps(run(args.dotnet, args.compiler, args.references), indent=2))
