import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = Path(os.environ.get("BUILD_BUDGET_CONFIG", str(ROOT / "rebar.config")))
FIXTURE = ROOT / "test/fixtures/iommap/do_iommap.sh"


class BuildBudgetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="build-budget-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "argv"
        self.environment = dict(os.environ)
        for key in ("CMAKE_BUILD_PARALLEL_LEVEL", "IOMMAP_BUILDOPTS", "MAKEFLAGS"):
            self.environment.pop(key, None)
        self.environment.update(
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            ARGV_LOG=str(self.log),
            ERL_FLAGS="+S 1:1 +A 1",
            REBAR_GLOBAL_CONFIG_DIR=str(self.root / "global"),
        )
        self.executable("getconf", "#!/bin/sh\nprintf '10\\n'\n")
        self.executable(
            "cmake3",
            '#!/bin/sh\nprintf "cmake %s\\n" "$*" >> "$ARGV_LOG"\n'
            'shift 2\nif [ "$1" = "--parallel" ]; then\n'
            '  jobs=$2; shift 2; [ "${1-}" != "--" ] || shift\n'
            '  exec make -j "$jobs" "$@"\n'
            'fi\n[ "$1" != "--" ] || shift\nexec make "$@"\n',
        )
        self.executable(
            "make",
            '#!/bin/sh\nprintf "make %s cap=%s\\n" "$*" '
            '"${CMAKE_BUILD_PARALLEL_LEVEL-unset}" >> "$ARGV_LOG"\n'
            '[ "$1" = "-j" ] && [ "$2" -le "${CMAKE_BUILD_PARALLEL_LEVEL:-2}" ] || '
            '{ printf "budget-violation\\n" >> "$ARGV_LOG"; exit 23; }\n',
        )
        # Hard stops: configure/build must only reach the fake tools above.
        for tool in ("cc", "gcc", "clang", "c++", "cmake"):
            self.executable(tool, "#!/bin/sh\nexit 99\n")

    def executable(self, name: str, content: str) -> None:
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_command(
        self, command: list[str], cwd: Path
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            command,
            cwd=cwd,
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def dependency(self, application: str = "iommap") -> Path:
        dep = self.root / "_checkouts" / application
        (dep / "_build/cmake").mkdir(parents=True)
        shutil.copyfile(FIXTURE, dep / "do_iommap.sh")
        (dep / "do_iommap.sh").chmod(0o755)
        (dep / "do_cmake.sh").write_text("#!/bin/sh\nexit 0\n")
        (dep / "do_cmake.sh").chmod(0o755)
        (dep / "rebar.config").write_text(
            '{post_hooks, [{compile, "./do_iommap.sh $IOMMAP_BUILDOPTS"}]}.\n'
        )
        self.app(dep, application)
        return dep

    @staticmethod
    def app(directory: Path, name: str) -> None:
        (directory / "src").mkdir(exist_ok=True)
        (directory / "src" / (name + ".app.src")).write_text(
            "{application, "
            + name
            + ', [{vsn, "1"}, {applications, [kernel, stdlib]}]}.\n'
        )

    def project(
        self, application: str = "iommap", configuration: Path = CONFIG
    ) -> None:
        self.app(self.root, "budget_probe")
        expression = (
            '{ok, C} = file:consult(os:getenv("BUDGET_CONFIG")), '
            "O = proplists:get_value(overrides, C), "
            'ok = file:write_file("rebar.config", io_lib:format("~p.~n~p.~n", '
            '[{deps, [list_to_atom(os:getenv("BUDGET_DEP"))]}, {overrides, O}])), halt().'
        )
        self.environment["BUDGET_CONFIG"] = str(configuration)
        self.environment["BUDGET_DEP"] = application
        result = self.run_command(["erl", "-noshell", "-eval", expression], self.root)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_old_dependency_escapes_environment(self) -> None:
        dep = self.dependency()
        self.environment.update(CMAKE_BUILD_PARALLEL_LEVEL="1", MAKEFLAGS="-j1")
        result = self.run_command(["sh", "./do_iommap.sh"], dep)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("budget-violation", self.log.read_text())
        self.assertIn("make -j 10 cap=1", self.log.read_text())
        # This is the failing budget assertion before the tracked override.
        self.assertNotIn("make -j 1 cap=1", self.log.read_text())

    def test_actual_rebar_dependency_hook_is_bounded(self) -> None:
        self.dependency()
        self.project()
        for budget, expected in ((None, "2"), ("", "2"), ("1", "1"), ("2", "2")):
            with self.subTest(budget=budget):
                self.log.unlink(missing_ok=True)
                if budget is None:
                    self.environment.pop("CMAKE_BUILD_PARALLEL_LEVEL", None)
                else:
                    self.environment["CMAKE_BUILD_PARALLEL_LEVEL"] = budget
                self.environment.update(IOMMAP_BUILDOPTS="-j10", MAKEFLAGS="-j99")
                # Touch the .app source to force the dependency's compile hooks again.
                app = self.root / "_checkouts/iommap/src/iommap.app.src"
                app.write_text(app.read_text() + "\n")
                result = self.run_command(["rebar3", "compile"], self.root)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(
                    "replaced by the compiler job budget", result.stdout + result.stderr
                )
                self.assertIn("make -j " + expected + " cap=", self.log.read_text())
                self.assertNotIn("-j 10", self.log.read_text())
                self.assertNotIn("budget-violation", self.log.read_text())

    def test_rebar_rejects_unsafe_environment_before_build(self) -> None:
        self.dependency()
        self.project()
        for budget in ("3", "10", "0", "-1", "invalid", "1 2"):
            with self.subTest(budget=budget):
                self.environment["CMAKE_BUILD_PARALLEL_LEVEL"] = budget
                result = self.run_command(["rebar3", "compile"], self.root)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must be 1 or 2", result.stdout + result.stderr)
                self.assertFalse(self.log.exists())

    def test_main_build_budget(self) -> None:
        (self.root / "_build/cmake").mkdir(parents=True)
        for budget, arguments, expected in (
            (None, [], "2"),
            ("", [], "2"),
            ("1", [], "1"),
            ("1", ["-j", "2"], "1"),
            ("2", ["-j1"], "1"),
        ):
            with self.subTest(budget=budget, arguments=arguments):
                self.log.unlink(missing_ok=True)
                if budget is None:
                    self.environment.pop("CMAKE_BUILD_PARALLEL_LEVEL", None)
                else:
                    self.environment["CMAKE_BUILD_PARALLEL_LEVEL"] = budget
                result = self.run_command(
                    ["sh", str(ROOT / "do_build.sh"), *arguments], self.root
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("make -j " + expected + " cap=", self.log.read_text())
        for arguments in (
            ["-j"],
            ["-j10"],
            ["-j", "3"],
            ["--jobs=10"],
            ["all", "-j10"],
        ):
            self.log.unlink(missing_ok=True)
            result = self.run_command(
                ["sh", str(ROOT / "do_build.sh"), *arguments], self.root
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.log.exists())

    def test_non_c_asset_make_is_unchanged(self) -> None:
        makefile = self.root / "assets.mk"
        makefile.write_text("all:\n\t@printf 'asset-only\\n'\n")
        result = self.run_command(["/usr/bin/make", "-f", str(makefile)], self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "asset-only\n")
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
