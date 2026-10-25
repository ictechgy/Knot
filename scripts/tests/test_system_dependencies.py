# SPDX-License-Identifier: GPL-3.0-only
"""Pure fixtures for dependency policy; no binary, linker, network or app is run."""
from pathlib import Path
import ast
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from system_dependencies import SystemDependencyError, parse_system_dependencies


class SystemDependencyTests(unittest.TestCase):
    executable = "/synthetic/stage with spaces/Knot.app/Contents/MacOS/DeskBridge"
    metadata = " (compatibility version 1.0.0, current version 1359.0.0)"

    def output(self, *lines):
        return (self.executable + ":\n" + "\n".join(lines) + "\n").encode("utf-8")

    def line(self, path):
        return "\t" + path + self.metadata

    def test_normal_system_framework_library_and_weak_overlay(self):
        paths = ("/usr/lib/libSystem.B.dylib",
                 "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
                 "/usr/lib/swift/libswiftCoreAudio.dylib")
        lines = [self.line(path) for path in paths]
        lines[-1] = lines[-1][:-1] + ", weak)"
        self.assertEqual(parse_system_dependencies(self.output(*lines), self.executable), paths)

    def test_zero_versions_and_output_without_final_newline(self):
        line = "\t/usr/lib/swift/libswiftCore.dylib (compatibility version 0.0.0, current version 0.0.0)"
        self.assertEqual(parse_system_dependencies(self.output(line).rstrip(b"\n"), self.executable),
                         ("/usr/lib/swift/libswiftCore.dylib",))

    def test_escape_dot_and_redundant_slash_paths_are_rejected(self):
        for path in ("/usr/lib/../../tmp/evil.dylib", "/System/Library/../../tmp/evil.dylib",
                     "/usr/lib/./libSystem.B.dylib", "/usr/lib/swift/../libSystem.B.dylib",
                     "/System/Library/Frameworks/./AppKit.framework/AppKit",
                     "/usr/lib//libSystem.B.dylib", "/System//Library/Frameworks/AppKit",
                     "//usr/lib/libSystem.B.dylib", "/usr/lib/", "/System/Library/"):
            with self.subTest(path=path), self.assertRaises(SystemDependencyError):
                parse_system_dependencies(self.output(self.line(path)), self.executable)

    def test_non_system_and_loader_relative_paths_are_rejected(self):
        for path in ("@rpath/libGlimmerEngine.dylib", "@executable_path/../Frameworks/evil.dylib",
                     "@loader_path/evil.dylib", "usr/lib/libSystem.B.dylib", "/tmp/evil.dylib",
                     "/usr/local/lib/evil.dylib", "/usr/library/evil.dylib",
                     "/System/LibraryEvil/evil.dylib"):
            with self.subTest(path=path), self.assertRaises(SystemDependencyError):
                parse_system_dependencies(self.output(self.line(path)), self.executable)

    def test_control_characters_in_paths_are_rejected(self):
        for codepoint in list(range(32)) + list(range(127, 160)):
            path = "/usr/lib/lib" + chr(codepoint) + "evil.dylib"
            with self.subTest(codepoint=codepoint), self.assertRaises(SystemDependencyError):
                parse_system_dependencies(self.output(self.line(path)), self.executable)

    def test_missing_or_malformed_metadata_is_rejected(self):
        path = "\t/usr/lib/libSystem.B.dylib"
        for suffix in ("", " ()", " (compatibility version 1.0.0)",
                       " (current version 1.0.0, compatibility version 1.0.0)",
                       " (compatibility version 1.0, current version 1.0.0)",
                       " (compatibility version 1.0.0, current version -1.0.0)",
                       " (compatibility version x.0.0, current version 1.0.0)",
                       " (compatibility version 1.0.0, current version 1.0.0, unknown)",
                       self.metadata + " trailing", self.metadata[:-1],
                       self.metadata + "\r", self.metadata + "\x00"):
            with self.subTest(suffix=suffix), self.assertRaises(SystemDependencyError):
                parse_system_dependencies(self.output(path + suffix), self.executable)

    def test_empty_missing_or_wrong_header_and_empty_dependency_list_are_rejected(self):
        valid_line = self.line("/usr/lib/libSystem.B.dylib")
        for output in (b"", b"\n", (self.executable + ":\n").encode(),
                       (valid_line + "\n").encode(), b"/wrong/executable:\n" + valid_line.encode(),
                       (self.executable + " (architecture arm64):\n" + valid_line).encode()):
            with self.subTest(output=output), self.assertRaises(SystemDependencyError):
                parse_system_dependencies(output, self.executable)

    def test_blank_lines_and_noncanonical_line_whitespace_are_rejected(self):
        line = self.line("/usr/lib/libSystem.B.dylib")
        for output in (self.output(line, ""), self.output("", line), self.output("not a dependency"),
                       self.output(line.lstrip()), self.output(line + " "),
                       self.output(self.line("/usr/lib/evil.dylib "))):
            with self.subTest(output=output), self.assertRaises(SystemDependencyError):
                parse_system_dependencies(output, self.executable)

    def test_invalid_utf8_is_rejected(self):
        with self.assertRaises(SystemDependencyError):
            parse_system_dependencies(self.output(self.line("/usr/lib/libSystem.B.dylib")) + b"\xff",
                                      self.executable)

    def test_actual_build_and_package_call_sites_apply_the_same_parser(self):
        # Evaluate only the actual parser call AST with inert run(), never import
        # either top-level build/packaging script or invoke external programs.
        expected = {"build.py": {"inspect-host-supervisor-dependencies", "inspect-dependencies", "inspect-mac-installer-dependencies"},
                    "package_release.py": {"inspect-staged-host-supervisor-dependencies", "inspect-staged-local-installer-dependencies"}}
        for filename, labels in expected.items():
            source = ast.parse((SCRIPTS / filename).read_text())
            calls = [node for node in ast.walk(source) if isinstance(node, ast.Call)
                     and isinstance(node.func, ast.Name) and node.func.id == "parse_system_dependencies"]
            self.assertEqual(len(calls), len(labels), filename)
            observed = set()
            for call in calls:
                expression = compile(ast.Expression(body=call), str(SCRIPTS / filename), "eval")
                for path, accepted in (("/usr/lib/libSystem.B.dylib", True),
                                       ("/usr/lib/../../tmp/evil.dylib", False)):
                    def run(label, argv):
                        observed.add(label)
                        self.assertIn(label, labels)
                        self.assertEqual(argv[:2], ["/usr/bin/otool", "-L"])
                        return (argv[2] + ":\n\t" + path + self.metadata + "\n").encode()
                    namespace = {"__builtins__": {}, "str": str, "run": run, "update_publisher": None,
                                 "supervisor": Path("/synthetic/Contents/Helpers/KnotHostSupervisor"),
                                 "macos": Path("/synthetic/Contents/MacOS"),
                                 "installer": Path("/synthetic/Install Knot.app"),
                                 "installer_binary": Path("/synthetic/Install Knot.app/Contents/MacOS/KnotInstaller"),
                                 "parse_system_dependencies": parse_system_dependencies}
                    if accepted:
                        self.assertEqual(eval(expression, namespace), (path,))
                    else:
                        with self.assertRaises(SystemDependencyError):
                            eval(expression, namespace)
            self.assertEqual(observed, labels)


if __name__ == "__main__":
    unittest.main()
