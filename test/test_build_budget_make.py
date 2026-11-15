import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REJECTED = "5186cdc19dce9d2acb40ef44e455527b91bec64b"


class RealMakeBudgetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="build-budget-real-make-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.build = self.root / "_build/cmake"
        self.build.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.events = self.build / "events"
        self.argv = self.root / "argv"
        self.environment = dict(os.environ)
        for key in (
            "CMAKE_BUILD_PARALLEL_LEVEL",
            "MAKEFLAGS",
            "MFLAGS",
            "GNUMAKEFLAGS",
            "MAKEOVERRIDES",
            "MAKEFILES",
            "MAKE",
            "MAKELEVEL",
            "IOMMAP_BUILDOPTS",
        ):
            self.environment.pop(key, None)
        self.environment.update(
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            ARGV_LOG=str(self.argv),
        )
        self.tool(
            "cmake3",
            '#!/bin/sh\nset -eu\nprintf "%s\\n" "$@" > "$ARGV_LOG"\n'
            '[ "$1" = "--build" ] && [ "$3" = "--parallel" ]\n'
            'jobs=$4; shift 4\n[ "${1-}" != "--" ] || shift\n'
            'exec /usr/bin/make -rR -j "$jobs" "$@"\n',
        )
        # The only real build tool used is make, with explicit non-C recipes.
        for name in ("cc", "c++", "gcc", "clang", "cmake"):
            self.tool(name, "#!/bin/sh\nexit 99\n")
        (self.build / "Makefile").write_text(
            ".PHONY: all first second\nall: first second\n"
            "first second:\n"
            "\t@printf 'start-$@\\n' >> events; /bin/sleep 0.2; "
            "printf 'end-$@\\n' >> events\n"
        )
        self.script = ROOT / "do_build.sh"

    def tool(self, name: str, content: str) -> None:
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_build(self, arguments: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
        self.events.unlink(missing_ok=True)
        self.argv.unlink(missing_ok=True)
        return subprocess.run(
            ["sh", str(self.script), *arguments],
            cwd=self.root,
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def peak(self) -> int:
        active = peak = 0
        events = self.events.read_text().splitlines()
        self.assertEqual(len(events), 4, events)
        for event in events:
            active += 1 if event.startswith("start-") else -1
            peak = max(peak, active)
            self.assertGreaterEqual(active, 0, events)
        self.assertEqual(active, 0, events)
        return peak

    def test_rejected_baseline_really_runs_assets_in_parallel_at_budget_one(
        self,
    ) -> None:
        self.script = self.root / "rejected-do_build.sh"
        self.script.write_text(
            subprocess.check_output(
                ["git", "show", REJECTED + ":do_build.sh"],
                cwd=ROOT,
                text=True,
            )
        )
        self.environment["CMAKE_BUILD_PARALLEL_LEVEL"] = "1"
        for arguments in (("-kj",), ("-kj10",), ("-skj2",), ("-j1", "-kj10")):
            with self.subTest(arguments=arguments):
                result = self.run_build(arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                # Expected failure of the old budget invariant, using real make.
                self.assertGreater(self.peak(), 1)

    def test_supported_forms_honor_ceiling_with_real_make(self) -> None:
        for budget, arguments, expected in (
            (None, (), 2),
            ("", (), 2),
            ("1", (), 1),
            ("2", (), 2),
            ("1", ("-j", "2"), 1),
            ("2", ("-j1",), 1),
            ("1", ("-j2",), 1),
            ("2", ("-j", "1"), 1),
        ):
            with self.subTest(budget=budget, arguments=arguments):
                if budget is None:
                    self.environment.pop("CMAKE_BUILD_PARALLEL_LEVEL", None)
                else:
                    self.environment["CMAKE_BUILD_PARALLEL_LEVEL"] = budget
                result = self.run_build(arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertLessEqual(self.peak(), expected)
                self.assertEqual(
                    self.argv.read_text().splitlines(),
                    ["--build", ".", "--parallel", str(expected)],
                )

    def test_all_unsupported_arguments_fail_before_cmake(self) -> None:
        unsafe = (
            ("-kj",),
            ("-kj10",),
            ("-skj2",),
            ("-ikj",),
            ("-jk",),
            ("-j",),
            ("-j0",),
            ("-j3",),
            ("-j", "10"),
            ("-j1", "-kj10"),
            ("--jobs",),
            ("--jobs=10",),
            ("--job=10",),
            ("--jo=10",),
            ("--parallel", "1"),
            ("--jobserver-fds=3,4",),
            ("--jobserver-auth=3,4",),
            ("MAKEFLAGS=-j10",),
            ("MFLAGS=-j",),
            ("GNUMAKEFLAGS=-j10",),
            ("MAKEOVERRIDES=MAKEFLAGS=-j10",),
            ("MAKE=make -j10",),
            ("-j1", "MAKEFLAGS=-j10"),
            ("all", "-kj10"),
            ("-kj10", "all"),
            ("--", "-kj10"),
            ("-k",),
            ("--keep-going",),
            ("all",),
        )
        for budget in ("1", "2"):
            self.environment["CMAKE_BUILD_PARALLEL_LEVEL"] = budget
            for arguments in unsafe:
                with self.subTest(budget=budget, arguments=arguments):
                    result = self.run_build(arguments)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertTrue(result.stderr)
                    self.assertFalse(self.argv.exists())
                    self.assertFalse(self.events.exists())

    def test_invalid_environment_fails_before_cmake(self) -> None:
        for budget in ("0", "3", "10", "-1", "invalid", "1 2", "1\n"):
            with self.subTest(budget=budget):
                self.environment["CMAKE_BUILD_PARALLEL_LEVEL"] = budget
                result = self.run_build(())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must be 1 or 2", result.stderr)
                self.assertFalse(self.argv.exists())
                self.assertFalse(self.events.exists())

    def test_direct_configure_strips_make_controls_before_cmake(self) -> None:
        self.script = ROOT / "do_cmake.sh"
        injection = self.root / "injected.mk"
        injection.write_text("override MAKEFLAGS := -j10\n")
        controls = {
            "MAKEFLAGS": "-kj10 MAKEFLAGS=-j10",
            "MFLAGS": "-kj",
            "GNUMAKEFLAGS": "-kj10",
            "MAKEOVERRIDES": "MAKEFLAGS=-j10",
            "MAKEFILES": str(injection),
            "MAKE": "/usr/bin/make -j10",
            "MAKELEVEL": "99",
        }
        self.environment.update(controls, CFLAGS="preserved-toolchain-sentinel")
        self.tool(
            "cmake3",
            "#!/bin/sh\nset -eu\n"
            "for name in " + " ".join(controls) + "; do\n"
            ' eval "present=\\${$name+x}"\n[ -z "$present" ] || exit 98\ndone\n'
            '[ "$CFLAGS" = "preserved-toolchain-sentinel" ]\n'
            'exec /usr/bin/make -rR -j "$CMAKE_BUILD_PARALLEL_LEVEL"\n',
        )
        for budget in ("1", "2"):
            self.environment["CMAKE_BUILD_PARALLEL_LEVEL"] = budget
            result = self.run_build(())
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Inherited make controls replaced", result.stderr)
            self.assertLessEqual(self.peak(), int(budget))
            for name, value in controls.items():
                self.assertEqual(self.environment[name], value)
        for budget in ("0", "3", "invalid"):
            self.environment["CMAKE_BUILD_PARALLEL_LEVEL"] = budget
            result = self.run_build(())
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must be 1 or 2", result.stderr)
            self.assertFalse(self.events.exists())

    def test_inherited_make_controls_do_not_escape_budget(self) -> None:
        # Exercise propagation through recursive make, not just the first argv.
        (self.build / "Makefile").rename(self.build / "assets.mk")
        (self.build / "Makefile").write_text(
            ".PHONY: all\nall:\n\t+$(MAKE) -rR -f assets.mk\n"
        )
        injection = self.root / "injected.mk"
        injection.write_text("override MAKEFLAGS := -j10\n")
        controls = {
            "MAKEFLAGS": "-kj10 MAKEFLAGS=-j10",
            "MFLAGS": "-kj",
            "GNUMAKEFLAGS": "-kj10",
            "MAKEOVERRIDES": "MAKEFLAGS=-j10",
            "MAKEFILES": str(injection),
            "MAKE": "/usr/bin/make -j10",
            "MAKELEVEL": "99",
        }
        for budget in ("1", "2"):
            for name, value in controls.items():
                with self.subTest(budget=budget, control=name):
                    self.environment["CMAKE_BUILD_PARALLEL_LEVEL"] = budget
                    self.environment[name] = value
                    self.environment["IOMMAP_BUILDOPTS"] = "-kj10"
                    result = self.run_build(())
                    self.environment.pop(name)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("Inherited make controls replaced", result.stderr)
                    self.assertLessEqual(self.peak(), int(budget))


if __name__ == "__main__":
    unittest.main()
