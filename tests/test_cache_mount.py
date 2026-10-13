"""Cached FUSE reads and writes on disposable fixtures for every profile."""
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

from image_fixtures import PROFILES, make_image
from reference_image import files as reference_files
from test_mount import mounted, ROOT

TOOL = ROOT / "build/oberon-image"


class CachedMount(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cache-mount-", dir=ROOT / "build")
        self.directory = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def fixture(self, profile):
        _, files, _, _ = make_image(profile)
        files["D.Cache"] = bytes(range(256)) * 6144
        image, _, headers, root = make_image(profile, files=files)
        image.extend(bytes(8 * 1024 * 1024))
        path = self.directory / f"{profile}.img"
        path.write_bytes(image)
        return path, files, headers, root

    def test_cache_sizes_read_identical_bytes(self):
        for profile in PROFILES:
            path, files, _, root = self.fixture(profile)
            before = hashlib.sha256(path.read_bytes()).digest()
            for mib in (0, 1, 32):
                with self.subTest(profile=profile, mib=mib):
                    with mounted(path, "--cache-mib", mib, profile, root) as mountpoint:
                        self.assertEqual({p.name for p in mountpoint.iterdir()}, set(files))
                        for _ in range(2):
                            for name, expected in files.items():
                                with (mountpoint / name).open("rb") as stream:
                                    self.assertEqual(stream.read(), expected)
                                    self.assertEqual(os.pread(stream.fileno(), 3000, 37), expected[37:3037])
                    self.assertEqual(hashlib.sha256(path.read_bytes()).digest(), before)

    def test_cached_writes_block_reuse_and_directory_updates(self):
        for profile in PROFILES:
            with self.subTest(profile=profile):
                path, expected, _, root = self.fixture(profile)
                with mounted(path, "--rw", "--cache-mib", 1, profile, root) as mountpoint:
                    file = mountpoint / "D.Cache"
                    self.assertEqual(file.read_bytes(), expected["D.Cache"])
                    for generation in range(3):
                        data = bytes([generation + 7]) * (360017 + generation * 17000)
                        with file.open("wb") as stream:
                            stream.write(data)
                            stream.flush()
                            os.fsync(stream.fileno())
                        self.assertEqual(file.read_bytes(), data)
                        expected["D.Cache"] = data
                    file.rename(mountpoint / "Renamed")
                    expected["Renamed"] = expected.pop("D.Cache")
                    for i in range(36):
                        name = f"New{i:03d}"
                        expected[name] = str(i).encode()
                        (mountpoint / name).write_bytes(expected[name])
                    for i in range(0, 36, 2):
                        name = f"New{i:03d}"
                        (mountpoint / name).unlink()
                        del expected[name]
                    self.assertEqual({p.name: p.read_bytes() for p in mountpoint.iterdir()}, expected)
                subprocess.run([str(TOOL), "check", str(path), profile, str(root)], check=True, capture_output=True)
                self.assertEqual(dict(reference_files(path, profile, root)), expected)

    def test_cached_salvage(self):
        for profile in PROFILES:
            with self.subTest(profile=profile):
                path, expected, headers, root = self.fixture(profile)
                image = bytearray(path.read_bytes())
                bs, _, names, _, _, _, _, short = PROFILES[profile]
                offset = root + (headers["B.Small"] // 29 - 1) * bs + names + 4
                struct.pack_into("<HH" if short else "<II", image, offset, 0, 0)
                path.write_bytes(image)
                del expected["B.Small"]
                with mounted(path, "--cache-mib", 1, "--salvage", profile, root) as mountpoint:
                    self.assertEqual({p.name: p.read_bytes() for p in mountpoint.iterdir()}, expected)
                self.assertEqual(path.read_bytes(), image)


if __name__ == "__main__":
    unittest.main(verbosity=2)
