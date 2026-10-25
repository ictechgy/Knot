#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""A/B actual production compressed-frame preparation on fresh synthetic inputs.

The baseline comes only from an explicit immutable Git commit. Both implementations
are compiled together with identical -O flags, real CoreMedia, inert decoder stubs
and no VideoToolbox/capture/display/network/app state. All compiler/cache products
live in a new system temporary directory. Pinned unmodified baseline sources also
work offline in a shallow checkout. --benchmark requires a new output path.
"""
from pathlib import Path
import argparse
import hashlib
import json
import platform
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BASELINE = "a9bd368f9281ac0c6c0d9cf140604b16ebb1d462"
PINNED = ROOT / "scripts/benchmarks/baselines/video-prepare-a9bd"
PINNED_SHA256 = {
    "VideoDecoder+Bitstream.swift": "0634d0e51da232d397aa718a1a1a073183f58ced10a2f71c5b9311b2b7847a56",
    "VideoDepacketizer+AnnexB.swift": "2d8987162087a05c662c393b0018ed2218ac80d10d71c8066e8b53eaad1b5082",
    "StreamingBackend.swift": "e7a4a4928b89880bc8d8f8ce5b86c4ba223a70fff17309287cbb81c48d910d7c",
}
BITSTREAM = "Vendor/Glimmer/GlimmerEngine/Video/VideoDecoder+Bitstream.swift"
ANNEXB = "Vendor/Glimmer/GlimmerEngine/Network/VideoDepacketizer+AnnexB.swift"
BUFFERS = "Vendor/Glimmer/GlimmerEngine/Protocol/StreamingBackend.swift"
SOURCE_PATHS = [BITSTREAM, ANNEXB, BUFFERS]
MARKER = "    // MARK: - Annex-B / AVCC conversion"
FLAGS = ["-O", "-swift-version", "6", "-parse-as-library"]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run(args, **kwargs):
    result = subprocess.run(args, cwd=ROOT, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, **kwargs)
    if result.returncode:
        sys.stderr.buffer.write(result.stdout)
        sys.stderr.buffer.write(result.stderr)
        result.check_returncode()
    return result


def balanced_type(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


def baseline_sources(commit):
    present = subprocess.run(["git", "cat-file", "-t", commit], cwd=ROOT,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    git_available = present.returncode == 0 and present.stdout.strip() == b"commit"
    if commit != DEFAULT_BASELINE:
        return ({path: run(["git", "show", commit + ":" + path]).stdout
                 for path in SOURCE_PATHS}, "explicit Git commit")
    manifest = json.loads((PINNED / "manifest.json").read_text())
    if manifest["baseline_commit"] != DEFAULT_BASELINE:
        raise ValueError("pinned baseline commit mismatch")
    if {entry["source_path"] for entry in manifest["files"]} != set(SOURCE_PATHS):
        raise ValueError("pinned baseline source inventory mismatch")
    result = {}
    for entry in manifest["files"]:
        name = Path(entry["source_path"]).name
        if entry["snapshot_file"] != name:
            raise ValueError("pinned baseline filename mismatch")
        data = (PINNED / name).read_bytes()
        if sha(data) != PINNED_SHA256[name] or sha(data) != entry["sha256"]:
            raise ValueError("pinned baseline source fingerprint mismatch: " + name)
        blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if blob != entry["git_blob"]:
            raise ValueError("pinned baseline Git blob mismatch: " + name)
        if git_available and run(["git", "show", commit + ":" + entry["source_path"]]).stdout != data:
            raise ValueError("pinned source differs from immutable Git baseline: " + name)
        result[entry["source_path"]] = data
    return result, "pinned exact source snapshots" + (" + Git cross-check" if git_available else " (offline shallow checkout)")


def production(source, prefix):
    tail = source[BITSTREAM].decode().split(MARKER, 1)[1]
    if not tail.rstrip().endswith("}"):
        raise ValueError("Bitstream tail extension contract changed")
    decoder = ("final class " + prefix + "VideoDecoder {\n"
               "    var formatDescription: CMVideoFormatDescription?\n"
               "    let log = QuietLogger()\n}\n"
               "extension " + prefix + "VideoDecoder {\n" + tail)
    annex = source[ANNEXB].decode()
    annex = "\n".join(line for line in annex.splitlines()
                      if not line.startswith("import "))
    annex = annex.replace("VideoDepacketizer", prefix + "VideoDepacketizer")
    depacketizer = ("final class " + prefix + "VideoDepacketizer {\n"
                    "    let isHEVC: Bool\n"
                    "    init(isHEVC: Bool) { self.isHEVC = isHEVC }\n}\n" + annex)
    return decoder + "\n" + depacketizer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default=DEFAULT_BASELINE,
                        help="full immutable 40-character baseline Git commit")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--benchmark", action="store_true")
    mode.add_argument("--checks-only", action="store_true", help="fast offline correctness checks (default)")
    parser.add_argument("--output", type=Path, help="new evidence directory (required for benchmark)")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.baseline):
        parser.error("--baseline must be a full immutable Git SHA")
    if args.benchmark and args.output is None:
        parser.error("--benchmark requires --output to preserve raw evidence")
    if sys.platform != "darwin":
        parser.error("real CoreMedia benchmark requires macOS")
    baseline, baseline_origin = baseline_sources(args.baseline)
    current = {path: (ROOT / path).read_bytes() for path in SOURCE_PATHS}
    head = run(["git", "rev-parse", "HEAD"]).stdout.decode().strip()
    dirty = run(["git", "diff", "--binary", "HEAD", "--", *SOURCE_PATHS]).stdout
    compiler = run(["/usr/bin/swiftc", "--version"]).stdout.decode()
    has_direct = bool(re.search(r"annexB\s*:\s*Bool\s*=\s*false", current[BITSTREAM].decode()))
    optimized_split = "withUnsafeBytes" in current[ANNEXB].decode()
    fixture = (ROOT / "scripts/benchmarks/VideoPrepareBenchmark.swift").read_text()
    buffers = balanced_type(current[BUFFERS].decode(), "public struct DecodeBuffer:")
    if buffers != balanced_type(baseline[BUFFERS].decode(), "public struct DecodeBuffer:"):
        raise ValueError("DecodeBuffer contract differs; explicitly update benchmark stubs")
    generated = fixture.replace("__PRODUCTION__", "struct QuietLogger { func error(_ message: String) {} }\n" + buffers + "\n" +
                                production(baseline, "Baseline") + "\n" + production(current, "Candidate"))
    generated = generated.replace("__CANDIDATE_SAMPLE__",
        "decoder.makeSampleBuffer(rawData: input, rtpTimestamp: timestamp, annexB: true)" if has_direct else
        "decoder.makeSampleBuffer(rawData: decoder.convertAnnexBToAVCC(input), rtpTimestamp: timestamp)")
    if optimized_split:
        generated = generated.replace("__NONZERO_SLICE_CHECK__", '''
        let padded = Data(repeating: 0xa5, count: 17) + value.input + Data([0x7f])
        let slice = padded[17..<(17 + value.input.count)]
        try expect(slice.startIndex == 17, "nonzero-based Data fixture")
        try expect(same(bufferPairs(newDepacketizer.splitAnnexBParamSets(slice)), value.expectedBuffers), "nonzero-based split")
        try expect(try contents(candidateSample(candidate, slice, 7)) == value.expectedAVCC, "nonzero-based sample")
        ''').replace("__SLICE_STATUS__", '"candidate verified directly; baseline split requires zero-based Data"')
    else:
        generated = generated.replace("__NONZERO_SLICE_CHECK__", "")
        generated = generated.replace("__SLICE_STATUS__", '"not yet enabled: baseline split assumes zero-based Data"')
    if re.search(r"__[A-Z_]+__", generated):
        raise ValueError("unexpanded Swift fixture placeholder")
    evidence = {
        "baseline_commit": args.baseline, "baseline_source_origin": baseline_origin, "candidate_head": head,
        "candidate_dirty_diff_sha256": sha(dirty), "compiler_version": compiler.strip(),
        "compiler_flags": FLAGS, "platform": platform.platform(), "architecture": platform.machine(),
        "candidate_direct_annexb": has_direct, "candidate_pointer_split": optimized_split,
        "baseline_sources_sha256": {path: sha(data) for path, data in baseline.items()},
        "candidate_sources_sha256": {path: sha(data) for path, data in current.items()},
        "harness_sha256": sha(fixture.encode()), "generated_swift_sha256": sha(generated.encode()),
        "limits": "Preparation microbenchmark only; no codec decoding, live stream, FPS, network, display or input-to-photon claims."
    }
    output = args.output.resolve() if args.output else None
    if output:
        output.mkdir(parents=True, exist_ok=False)
        (output / "candidate.diff").write_bytes(dirty)
        (output / "benchmark.swift").write_text(generated)
        (output / "metadata.json").write_text(json.dumps(evidence, indent=2) + "\n")
    with tempfile.TemporaryDirectory(prefix="knot-video-prepare-synthetic-") as directory:
        temporary = Path(directory)
        swift = temporary / "Benchmark.swift"
        swift.write_text(generated)
        argv = ["/usr/bin/swiftc", *FLAGS, "-module-cache-path", str(temporary / "module-cache"),
                str(swift), "-o", str(temporary / "benchmark")]
        compiled = run(argv)
        executed = run([str(temporary / "benchmark"), *( ["--benchmark"] if args.benchmark else [])])
        result = json.loads(executed.stdout)
        evidence["sources_unchanged_after_execution"] = all((ROOT / path).read_bytes() == data for path, data in current.items())
        if not evidence["sources_unchanged_after_execution"]:
            raise RuntimeError("production sources changed while benchmarking; rerun against stable snapshot")
        evidence["result_sha256"] = sha(executed.stdout)
        if output:
            (output / "compiler.argv.json").write_text(json.dumps(argv, indent=2) + "\n")
            (output / "compiler.stdout").write_bytes(compiled.stdout)
            (output / "compiler.stderr").write_bytes(compiled.stderr)
            (output / "runtime.stdout.json").write_bytes(executed.stdout)
            (output / "runtime.stderr").write_bytes(executed.stderr)
            (output / "metadata.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(json.dumps({"metadata": evidence, "result": result}, indent=2))


if __name__ == "__main__":
    main()
