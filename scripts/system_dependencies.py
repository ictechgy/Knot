# SPDX-License-Identifier: GPL-3.0-only
"""Validate the complete otool -L output against the system-only linkage policy."""
import re
import unicodedata


class SystemDependencyError(ValueError):
    pass


_DEPENDENCY = re.compile(
    r"[ \t]+(?P<path>.+) \(compatibility version [0-9]+\.[0-9]+\.[0-9]+, "
    r"current version [0-9]+\.[0-9]+\.[0-9]+(?:, weak)?\)"
)


def parse_system_dependencies(output: bytes, executable, *, allowed_frameworks=()) -> tuple[str, ...]:
    """Return canonical system paths, rejecting missing or malformed inspection data.

    This is a lexical install-name policy: it does not follow filesystem links or
    load any binary. The optional weak marker is emitted by otool for the app's
    existing weak-linked system Swift overlays.
    """
    try:
        text = output.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        raise SystemDependencyError("Invalid UTF-8 in dynamic dependency inspection.") from None
    lines = text.split("\n")
    if lines[-1] == "":
        lines.pop()
    if len(lines) < 2 or lines[0] != str(executable) + ":":
        raise SystemDependencyError("Missing or unexpected dynamic dependency inspection header.")
    dependencies = []
    for line in lines[1:]:
        match = _DEPENDENCY.fullmatch(line)
        if match is None:
            raise SystemDependencyError("Malformed dynamic dependency inspection line.")
        path = match.group("path")
        permitted_framework = path in allowed_frameworks and path == "@rpath/Sparkle.framework/Versions/B/Sparkle"
        if ((not path.startswith(("/usr/lib/", "/System/Library/")) and not permitted_framework)
                or any(part in ("", ".", "..") for part in path.split("/")[1:])
                or path != path.strip(" ")
                or any(unicodedata.category(character) == "Cc" for character in path)):
            raise SystemDependencyError("Unexpected non-canonical or non-system dynamic dependency.")
        dependencies.append(path)
    return tuple(dependencies)
