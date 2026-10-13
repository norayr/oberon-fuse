"""Filesystem writer and device guard tests without mounting or physical media."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from image_fixtures import PROFILES, make_image
from reference_image import files as reference_files

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "build/oberon-image"
PROBE = ROOT / "build/WriteProbe"


class Writes(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="writes-", dir=ROOT / "build")
        self.directory = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def fixture(self, profile):
        image, _, _, root = make_image(profile, files={"File": b"original bytes"})
        image.extend(bytes(3 * 1024 * 1024))
        path = self.directory / f"{profile}.img"
        path.write_bytes(image)
        return path, root

    def test_writer_without_fuse(self):
        for profile in PROFILES:
            with self.subTest(profile=profile):
                path, root = self.fixture(profile)
                count = 700000
                subprocess.run([str(PROBE), str(path), profile, "write", str(count)], check=True, capture_output=True)
                expected = (bytes(i % 251 for i in range(4096)) * ((count + 4095) // 4096))[:count]
                self.assertEqual(dict(reference_files(path, profile, root)), {"File": expected})
                subprocess.run([str(TOOL), "check", str(path), profile], check=True, capture_output=True)

    def test_partial_spare_block_failure_keeps_old_file(self):
        for profile in PROFILES:
            with self.subTest(profile=profile):
                path, root = self.fixture(profile)
                bs = PROFILES[profile][0]
                env = dict(os.environ, LD_PRELOAD=str(ROOT / "build/FailIO.so"),
                           OBERON_TEST_IMAGE=str(path), OBERON_TEST_WRITE_OFFSET=str(root + 2 * bs))
                result = subprocess.run([str(PROBE), str(path), profile, "write", "100000"], env=env, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 1, (result.stdout, result.stderr))
                self.assertIn(b"Input/output error", result.stderr)
                self.assertEqual(dict(reference_files(path, profile, root)), {"File": b"original bytes"})
                subprocess.run([str(TOOL), "check", str(path), profile], check=True, capture_output=True)

    def test_sync_failure_before_root_keeps_old_directory(self):
        path, root = self.fixture("aos2")
        original_root = path.read_bytes()[root:root + 4096]
        # First sync invalidates the cache; second sync precedes root publication.
        env = dict(os.environ, LD_PRELOAD=str(ROOT / "build/FailIO.so"),
                   OBERON_TEST_IMAGE=str(path), OBERON_TEST_SYNC_CALL="2")
        result = subprocess.run([str(PROBE), str(path), "aos2", "write", "10000"], env=env, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1, (result.stdout, result.stderr))
        self.assertEqual(path.read_bytes()[root:root + 4096], original_root)
        self.assertEqual(dict(reference_files(path, "aos2", root)), {"File": b"original bytes"})

    def test_device_flags_reject_regular_files_aliases_and_fifos(self):
        path, _ = self.fixture("aos2")
        alias = self.directory / "alias"
        alias.symlink_to(path)
        fifo = self.directory / "fifo"
        os.mkfifo(fifo)
        mountpoint = self.directory / "mountpoint"
        mountpoint.mkdir()
        before = path.read_bytes()
        for selected in (path, alias, fifo, self.directory / "missing", Path("/dev/null")):
            for command in ([str(TOOL), "mkfs", "aos2", str(selected), "--erase-device"],
                            [str(TOOL), "check", str(selected), "--device", "aos2"],
                            [str(ROOT / "build/oberon-fuse"), str(selected), str(mountpoint), "--device", "--rw", "aos2"]):
                with self.subTest(command=command):
                    result = subprocess.run(command, capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertEqual(path.read_bytes(), before)

    def test_bad_detection_is_refused_without_dereferencing_entries(self):
        path = self.directory / "bad.img"
        path.write_bytes(bytes(1024 * 1024))
        result = subprocess.run([str(PROBE), str(path), "aos2", "write", "10"], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1, (result.stdout, result.stderr))
        self.assertNotIn(b"Halt", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
