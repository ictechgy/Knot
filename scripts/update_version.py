# SPDX-License-Identifier: GPL-3.0-only
"""One deterministic increasing integer for Sparkle and WinSparkle VERSION ordering."""
import re

def build_number(version):
    match = re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(preview|beta|rc)\.(0|[1-9][0-9]*))?', version)
    if not match:
        raise ValueError('VERSION must be major.minor.patch[-preview.N|-beta.N|-rc.N]')
    major, minor, patch = map(int, match.group(1,2,3))
    if any(value > 999 for value in (major, minor, patch)):
        raise ValueError('Version components must be <=999')
    phase = {'preview': 1, 'beta': 2, 'rc': 3, None: 4}[match[4]]
    revision = int(match[5] or 0)
    if revision > 99999:
        raise ValueError('Prerelease number must be <=99999')
    return str((((major * 1000 + minor) * 1000 + patch) * 5 + phase) * 100000 + revision)
