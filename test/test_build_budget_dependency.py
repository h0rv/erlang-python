import os
import subprocess
import unittest
from pathlib import Path

import test_build_budget as harness

CONFIG = harness.CONFIG
ROOT = harness.ROOT

CONTROLS = (
    "MAKEFLAGS",
    "MFLAGS",
    "GNUMAKEFLAGS",
    "MAKEOVERRIDES",
    "MAKEFILES",
    "MAKE",
    "MAKELEVEL",
)
APPLICATION = os.environ.get("BUDGET_APPLICATION", "iommap")


class RecursiveDependencyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.probe = harness.BuildBudgetTests()
        self.probe.setUp()
        self.addCleanup(self.probe.doCleanups)
        self.dep = self.probe.dependency(APPLICATION)
        self.build = self.dep / "_build/cmake"
        self.environment = self.probe.environment
        for name in CONTROLS:
            self.environment.pop(name, None)
        self.environment.update(
            CFLAGS="budget-toolchain-sentinel", IOMMAP_BUILDOPTS="-j10"
        )
        self.probe.executable(
            "cmake3",
            "#!/bin/sh\nset -eu\nphase=configure\njobs=${CMAKE_BUILD_PARALLEL_LEVEL:-2}\n"
            'if [ "$1" = "--build" ]; then\n phase=build; shift 2\n'
            ' if [ "$1" = "--parallel" ]; then jobs=$2; shift 2; '
            '[ "${1-}" != "--" ] || shift; set -- -j "$jobs" "$@"; '
            'else [ "$1" != "--" ] || shift; fi\n'
            'else set -- -j "$jobs"; fi\n'
            "for name in " + " ".join(CONTROLS) + "; do\n"
            ' eval "present=\\${$name+x}"\n'
            ' [ -z "$present" ] || printf "%s\\n" "$name" >> controls\ndone\n'
            '[ "$CFLAGS" = "budget-toolchain-sentinel" ]\n'
            "export EVENT_FILE=$phase.events\n"
            'exec /usr/bin/make -rR "$@"\n',
        )
        (self.dep / "do_cmake.sh").write_text(
            "#!/bin/sh\ncd _build/cmake\nexec cmake3 configure\n"
        )
        (self.dep / "do_cmake.sh").chmod(0o755)
        script = "do_iommap.sh"
        if APPLICATION == "erlang_python":
            script = "do_build.sh"
            (self.dep / script).write_text(
                subprocess.check_output(
                    ["git", "show", "550abf9:do_build.sh"],
                    cwd=ROOT,
                    text=True,
                )
            )
            (self.dep / script).chmod(0o755)
        (self.dep / "rebar.config").write_text(
            '{pre_hooks, [{compile, "./do_cmake.sh"}]}.\n'
            '{post_hooks, [{compile, "./' + script + ' $IOMMAP_BUILDOPTS"}]}.\n'
        )
        (self.build / "Makefile").write_text(
            ".PHONY: all\nall:\n\t+$(MAKE) -rR -f assets.mk\n"
        )
        (self.build / "assets.mk").write_text(
            ".PHONY: all first second\nall: first second\nfirst second:\n"
            '\t@printf "start-$@\\n" >> $$EVENT_FILE; /bin/sleep 0.2; '
            'printf "end-$@\\n" >> $$EVENT_FILE\n'
        )
        self.injection = self.probe.root / "injected.mk"
        self.injection.write_text("override MAKEFLAGS := -j10\n")

    def peak(self, phase: str) -> int:
        active = peak = 0
        events = (self.build / (phase + ".events")).read_text().splitlines()
        self.assertEqual(len(events), 4, events)
        for event in events:
            active += 1 if event.startswith("start-") else -1
            peak = max(peak, active)
        self.assertEqual(active, 0)
        return peak

    def compile(self, configuration: Path) -> subprocess.CompletedProcess[str]:
        self.probe.project(APPLICATION, configuration)
        for name in ("configure.events", "build.events", "controls"):
            (self.build / name).unlink(missing_ok=True)
        return self.probe.run_command(["rebar3", "compile"], self.probe.root)

    def test_rejected_override_really_exceeds_one_in_recursive_make(self) -> None:
        old = self.probe.root / "old.config"
        revision = "0f8086e" if CONFIG.parent == ROOT else "e9fc1d0"
        old.write_text(
            subprocess.check_output(
                ["git", "show", revision + ":rebar.config"],
                cwd=CONFIG.parent,
                text=True,
            )
        )
        self.environment.update(
            CMAKE_BUILD_PARALLEL_LEVEL="1",
            MAKEFLAGS="-kj10 MAKEFLAGS=-j10",
        )
        result = self.compile(old)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.peak("configure"), 2)
        self.assertEqual(self.peak("build"), 2)

    def test_actual_rebar_configure_and_build_strip_recursive_controls(self) -> None:
        hostile = {
            "MAKEFLAGS": "-kj10 MAKEFLAGS=-j10",
            "MFLAGS": "-kj",
            "GNUMAKEFLAGS": "-kj10 MAKEFLAGS=-j10",
            "MAKEOVERRIDES": "MAKEFLAGS=-j10",
            "MAKEFILES": str(self.injection),
            "MAKE": "/usr/bin/make -j10",
            "MAKELEVEL": "99",
        }
        for budget in ("1", "2"):
            for controls in ({name: value} for name, value in hostile.items()):
                with self.subTest(budget=budget, controls=tuple(controls)):
                    self.environment.update(controls, CMAKE_BUILD_PARALLEL_LEVEL=budget)
                    result = self.compile(CONFIG)
                    self.assertEqual(
                        result.returncode, 0, result.stdout + result.stderr
                    )
                    self.assertIn(
                        "Inherited make controls replaced",
                        result.stdout + result.stderr,
                    )
                    self.assertFalse((self.build / "controls").exists())
                    for phase in ("configure", "build"):
                        self.assertLessEqual(self.peak(phase), int(budget))
                    for name in controls:
                        self.assertEqual(self.environment.pop(name), controls[name])
            self.environment.update(hostile, CMAKE_BUILD_PARALLEL_LEVEL=budget)
            result = self.compile(CONFIG)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((self.build / "controls").exists())
            self.assertLessEqual(self.peak("configure"), int(budget))
            self.assertLessEqual(self.peak("build"), int(budget))
            for name in hostile:
                self.assertEqual(self.environment.pop(name), hostile[name])


if __name__ == "__main__":
    unittest.main()
