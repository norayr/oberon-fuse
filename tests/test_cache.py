"""Read-cache host I/O and mount-option regressions; no physical media."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Cache(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cache-", dir=ROOT / "build")
        self.directory = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_hits_shared_images_and_partial_write_invalidation(self):
        for mode in ("normal", "partial", "failed-read"):
            with self.subTest(mode=mode):
                image = self.directory / f"{mode}.img"
                original = b"A" * 1024 + b"B" * 1024 + b"C" * 2048
                image.write_bytes(original)
                env = dict(os.environ)
                if mode != "normal":
                    env.update(LD_PRELOAD=str(ROOT / "build/FailIO.so"), OBERON_TEST_IMAGE=str(image))
                    if mode == "partial":
                        env["OBERON_TEST_WRITE_OFFSET"] = "0"
                    else:
                        env["OBERON_TEST_READ_OFFSET"] = "0"
                result = subprocess.run([str(ROOT / "build/CacheIOProbe"), str(image), mode], env=env, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
                if mode == "failed-read":
                    self.assertEqual(image.read_bytes(), original)

    def test_invalid_cache_options(self):
        for value in ("-1", "257", "999999999999999999999", "one", "1.5", ""):
            with self.subTest(value=value):
                result = subprocess.run([str(ROOT / "build/oberon-fuse"), "missing.img", "mnt", "--cache-mib", value], capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 2, result.stderr)
        for options in (["--cache-mib"], ["--cache-mib", "1", "--cache-mib", "2"]):
            result = subprocess.run([str(ROOT / "build/oberon-fuse"), "missing.img", "mnt", *options], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 2, result.stderr)

    def test_valid_cache_options(self):
        for value in ("0", "1", "32", "256"):
            result = subprocess.run([str(ROOT / "build/oberon-fuse"), str(self.directory / "missing.img"), "mnt", "--cache-mib", value, "--utc-offset", "120", "aos2"], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn(b"No such file", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
