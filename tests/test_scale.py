"""Scaling through the JSON configuration interface, using Quickshell offscreen."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("qs"), "JSON settings checks require Quickshell")
class ScalingConfigTests(unittest.TestCase):
    def check_config(self, settings, expected):
        with tempfile.TemporaryDirectory(prefix="aial-config-") as directory:
            path = Path(directory, "config.json")
            path.write_text(settings if isinstance(settings, str) else json.dumps(settings))
            runtime = Path(directory, "runtime")
            runtime.mkdir(mode=0o700)
            env = dict(os.environ, QT_QPA_PLATFORM="offscreen", AIAL_SOURCE_DIR=str(ROOT),
                       APPLESEARCH_CONFIG=str(path), AIAL_EXPECT_CONFIG=json.dumps(expected),
                       XDG_RUNTIME_DIR=str(runtime), XDG_CACHE_HOME=str(Path(directory, "cache")))
            for name in ("WAYLAND_DISPLAY", "DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE"):
                env.pop(name, None)
            result = subprocess.run(
                ["qs", "--path", str(ROOT / "tests/config-check.qml"), "--no-color"],
                env=env,
                capture_output=True, text=True, timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_scale_is_configurable_without_changing_base_dimensions(self):
        self.check_config({"scale": 0.7}, {
            "scale": 0.7, "width": 680, "rows": 7,
            "fontSize": 15, "searchFontSize": 24, "topOffset": 0.22,
        })

    def test_scale_defaults_to_one(self):
        self.check_config({}, {"scale": 1})

    def test_scale_accepts_fractions_and_clamps_numeric_limits(self):
        for value, expected in ((0.73, 0.73), (0, 0.5), (-3, 0.5), (0.5, 0.5), (2, 2), (9, 2)):
            with self.subTest(value=value):
                self.check_config({"scale": value}, {"scale": expected})

    def test_invalid_scale_types_and_nonfinite_values_use_default(self):
        for value in ("0.7", None, True, [], {}):
            with self.subTest(value=value):
                self.check_config({"scale": value}, {"scale": 1})
        self.check_config('{"scale": 1e999}', {"scale": 1})


@unittest.skipUnless(os.environ.get("AIAL_LIVE_TESTS") == "1"
                     and os.environ.get("WAYLAND_DISPLAY") and shutil.which("qs"),
                     "Set AIAL_LIVE_TESTS=1 in a Wayland session for launcher checks")
class ScalingLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="aial-layout-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.source = self.directory / "source"
        self.source.mkdir()
        for name in ("shell.qml", "Config.qml", "Theme.qml", "Spring.qml", "rofi-search.js"):
            shutil.copy2(ROOT / name, self.source / name)
        shutil.copytree(ROOT / "fonts", self.source / "fonts")
        self.settings = self.directory / "config.json"
        self.settings.write_text('{"scale": 0.7}')
        self.log = (self.directory / "quickshell.log").open("w+")
        self.addCleanup(self.log.close)
        self.process = subprocess.Popen(
            ["qs", "--path", str(self.source), "--no-color"],
            env=dict(os.environ, APPLESEARCH_CONFIG=str(self.settings), APPLESEARCH_HIDDEN="1",
                     APPLESEARCH_NAMESPACE="aial-scale-test-" + self.directory.name,
                     XDG_CACHE_HOME=str(self.directory / "cache")),
            stdin=subprocess.DEVNULL, stdout=self.log, stderr=subprocess.STDOUT,
        )
        self.addCleanup(self.stop_launcher)
        self.await_state(lambda state: state["apps"] > 0)

    def stop_launcher(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)

    def ipc(self, method, *arguments):
        return subprocess.run(
            ["qs", "ipc", "--pid", str(self.process.pid), "call", "spotlight", method, *arguments],
            capture_output=True, text=True, timeout=5,
        )

    def await_state(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.log.flush()
                self.log.seek(0)
                self.fail("Launcher exited: " + self.log.read())
            result = self.ipc("state")
            try:
                last = json.loads(result.stdout)
            except json.JSONDecodeError:
                time.sleep(0.02)
                continue
            if predicate(last):
                return last
            time.sleep(0.02)
        self.fail("Launcher did not reach the expected state: " + json.dumps(last))

    def test_empty_search_and_surface_shrink_together(self):
        state = self.await_state(lambda state: not state["visible"])
        self.assertAlmostEqual(state["height"], 75.6, places=2)
        self.assertEqual(state["surfaceHeight"], 391)
        self.assertEqual(state["geometry"]["surfaceWidth"], 476)
        for key, expected in {"x": 11.2, "y": 8.4, "width": 453.6, "height": 50.4}.items():
            self.assertAlmostEqual(state["geometry"]["card"][key], expected, places=2)
            self.assertAlmostEqual(state["geometry"]["mask"][key], expected, delta=1.5)

    def test_setting_scale_to_one_restores_upstream_geometry_live(self):
        self.settings.write_text('{}')
        state = self.await_state(lambda state: state["config"]["scale"] == 1
                                 and state["geometry"]["surfaceWidth"] == 680
                                 and state["surfaceHeight"] == 558)
        self.assertAlmostEqual(state["height"], 108, places=2)
        for key, expected in {"x": 16, "y": 12, "width": 648, "height": 72}.items():
            self.assertAlmostEqual(state["geometry"]["card"][key], expected, places=2)

    def test_surface_stays_on_screen_when_scaled_up(self):
        self.settings.write_text('{"scale": 2, "width": 1600, "rows": 12}')
        state = self.await_state(lambda state: state["config"]["scale"] == 2)
        monitors = json.loads(subprocess.check_output(['hyprctl', '-j', 'monitors'], text=True))
        monitor = next(monitor for monitor in monitors if monitor['name'] == state['screen'])
        self.assertLessEqual(state['geometry']['surfaceWidth'], monitor['width'] / monitor['scale'] - 48)
        self.assertLessEqual(state['surfaceHeight'], monitor['height'] / monitor['scale'])
        self.assertGreater(state['geometry']['card']['height'], 0)

    def test_first_menu_open_uses_the_configured_surface_height(self):
        lines = self.directory / 'lines'
        result = self.directory / 'result'
        lines.write_text('One item\n')
        request = self.ipc('showMenu', str(lines), str(result), '')
        self.assertEqual(request.returncode, 0, request.stdout + request.stderr)
        self.await_state(lambda state: state['menu'] and state['visible']
                         and abs(state['geometry']['card']['height'] - 54.6) < 0.02)

    @unittest.skipUnless(shutil.which("wtype"), "Keyboard checks require wtype")
    def test_scaled_menu_rows_scroll_and_keyboard_selection_still_works(self):
        lines = self.directory / "lines"
        result = self.directory / "result"
        lines.write_text(''.join(f'Item {index:02}\n' for index in range(10)))
        request = self.ipc("showMenu", str(lines), str(result), "")
        self.assertEqual(request.returncode, 0, request.stdout + request.stderr)
        state = self.await_state(lambda state: state["menu"] and state["visible"]
                                 and abs(state["geometry"]["firstRow"]["height"] - 43.4) < 0.02
                                 and abs(state["geometry"]["card"]["height"] - 315) < 0.02
                                 and state["focus"]["navigation"] and state["focus"]["grabbed"])
        self.assertEqual(len(state['results']), 10)
        for selected in range(1, 10):
            subprocess.run(['wtype', '-k', 'Down'], check=True, timeout=5)
            state = self.await_state(lambda state, selected=selected: state['selected'] == selected
                                     and state['focus']['navigation'])
        self.assertEqual(state['scroll'], 186)
        subprocess.run(['wtype', '-k', 'Return'], check=True, timeout=5)
        self.await_state(lambda state: not state['visible'])
        self.assertEqual(result.read_text(), 'selected\nItem 09\n')

if __name__ == "__main__":
    unittest.main()
