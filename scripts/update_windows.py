# SPDX-License-Identifier: GPL-3.0-only
"""Build the pinned Windows updater and its independent, non-elevated handoff.

The caller supplies its already pinned C# compiler and Framework references.
No download, installation, preference, registry or signing-key access occurs.
"""
from pathlib import Path
import hashlib
import json
import subprocess

from update_runtime import publisher_config, stage_winsparkle
from update_version import build_number


def configuration_source(root, dll_sha256, helper_sha256=''):
    root = Path(root)
    publisher = publisher_config(root)
    version = (root / 'VERSION').read_text().strip()
    values = {
        'FeedURL': publisher['windowsFeedURL'] if publisher else '',
        'PublicEDKey': publisher['publicEDKey'] if publisher else '',
        'PublisherCertificateSHA256': publisher['windowsPublisherCertificateSHA256'] if publisher else '',
        'DisplayVersion': version,
        'BuildNumber': build_number(version),
        'RuntimeSHA256': dll_sha256,
        'HandoffSHA256': helper_sha256,
    }
    if any(len(values[name]) != 64 or any(c not in '0123456789abcdef' for c in values[name])
           for name in ['RuntimeSHA256'] + (['HandoffSHA256'] if helper_sha256 else [])):
        raise ValueError('Invalid updater binary pin')
    return ('// Generated from reviewed source; no runtime publisher override.\n'
            'namespace Knot.Updates { internal static class KnotUpdateConfiguration {\n'
            'internal const bool Configured = ' + ('true' if publisher else 'false') + ';\n' +
            ''.join('internal const string ' + name + ' = ' + json.dumps(value, ensure_ascii=True) + ';\n'
                    for name, value in values.items()) + '} }\n')


def prepare_windows_updates(root, compiler_prefix, references, destination):
    root, destination = Path(root), Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    runtime = stage_winsparkle(root, destination)
    runtime_sha = hashlib.sha256(runtime.read_bytes()).hexdigest()
    configuration = destination / 'KnotUpdateConfiguration.cs'
    configuration.write_text(configuration_source(root, runtime_sha), encoding='utf-8')
    helper = destination / 'KnotUpdateHandoff.exe'
    refs = [Path(references) / (name + '.dll') for name in
            ['mscorlib', 'System', 'System.Core', 'System.Windows.Forms']]
    if any(not path.is_file() for path in refs):
        raise ValueError('Windows updater requires Framework 4.8 reference assemblies')
    argv = list(compiler_prefix) + ['-nologo', '-target:winexe', '-platform:x64', '-langversion:5',
        '-optimize+', '-deterministic+', '-nostdlib+', '-main:Knot.Updates.KnotUpdateHandoff',
        '-out:' + str(helper), '-win32manifest:' + str(root / 'packaging/windows/Launcher.manifest'),
        '-win32icon:' + str(root / 'Assets/Brand/AppIcon.ico'),
        *['-r:' + str(path) for path in refs],
        str(root / 'packaging/windows/KnotUpdateHandoff.cs'), str(configuration)]
    result = subprocess.run(argv, capture_output=True)
    if result.returncode:
        helper.unlink(missing_ok=True)
        raise RuntimeError(result.stdout.decode(errors='replace') + result.stderr.decode(errors='replace'))
    helper_sha = hashlib.sha256(helper.read_bytes()).hexdigest()
    configuration.write_text(configuration_source(root, runtime_sha, helper_sha), encoding='utf-8')
    payload = [(path.name, path) for path in [runtime, helper,
        destination / 'WinSparkle-LICENSE.txt', destination / 'WinSparkle-Expat-LICENSE.txt']]
    return {'configurationSource': configuration, 'payload': payload,
            'sources': [root / 'client/windows/KnotUpdates.cs', root / 'packaging/windows/KnotUpdateHandoff.cs'],
            'record': {'configured': publisher_config(root) is not None, 'runtimeSHA256': runtime_sha,
                       'handoffSHA256': helper_sha, 'compilerArgv': argv, 'compilerExitCode': result.returncode,
                       'compilerStdout': result.stdout.decode(errors='replace'),
                       'compilerStderr': result.stderr.decode(errors='replace'),
                       'windowsRuntimeTested': False}}
