"""Tests for kit/linux/dayzero.py and kit/linux/install-kit.sh (python3 -m unittest)."""

import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
KIT = os.path.join(REPO, "kit", "linux")
sys.path.insert(0, KIT)
sys.dont_write_bytecode = True
import dayzero  # noqa: E402


def catalog():
    with open(os.path.join(KIT, "apps.json"), encoding="utf-8") as f:
        return json.load(f)


class PlanTests(unittest.TestCase):
    def setUp(self):
        dayzero.load_language("en")

    def ids(self, steps):
        return [s["id"] for s in steps]

    def test_every_plan_starts_with_network_and_updates(self):
        for mode in ("gaming", "office", "everything", "custom"):
            steps = dayzero.build_plan({"defaultMode": mode}, catalog(), "/nonexistent")
            self.assertEqual(self.ids(steps)[:3], ["network", "apt-update", "apt-upgrade"], mode)

    def test_gaming_installs_steam_and_not_libreoffice(self):
        ids = self.ids(dayzero.build_plan({"defaultMode": "gaming"}, catalog(), "/nonexistent"))
        self.assertIn("app-steam", ids)
        self.assertNotIn("app-libreoffice", ids)
        self.assertLess(ids.index("flathub"), ids.index("app-steam"))

    def test_everything_installs_every_app(self):
        steps = dayzero.build_plan({"defaultMode": "everything"}, catalog(), "/nonexistent")
        apps = [s for s in steps if s["id"].startswith("app-")]
        self.assertEqual(len(apps), len(catalog()["apps"]))

    def test_custom_installs_only_the_picks(self):
        ids = self.ids(dayzero.build_plan({"defaultMode": "custom", "apps": ["vlc"]}, catalog(), "/nonexistent"))
        self.assertEqual([i for i in ids if i.startswith("app-")], ["app-vlc"])
        none = self.ids(dayzero.build_plan({"defaultMode": "custom"}, catalog(), "/nonexistent"))
        self.assertNotIn("flathub", none)

    def test_drivers_can_be_left_out(self):
        self.assertIn("drivers", self.ids(dayzero.build_plan({}, catalog(), "/x")))
        self.assertNotIn("drivers", self.ids(dayzero.build_plan({"installDrivers": False}, catalog(), "/x")))

    def test_bad_ids_in_the_catalog_are_refused(self):
        bad = {"apps": [{"id": "x", "name": "X", "flatpak": "com.x;rm -rf /", "modes": ["gaming"]}]}
        with self.assertRaises(ValueError):
            dayzero.build_plan({"defaultMode": "gaming"}, bad, "/x")
        bad = {"apps": [{"id": "x", "name": "X", "apt": "foo bar", "modes": ["gaming"]}]}
        with self.assertRaises(ValueError):
            dayzero.build_plan({"defaultMode": "gaming"}, bad, "/x")

    def test_commands_are_argument_lists_never_shell_strings(self):
        for s in dayzero.build_plan({"defaultMode": "everything"}, catalog(), "/x"):
            if s["kind"] == "cmd":
                self.assertIsInstance(s["cmd"], list)
                self.assertNotIn(s["cmd"][0], ("sh", "/bin/sh"))

    def test_user_scripts_run_in_name_order_after_the_apps(self):
        d = tempfile.mkdtemp()
        try:
            for n in ("20-b.sh", "01-a.sh", "notes.txt"):
                open(os.path.join(d, n), "w").close()
            ids = self.ids(dayzero.build_plan({"defaultMode": "gaming"}, catalog(), d))
            self.assertEqual([i for i in ids if i.startswith("script-")], ["script-01-a.sh", "script-20-b.sh"])
            self.assertGreater(ids.index("script-01-a.sh"), ids.index("app-steam"))
        finally:
            shutil.rmtree(d)

    def test_nothing_turns_off_updates(self):
        for s in dayzero.build_plan({"defaultMode": "everything"}, catalog(), "/x"):
            text = " ".join(s.get("cmd") or [])
            self.assertNotRegex(text, r"unattended-upgrades|apt-mark hold|ufw disable|mask")


class RunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        dayzero.LOG_DIR = self.tmp
        dayzero.LOG_FILE = os.path.join(self.tmp, "setup.log")
        dayzero.load_language("en")
        self.steps = [
            {"id": "network", "title": "Waiting for the internet", "kind": "network"},
            {"id": "a", "title": "A", "kind": "cmd", "cmd": ["true"]},
            {"id": "b", "title": "Installing {0}", "args": ["B"], "kind": "cmd", "cmd": ["false"]},
        ]
        self._out = sys.stdout
        sys.stdout = io.StringIO()

    def tearDown(self):
        sys.stdout = self._out
        shutil.rmtree(self.tmp)

    def test_resumes_and_stops_after_three_attempts(self):
        calls = []

        def runner(step, dry):
            calls.append(step["id"])
            return 0 if step["id"] == "a" else 1

        state = {}
        dayzero.run_plan(self.steps, state, runner=runner, network=lambda: True)
        self.assertEqual(calls, ["a", "b"])
        self.assertFalse(dayzero.is_finished(self.steps, state))
        dayzero.run_plan(self.steps, state, runner=runner, network=lambda: True)
        dayzero.run_plan(self.steps, state, runner=runner, network=lambda: True)
        self.assertEqual(calls, ["a", "b", "b", "b"])
        self.assertTrue(dayzero.is_finished(self.steps, state))
        dayzero.run_plan(self.steps, state, runner=runner, network=lambda: True)
        self.assertEqual(len(calls), 4)

    def test_no_internet_stops_before_anything_else(self):
        calls = []
        state = dayzero.run_plan(self.steps, {}, runner=lambda s, d: calls.append(s) or 0, network=lambda: False)
        self.assertEqual(calls, [])
        self.assertEqual(state["steps"]["network"]["status"], "failed")

    def test_dry_run_runs_nothing(self):
        state = dayzero.run_plan(self.steps, {}, dry_run=True)
        self.assertTrue(all(r["status"] == "done" for r in state["steps"].values()))

    def test_log_is_english_and_summary_is_translated(self):
        state = dayzero.run_plan(self.steps, {}, runner=lambda s, d: 0 if s["id"] == "a" else 1, network=lambda: True)
        with open(dayzero.LOG_FILE, encoding="utf-8") as f:
            self.assertIn("== Installing B", f.read())
        dayzero.load_language("ru", os.path.join(REPO, "kit"))
        lines = dayzero.summary_lines(self.steps, state)
        self.assertRegex(lines[0], "[Ѐ-ӿ]")
        self.assertTrue(any("B" in l and "Устан" in l for l in lines))
        dayzero.load_language("en")


class InstallKitTests(unittest.TestCase):
    def test_copies_the_kit_and_turns_on_the_service(self):
        if not shutil.which("sh"):
            self.skipTest("no sh")
        tmp = tempfile.mkdtemp()
        try:
            stick = os.path.join(tmp, "stick", "dayzero")
            shutil.copytree(KIT, stick, ignore=shutil.ignore_patterns("__pycache__", "test_*"))
            with open(os.path.join(stick, "settings.json"), "w") as f:
                json.dump({"buildId": "0123abcd", "userName": "ivan", "temporaryPassword": False}, f, indent=2)
            target = os.path.join(tmp, "target")
            os.makedirs(os.path.join(target, "etc", "systemd", "system"))
            r = subprocess.run(["sh", os.path.join(stick, "install-kit.sh"), target])
            self.assertEqual(r.returncode, 0)
            self.assertTrue(os.path.isfile(os.path.join(target, "opt", "dayzero", "dayzero.py")))
            self.assertTrue(os.path.isfile(os.path.join(target, "etc", "systemd", "system", "dayzero-setup.service")))
            link = os.path.join(target, "etc", "systemd", "system", "multi-user.target.wants", "dayzero-setup.service")
            self.assertEqual(os.readlink(link), "/etc/systemd/system/dayzero-setup.service")
            self.assertTrue(os.path.isfile(os.path.join(target, "etc", "xdg", "autostart", "dayzero-progress.desktop")))
            with open(os.path.join(target, "var", "log", "dayzero", "install.log")) as f:
                self.assertIn("done", f.read())
        finally:
            shutil.rmtree(tmp)

    def test_never_fails_the_install(self):
        tmp = tempfile.mkdtemp()
        try:
            r = subprocess.run(["sh", os.path.join(KIT, "install-kit.sh"), os.path.join(tmp, "nothing-here")])
            self.assertEqual(r.returncode, 0)
        finally:
            shutil.rmtree(tmp)

    def test_kit_files_use_lf_line_endings(self):
        for name in os.listdir(KIT):
            if name.endswith((".sh", ".py", ".service", ".desktop")):
                with open(os.path.join(KIT, name), "rb") as f:
                    self.assertNotIn(b"\r\n", f.read(), name)


if __name__ == "__main__":
    unittest.main()
