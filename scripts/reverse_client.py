# SPDX-License-Identifier: GPL-3.0-only
"""Offline generation of the Windows reverse client's trusted engine inventory."""
from pathlib import Path, PurePosixPath
import hashlib
import json
import re


def engine_inputs(root):
    directory = Path(root) / "client/windows"
    pin = json.loads((directory / "MoonlightDependency.json").read_text())
    files = json.loads((directory / "MoonlightFiles.json").read_text())
    version = pin.get("version", "")
    if (pin.get("schema") != 1 or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
            or pin.get("url") != "https://github.com/moonlight-stream/moonlight-qt/releases/download/v" + version + "/MoonlightPortable-x64-" + version + ".zip"
            or not re.fullmatch(r"[0-9a-f]{64}", pin.get("sha256", ""))
            or type(pin.get("bytes")) is not int or not 1 <= pin["bytes"] <= 128 * 1024 * 1024
            or pin.get("runtimeManifest") != "MoonlightFiles.json"
            or not re.fullmatch(r"[0-9a-f]{40}", pin.get("releaseCommit", ""))):
        raise ValueError("Invalid pinned Moonlight release")
    source = pin.get("source", {})
    if (source.get("url") != "https://github.com/moonlight-stream/moonlight-qt/releases/download/v" + version + "/MoonlightSrc-" + version + ".tar.gz"
            or not re.fullmatch(r"[0-9a-f]{64}", source.get("sha256", ""))):
        raise ValueError("Missing corresponding upstream source pin")
    if not isinstance(files, dict) or not 1 <= len(files) <= 512 or not {"Moonlight.exe", "portable.dat"} <= files.keys():
        raise ValueError("Invalid engine runtime inventory")
    names, total = set(), 0
    for name, entry in files.items():
        path = PurePosixPath(name)
        if (not name or path.is_absolute() or ".." in path.parts or "." in path.parts
                or path.as_posix() != name or "\\" in name or ":" in name or len(name) > 240
                or any(not re.fullmatch(r"[A-Za-z0-9_. -]+", part) or part.rstrip(". ") != part
                       or part.split(".")[0].upper() in {"CON", "PRN", "AUX", "NUL"}
                       or re.fullmatch(r"(?:COM|LPT)[0-9]", part.split(".")[0], re.IGNORECASE)
                       for part in path.parts)
                or any(ord(c) < 32 for c in name) or name.casefold() in names
                or set(entry) != {"sha256", "bytes"}
                or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])
                or type(entry["bytes"]) is not int or not 0 <= entry["bytes"] <= 64 * 1024 * 1024):
            raise ValueError("Invalid engine runtime entry: " + name)
        names.add(name.casefold())
        total += entry["bytes"]
    if total > 128 * 1024 * 1024:
        raise ValueError("Oversized engine runtime")
    for name in names:
        parts = name.split("/")
        if any("/".join(parts[:i]) in names for i in range(1, len(parts))):
            raise ValueError("File-directory collision in engine inventory")
    return pin, files


def generate_engine_pin(root, output):
    pin, files = engine_inputs(root)
    lines = ["// Generated from reviewed source pins. Do not load mutable runtime metadata.",
             "namespace DeskBridge.Reverse { internal static class EnginePin {"]
    for key, value in [("Version", pin["version"]), ("Url", pin["url"]), ("SHA256", pin["sha256"]), ("SourceUrl", pin["source"]["url"])]:
        lines.append("internal const string " + key + " = " + json.dumps(value) + ";")
    lines.append("internal const long Bytes = " + str(pin["bytes"]) + "L;")
    lines.append("internal static readonly RuntimeEntry[] Entries = {")
    for name, entry in sorted(files.items()):
        lines.append("new RuntimeEntry(" + json.dumps(name) + "," + json.dumps(entry["sha256"]) + "," + str(entry["bytes"]) + "L),")
    lines += ["};", "}}"]
    output = Path(output)
    output.write_text("\n".join(lines) + "\n")
    return {"version": pin["version"], "runtimeFiles": len(files),
            "generatedSHA256": hashlib.sha256(output.read_bytes()).hexdigest()}


def client_sources(root):
    return sorted(p for p in (Path(root) / "client/windows").glob("*.cs") if p.name != "Tests.cs") + [Path(root) / "host/windows/KnotUpdateForm.cs"]


def generate_qr_loader(digest, output):
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("Invalid decoder digest")
    # Load the exact embedded assembly before the adapter's types can be JIT-compiled.
    source = '''using System;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
namespace DeskBridge.Reverse {
internal static class ReverseQrLibrary {
private const string Identity = "DeskBridge.QrDecoder, Version=0.0.0.0, Culture=neutral, PublicKeyToken=null";
private static readonly object Gate = new object();
private static Assembly decoder;
private static Assembly Resolve(object sender, ResolveEventArgs request) {
 // No probing, paths or partial/simple-name matches: return only authenticated embedded bytes.
 if (!String.Equals(request.Name, Identity, StringComparison.Ordinal)) return null;
 lock (Gate) { return decoder; }
}
internal static void Initialize() {
 lock (Gate) {
 if (decoder != null) return;
 using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream("DeskBridge.Reverse.QrDecoder")) {
  if (input == null || input.Length < 1 || input.Length > 4*1024*1024) throw new InvalidDataException("QR decoder resource is missing.");
  byte[] data = new byte[(int)input.Length]; int offset=0;
  while (offset<data.Length) { int got=input.Read(data,offset,data.Length-offset); if(got==0) throw new EndOfStreamException(); offset+=got; }
  using (SHA256 hash=SHA256.Create()) if (BitConverter.ToString(hash.ComputeHash(data)).Replace("-", "").ToLowerInvariant() != "DIGEST") throw new InvalidDataException("QR decoder integrity check failed.");
  Assembly loaded=Assembly.Load(data);
  if(!String.Equals(loaded.FullName, Identity, StringComparison.Ordinal)) throw new InvalidDataException("Unexpected QR decoder assembly.");
  decoder=loaded;
  // Byte-array loads have no Framework probing context. Register before any adapter JIT.
  AppDomain.CurrentDomain.AssemblyResolve += Resolve;
 }
 }
}
}}
'''
    Path(output).write_text(source.replace("DIGEST", digest))
