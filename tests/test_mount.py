"""Kernel FUSE integration test; skips only when mounting is unavailable."""

import errno
from contextlib import contextmanager
import hashlib
import io
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import time
import unittest
import zipfile

from image_fixtures import PROFILES, make_image
from reference_image import files as reference_files, isolated_files, ceres_salvage_files


ROOT = Path(__file__).resolve().parents[1]


@contextmanager
def mounted(image, *options, env=None, expected_exit=0):
    unmount = shutil.which("fusermount3")
    if not unmount:
        raise unittest.SkipTest("fusermount3 not installed")
    try:
        fd = os.open("/dev/fuse", os.O_RDWR)
        os.close(fd)
    except OSError as error:
        raise unittest.SkipTest(f"/dev/fuse unavailable: {error}") from error
    directory = Path(tempfile.mkdtemp(prefix="mount-", dir=ROOT / "build"))
    mountpoint = directory / "mnt"
    mountpoint.mkdir()
    process = subprocess.Popen([str(ROOT / "build/oberon-fuse"), str(image), str(mountpoint), *map(str, options)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    completed = False
    try:
        deadline = time.monotonic() + 10
        while not os.path.ismount(mountpoint) and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        if not os.path.ismount(mountpoint):
            if process.poll() is None:
                process.terminate()
            _, error = process.communicate(timeout=10)
            if b"Operation not permitted" in error or b"Permission denied" in error:
                raise unittest.SkipTest(error.decode().strip())
            raise AssertionError(f"mount failed: {error.decode()}")
        yield mountpoint
        completed = True
    finally:
        try:
            # A disconnected FUSE mount can make ismount return False.
            result = subprocess.run([unmount, "-u", str(mountpoint)], capture_output=True, timeout=10)
            if result.returncode and os.path.ismount(mountpoint):
                raise RuntimeError(result.stderr.decode())
        finally:
            try:
                output, error = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate()
                output, error = process.communicate(timeout=10)
            if process.returncode and process.returncode != expected_exit:
                print(f"FUSE exited {process.returncode}: {output.decode().strip()} {error.decode().strip()}")
        # Never recursively clean a directory that is still mounted.
        if os.path.ismount(mountpoint):
            raise RuntimeError(f"test mount remains active: {mountpoint}")
        mountpoint.rmdir()
        directory.rmdir()
        if completed and expected_exit is not None and process.returncode != expected_exit:
            raise AssertionError(f"FUSE exit {process.returncode}, expected {expected_exit}: {output!r} {error!r}")


class Mount(unittest.TestCase):
    def test_ceres_in_place_repair(self):
        image = Path(os.environ.get("CERES_IMAGE", ROOT / "disks/ceres/ceres.dat"))
        if not image.exists():
            self.skipTest("Ceres dump not installed")
        before = hashlib.sha256(image.read_bytes()).digest()
        expected = ceres_salvage_files(image)
        with tempfile.TemporaryDirectory(prefix="ceres-inplace-mount-", dir=ROOT / "build") as temp:
            working = Path(temp) / "working.img"
            subprocess.run(["dd", f"if={image}", f"of={working}", "bs=1M", "conv=excl", "status=none"], check=True, timeout=30)
            inode = working.stat().st_ino
            subprocess.run([str(ROOT / "build/oberon-image"), "repair", str(working), "--in-place", "--drop-invalid", "ceres"], check=True, capture_output=True, timeout=60)
            self.assertEqual(working.stat().st_ino, inode)
            repaired_hash = hashlib.sha256(working.read_bytes()).digest()
            with mounted(working, "ceres") as mountpoint:
                self.assertEqual({p.name for p in mountpoint.iterdir()}, set(expected))
                for name, data in expected.items():
                    self.assertEqual((mountpoint / name).read_bytes(), data, name)
            self.assertEqual(hashlib.sha256(working.read_bytes()).digest(), repaired_hash)
        self.assertEqual(hashlib.sha256(image.read_bytes()).digest(), before)

    def test_dd_format_and_mount(self):
        with tempfile.TemporaryDirectory(prefix="dd-format-mount-", dir=ROOT / "build") as temp:
            for profile in PROFILES:
                with self.subTest(profile=profile):
                    image = Path(temp) / f"{profile}.img"
                    subprocess.run(["dd", "if=/dev/zero", f"of={image}", "bs=1M", "count=2", "conv=excl", "status=none"], check=True, timeout=30)
                    subprocess.run([str(ROOT / "build/oberon-image"), "mkfs", profile, str(image), "--in-place"], check=True, capture_output=True, timeout=30)
                    before = image.read_bytes()
                    with mounted(image, profile) as mountpoint:
                        self.assertEqual(list(mountpoint.iterdir()), [])
                        with self.assertRaises(OSError) as raised:
                            (mountpoint / "new-file").write_bytes(b"still read-only")
                        self.assertIn(raised.exception.errno, (errno.EROFS, errno.EACCES))
                    self.assertEqual(image.read_bytes(), before)

    def test_mounted_image_refuses_updates(self):
        with tempfile.TemporaryDirectory(prefix="mounted-update-", dir=ROOT / "build") as temp:
            image = Path(temp) / "working.img"
            data, files, _, root = make_image("ceres", large=False)
            image.write_bytes(data)
            with mounted(image, "ceres", root) as mountpoint:
                for args in (("repair", str(image), "--in-place", "--drop-invalid", "ceres", str(root)),
                             ("mkfs", "ceres", str(image), "--in-place")):
                    result = subprocess.run([str(ROOT / "build/oberon-image"), *args], capture_output=True, timeout=30)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn(b"Resource temporarily unavailable", result.stderr)
                self.assertEqual({p.name for p in mountpoint.iterdir()}, set(files))
            self.assertEqual(image.read_bytes(), data)
            self.assertFalse(Path(str(image) + ".repair.txt").exists())

    def test_ceres_salvage_and_repaired_copy(self):
        image = Path(os.environ.get("CERES_IMAGE", ROOT / "disks/ceres/ceres.dat"))
        if not image.exists():
            self.skipTest("Ceres dump not installed")
        before = hashlib.sha256(image.read_bytes()).digest()
        expected = ceres_salvage_files(image)
        with mounted(image, "--salvage", "ceres") as mountpoint:
            self.assertEqual({p.name for p in mountpoint.iterdir()}, set(expected))
            for name, data in expected.items():
                self.assertEqual((mountpoint / name).read_bytes(), data, name)
            self.assertFalse((mountpoint / "Ceres1.Boot").exists())
            self.assertFalse((mountpoint / "ET.Mod2").exists())
        with tempfile.TemporaryDirectory(prefix="ceres-repair-mount-", dir=ROOT / "build") as temp:
            output = Path(temp) / "repaired.img"
            subprocess.run([str(ROOT / "build/oberon-image"), "repair", str(image), str(output), "--drop-invalid", "ceres"], check=True, capture_output=True, timeout=60)
            repaired_hash = hashlib.sha256(output.read_bytes()).digest()
            with mounted(output, "ceres") as mountpoint:
                self.assertEqual({p.name for p in mountpoint.iterdir()}, set(expected))
                for name, data in expected.items():
                    self.assertEqual((mountpoint / name).read_bytes(), data, name)
            self.assertEqual(hashlib.sha256(output.read_bytes()).digest(), repaired_hash)
        self.assertEqual(hashlib.sha256(image.read_bytes()).digest(), before)

    def test_salvage_mount(self):
        with tempfile.TemporaryDirectory(prefix="salvage-", dir=ROOT / "build") as directory:
            for profile in PROFILES:
                with self.subTest(profile=profile):
                    bs, _, names, _, _, _, _, short = PROFILES[profile]
                    image, files, headers, root = make_image(profile)
                    offset = root + (headers["B.Small"] // 29 - 1) * bs + names + 4
                    struct.pack_into("<HH" if short else "<II", image, offset, 0, 0)
                    path = Path(directory) / "image.img"
                    path.write_bytes(image)
                    expected = {name: data for name, data in files.items() if name != "B.Small"}
                    with mounted(path, "--salvage", profile, root) as mountpoint:
                        self.assertEqual({p.name for p in mountpoint.iterdir()}, set(expected))
                        for name, data in expected.items():
                            self.assertEqual((mountpoint / name).read_bytes(), data, name)
                        with self.assertRaises(FileNotFoundError):
                            (mountpoint / "B.Small").read_bytes()
                        with self.assertRaises(OSError) as raised:
                            (mountpoint / "new-file").write_bytes(b"no writes")
                        self.assertIn(raised.exception.errno, (errno.EROFS, errno.EACCES))
                    self.assertEqual(path.read_bytes(), image)

    def test_ceres_file_records(self):
        image = Path(os.environ.get("CERES_IMAGE", ROOT / "disks/ceres/ceres.dat"))
        extracted = Path(os.environ.get("CERES_FILES", ROOT / "disks/ceres/ceres_xt2190_files.zip"))
        if not image.exists() or not extracted.exists():
            self.skipTest("Ceres dump and extracted-file archive not installed")
        before = hashlib.sha256(image.read_bytes()).digest()
        with zipfile.ZipFile(extracted) as archive:
            chosen = [i.filename for i in sorted(archive.infolist(), key=lambda i: -i.file_size)[:3]]
            with tempfile.TemporaryDirectory(prefix="ceres-records-", dir=ROOT / "build") as temp:
                fixture = Path(temp) / "isolated.img"
                fixture.write_bytes(isolated_files(image, "ceres", 1024, chosen))
                with mounted(fixture, "ceres") as mountpoint:
                    self.assertEqual({p.name for p in mountpoint.iterdir()}, set(chosen))
                    for name in chosen:
                        self.assertEqual((mountpoint / name).read_bytes(), archive.read(name), name)
        self.assertEqual(hashlib.sha256(image.read_bytes()).digest(), before)

    def test_mount(self):
        with tempfile.TemporaryDirectory(prefix="fixtures-", dir=ROOT / "build") as directory:
            for profile in ("project", "natfs", "ceres", "aos1", "aos2"):
                with self.subTest(profile=profile):
                    image, files, _, root = make_image(profile)
                    path = Path(directory) / "image.img"
                    path.write_bytes(image)
                    with mounted(path, profile, root) as mountpoint:
                        self.assertEqual(sorted(p.name for p in mountpoint.iterdir()), sorted(files))
                        for name, expected in files.items():
                            with (mountpoint / name).open("rb") as f:
                                self.assertEqual(f.read(), expected)
                                self.assertEqual(os.pread(f.fileno(), 99, 4294967296), b"")
                        with self.assertRaises(OSError) as raised:
                            (mountpoint / "new-file").write_bytes(b"no writes")
                        self.assertIn(raised.exception.errno, (errno.EROFS, errno.EACCES))

    def test_preservation_images(self):
        cases = [
            (ROOT / "disks/po13/RISC.img", "project", 268436480, 60),
            (ROOT / "disks/no/Oberon0.Dsk", "natfs", 251392, 2),
            (ROOT / "disks/no/OberonCF0.Dsk", "natfs", 251392, 2),
            (ROOT / "disks/no/NativeOberon-2.3.6.img", "natfs", 36352, 1159),
            (ROOT / "disks/no/NativeOberon-2003-01-05.img", "aos1", 560640, 1331),
            (Path(os.environ.get("A2_IMAGE", "/tmp/A2_Rev-6498_serial-trace.iso")), "aos2", 1099776, 2516),
        ]
        available = 0
        for image, profile, root, count in cases:
            with self.subTest(image=image):
                if not image.exists() or image.stat().st_size == 0:
                    continue
                available += 1
                before = hashlib.sha256(image.read_bytes()).digest()
                with mounted(image) as mountpoint:
                    names = {p.name for p in mountpoint.iterdir()}
                    self.assertEqual(len(names), count)
                    visited = set()
                    for name, expected in reference_files(image, profile, root):
                        with self.subTest(file=name):
                            data = (mountpoint / name).read_bytes()
                            self.assertEqual(data, expected)
                            visited.add(name)
                            if name.lower().endswith(".zip"):
                                with zipfile.ZipFile(io.BytesIO(data)) as archive:
                                    self.assertIsNone(archive.testzip())
                    self.assertEqual(names, visited)
                self.assertEqual(hashlib.sha256(image.read_bytes()).digest(), before)
        if not available:
            self.skipTest("preservation images not installed")


if __name__ == "__main__":
    unittest.main(verbosity=2)
