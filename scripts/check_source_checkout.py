#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Reject checkout transformations before building any package; reads source only."""
from pathlib import Path
import json
import subprocess
import sys

sys.dont_write_bytecode = True
from build_snapshot import BuildSnapshotError, source_snapshot, validate_corresponding_source


def validate_checkout(root):
    root = Path(root)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    sources = source_snapshot(root)
    # Reuse the package gate's archive semantics, including export attributes and
    # its refusal of linked source inputs. Never follow a link to read its target.
    validate_corresponding_source(root, sources, revision=revision)
    return {"schema": 1, "status": "passed", "revision": revision,
            "sourceFiles": len(sources), "scope": "checkout bytes equal canonical corresponding-source archive"}


def main():
    try:
        result = validate_checkout(Path(__file__).resolve().parent.parent)
    except (BuildSnapshotError, OSError, subprocess.CalledProcessError) as error:
        print("Source checkout verification failed: " + str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
