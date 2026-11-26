# C9: 两台设备各自学到的词，经「同步用户资料」导出的快照互相交换后，都能合并进对方的词库。
import glob
import os
import shutil
import tempfile
import unittest

from test_switch import DATA, Rime, build


def body(user):
    lines = []
    for p in glob.glob(os.path.join(user, "sync", "*", "rime_frost.userdb.txt")):
        lines += [l for l in open(p, encoding="utf-8").read().split("\n") if l and not l.startswith("#")]
    return set(lines)


class DictSyncTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build()

    def test_learned_words_reach_other_device(self):
        os.environ["QI_MAINT"] = "1"  # 与鼠须管一致：引擎先做过维护，同步任务才可用
        self.addCleanup(os.environ.pop, "QI_MAINT", None)
        a, b = tempfile.mkdtemp(prefix="qi-dict-a-"), tempfile.mkdtemp(prefix="qi-dict-b-")
        self.addCleanup(shutil.rmtree, a, True)
        self.addCleanup(shutil.rmtree, b, True)
        Rime(a, deploy=True).close()
        shutil.copytree(os.path.join(a, "build"), os.path.join(b, "build"))
        r = Rime(a)
        r.cmd("keys {Escape}")
        r.cmd("keys nihao")
        r.cmd("keys 1")
        self.assertTrue(r.cmd("commit"))
        self.assertEqual(r.cmd("sync"), "ok")
        r.close()
        learned = body(a)
        self.assertTrue(learned, "device A learned nothing")
        a_id = os.listdir(os.path.join(a, "sync"))[0]
        shutil.copytree(os.path.join(a, "sync", a_id), os.path.join(b, "sync", a_id))
        for _ in range(2):
            r = Rime(b)
            self.assertEqual(r.cmd("sync"), "ok")
            r.close()
        mine = {d for d in os.listdir(os.path.join(b, "sync")) if d != a_id}
        self.assertEqual(len(mine), 1)
        merged = set(open(os.path.join(b, "sync", mine.pop(), "rime_frost.userdb.txt"), encoding="utf-8").read().split("\n"))
        self.assertTrue(learned <= merged, "device B did not merge A's words")


if __name__ == "__main__":
    unittest.main()
