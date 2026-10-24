#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compile the real updater and run inert policy fixtures; never start WinSparkle."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

from update_windows import prepare_windows_updates

ROOT = Path(__file__).resolve().parent.parent


def check(compiler, references, dotnet=None):
    prefix = ([str(dotnet)] if dotnet else []) + [str(compiler)]
    with tempfile.TemporaryDirectory(prefix='knot-update-check-') as temporary:
        folder = Path(temporary)
        prepared = prepare_windows_updates(ROOT, prefix, references, folder / 'stage')
        # This fixture never initializes the native engine, even when publisher
        # configuration exists. It checks guards and pure production policies only.
        executable = folder / 'checks.exe'
        refs = [Path(references) / (name + '.dll') for name in
                ['mscorlib', 'System', 'System.Core', 'System.Windows.Forms', 'System.Drawing']]
        sources = prepared['sources'] + [prepared['configurationSource'], ROOT / 'scripts/tests/WindowsUpdateChecks.cs']
        argv = prefix + ['-nologo', '-target:exe', '-platform:anycpu', '-langversion:5', '-optimize+', '-deterministic+',
            '-nostdlib+', '-main:WindowsUpdateChecks', '-out:' + str(executable)] + ['-r:' + str(path) for path in refs] + list(map(str, sources))
        compiled = subprocess.run(argv, capture_output=True)
        if compiled.returncode:
            raise RuntimeError(compiled.stdout.decode(errors='replace') + compiled.stderr.decode(errors='replace'))
        if sys.platform == 'win32':
            run_argv = [str(executable)]
        elif dotnet:
            runtime_root = Path(dotnet).resolve().parent / 'shared/Microsoft.NETCore.App'
            versions = sorted((item.name for item in runtime_root.iterdir() if item.is_dir()),
                              key=lambda value: tuple(int(part) for part in value.split('.')))
            (folder / 'checks.runtimeconfig.json').write_text(json.dumps({'runtimeOptions': {
                'tfm': 'net8.0', 'framework': {'name': 'Microsoft.NETCore.App', 'version': versions[-1]}}}))
            run_argv = [str(dotnet), str(executable)]
        else:
            raise ValueError('Supply --dotnet to execute pure checks outside Windows')
        executed = subprocess.run(run_argv, capture_output=True, timeout=30)
        if executed.returncode:
            raise RuntimeError(executed.stdout.decode(errors='replace') + executed.stderr.decode(errors='replace'))
        output = executed.stdout.decode(errors='replace')
        match = re.fullmatch(r'Windows update policy: ([1-9][0-9]*) checks passed; native updater and installer not run\.\r?\n', output)
        if not match: raise RuntimeError('Updater fixture did not emit its exact terminal success record')
        return {'status': 'PASS', 'checks': int(match[1]), 'compilerArgv': argv, 'compilerExitCode': compiled.returncode,
                'compilerStdout': compiled.stdout.decode(errors='replace'), 'compilerStderr': compiled.stderr.decode(errors='replace'),
                'runArgv': run_argv, 'runExitCode': executed.returncode,
                'stdout': output, 'stderr': executed.stderr.decode(errors='replace'),
                'handoffBuild': prepared['record'], 'sourceSHA256': {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in prepared['sources'] + [ROOT / 'scripts/tests/WindowsUpdateChecks.cs']},
                'nativeWindowsFileSharingTested': sys.platform == 'win32', 'freshSyntheticOnly': True,
                'nativeUpdaterExecuted': False, 'installerExecuted': False, 'registryRead': False, 'networkUsed': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True)
    parser.add_argument('--references', required=True)
    parser.add_argument('--dotnet')
    parser.add_argument('--output')
    args = parser.parse_args()
    result = check(args.compiler, args.references, args.dotnet)
    if args.output:
        Path(args.output).write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
