# C2: 小鹤双拼与全拼都能出词，快捷键与界面（写 qi_schema.txt）都能切换，且所有会话一致。
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HARNESS = os.path.join(ROOT, "build", "rime_harness")
DATA = os.path.join(ROOT, "build", "rime-data")
FLYPY, QUANPIN = "double_pinyin_flypy", "rime_ice"


def build():
    subprocess.run([os.path.join(ROOT, "scripts", "rime_data.sh")], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(
        ["clang", "-O1", "-I/opt/homebrew/opt/librime/include", "-L/opt/homebrew/opt/librime/lib",
         "-lrime", os.path.join(ROOT, "tests", "rime", "harness.c"), "-o", HARNESS],
        check=True,
    )


class Rime:
    def __init__(self, user, deploy=False):
        args = [HARNESS, DATA, user, os.path.join(user, "build")] + (["deploy"] if deploy else [])
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True)

    def cmd(self, line):
        assert self.p.stdin and self.p.stdout
        self.p.stdin.write(line + "\n")
        self.p.stdin.flush()
        return self.p.stdout.readline().rstrip("\n")

    def close(self):
        assert self.p.stdin
        self.p.stdin.close()
        self.p.wait()


class SwitchTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build()
        cls.user = tempfile.mkdtemp(prefix="qi-rime-")
        Rime(cls.user, deploy=True).close()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.user, ignore_errors=True)

    def setUp(self):
        with open(os.path.join(self.user, "qi_schema.txt"), "w") as f:
            f.write(f"{FLYPY} reset-{self.id()}\n")
        self.r = Rime(self.user)
        self.r.cmd("keys {Escape}")

    def tearDown(self):
        self.r.close()

    def first_candidate(self, keys):
        self.r.cmd("keys {Escape}")
        self.r.cmd("keys " + keys)
        cands = self.r.cmd("cands").split("|")
        self.r.cmd("keys {Escape}")
        return cands[0]

    def test_flypy_is_default_and_types(self):
        self.assertEqual(self.r.cmd("schema"), FLYPY)
        self.assertEqual(self.first_candidate("nihc"), "你好")
        self.assertEqual(self.first_candidate("wode"), "我的")

    def test_hotkey_toggles_both_ways(self):
        self.r.cmd("keys {Control+Shift+1}")
        self.assertEqual(self.r.cmd("schema"), QUANPIN)
        self.assertEqual(self.first_candidate("nihao"), "你好")
        self.r.cmd("keys {Control+Shift+1}")
        self.assertEqual(self.r.cmd("schema"), FLYPY)
        self.assertEqual(self.first_candidate("nihc"), "你好")

    def test_interface_request_applies_on_next_key(self):
        self.assertEqual(self.r.cmd("schema"), FLYPY)
        with open(os.path.join(self.user, "qi_schema.txt"), "w") as f:
            f.write(f"{QUANPIN} ui-1\n")
        self.r.cmd("keys nihao")
        self.assertEqual(self.r.cmd("schema"), QUANPIN)
        self.assertEqual(self.r.cmd("cands").split("|")[0], "你好")

    def test_toolbar_option_switches_on_next_key(self):
        self.assertEqual(self.r.cmd("schema"), FLYPY)
        self.r.cmd("option qi_flypy 0")
        self.r.cmd("keys nihao")
        self.assertEqual(self.r.cmd("schema"), QUANPIN)
        self.assertEqual(self.r.cmd("cands").split("|")[0], "你好")
        self.r.cmd("keys {Escape}")
        self.r.cmd("option qi_flypy 1")
        self.r.cmd("keys nihc")
        self.assertEqual(self.r.cmd("schema"), FLYPY)
        self.assertEqual(self.r.cmd("cands").split("|")[0], "你好")

    def test_hotkey_is_recorded_for_interface_and_other_sessions(self):
        self.r.cmd("keys {Control+Shift+1}")
        with open(os.path.join(self.user, "qi_schema.txt")) as f:
            self.assertTrue(f.read().startswith(QUANPIN + " "))
        self.r.cmd("newsession")
        self.r.cmd("keys a")
        self.assertEqual(self.r.cmd("schema"), QUANPIN)


if __name__ == "__main__":
    unittest.main()
