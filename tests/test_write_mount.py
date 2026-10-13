"""Writable kernel FUSE mounts on disposable files, never preservation media."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import errno
import fcntl
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

from image_fixtures import PROFILES, make_image
from reference_image import files as reference_files, directory as reference_directory
from test_mount import mounted, ROOT

TOOL = ROOT / "build/oberon-image"


def clock(profile, value):
    year = value.year - 2000 if profile == "project" else value.year % 100 if profile == "ceres" else value.year - 1900
    date = year * 512 + value.month * 32 + value.day
    time = value.hour * 4096 + value.minute * 64 + value.second
    return (date * 131072 + time, 0) if profile == "project" else (date, time)


def timestamps(path, profile, root):
    bs, _, names, _, _, _, _, short = PROFILES[profile]
    offset = names + (8 if short else 12)
    image = path.read_bytes()
    result = {}
    for name, key in reference_directory(path, profile, root):
        at = root + (key // 29 - 1) * bs + offset
        date = struct.unpack_from("<I", image, at)[0]
        time = 0 if profile == "project" else struct.unpack_from("<I", image, at + 4)[0]
        result[name] = (date, time)
    return result


class WritableMount(unittest.TestCase):
    def unlinked_metadata(self, fd):
        # High-level libfuse may have no path/fh for fstat after hard_remove.
        try:
            self.assertEqual(os.fstat(fd).st_nlink, 0)
        except OSError as error:
            self.assertIn(error.errno, (errno.ESTALE, errno.ENOENT))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="write-mount-", dir=ROOT / "build")
        self.directory = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def image(self, profile, mib=16):
        path = self.directory / f"{profile}.img"
        subprocess.run([str(TOOL), "mkfs", profile, str(path), str(mib)], check=True, capture_output=True)
        return path

    def verify(self, path, profile, expected):
        subprocess.run([str(TOOL), "check", str(path), profile], check=True, capture_output=True)
        root = 1024 if profile in ("ceres", "project") else 0
        self.assertEqual(dict(reference_files(path, profile, root)), expected)
        with mounted(path, profile) as mountpoint:
            self.assertEqual({p.name: p.read_bytes() for p in mountpoint.iterdir()}, expected)

    def test_timestamps_and_invalid_clock(self):
        values = [datetime(2024, 2, 29, 23, 59, 59, tzinfo=timezone.utc),
                  datetime(2000, 1, 1, tzinfo=timezone.utc)]
        for profile in PROFILES:
            with self.subTest(profile=profile):
                image, _, headers, root = make_image(profile, files={"A.Date": b"date", "B.Date": b"date", "C.Bad": b"bad"})
                bs, _, names, _, _, _, _, short = PROFILES[profile]
                for name, value in zip(("A.Date", "B.Date"), values):
                    at = root + (headers[name] // 29 - 1) * bs + names + (8 if short else 12)
                    date, time = clock(profile, value)
                    struct.pack_into("<I", image, at, date)
                    if profile != "project":
                        struct.pack_into("<I", image, at + 4, time)
                path = self.directory / f"dates-{profile}.img"
                path.write_bytes(image)
                for offset in (0, 120, -330):
                    with mounted(path, "--utc-offset", offset, profile, root) as mountpoint:
                        for name, value in zip(("A.Date", "B.Date"), values):
                            self.assertEqual((mountpoint / name).stat().st_mtime, value.timestamp() - offset * 60)
                        self.assertEqual((mountpoint / "C.Bad").stat().st_mtime, 0)
                self.assertEqual(path.read_bytes(), image)

    def test_create_write_truncate_and_dates(self):
        stamp = datetime(2004, 2, 29, 12, 34, 56, tzinfo=timezone.utc)
        for profile in PROFILES:
            with self.subTest(profile=profile):
                path = self.image(profile)
                before = path.stat()
                bs, hs, _, _, direct, _, _, _ = PROFILES[profile]
                size = (direct + bs // 4 + 3) * bs - hs
                payload = (bytes(range(256)) * ((size + 255) // 256))[:size]
                with mounted(path, "--rw", profile) as mountpoint:
                    file = mountpoint / "Data"
                    with file.open("w+b") as stream:
                        stream.write(payload)
                        stream.flush()
                        os.fsync(stream.fileno())
                        stream.seek(0)
                        self.assertEqual(stream.read(), payload)
                        stream.truncate(len(payload) + 99)
                    self.assertEqual(file.read_bytes(), payload + bytes(99))
                    with file.open("r+b") as stream:
                        stream.seek(9)
                        stream.write(b"changed")
                        stream.truncate(len(payload) - 7)
                    expected = payload[:9] + b"changed" + payload[16:-7]
                    os.utime(file, (stamp.timestamp(), stamp.timestamp()))
                    self.assertEqual(file.stat().st_mtime, stamp.timestamp())
                    self.assertEqual(file.read_bytes(), expected)
                    info = os.statvfs(mountpoint)
                    self.assertGreater(info.f_bavail, 0)
                    self.assertEqual(info.f_namemax, PROFILES[profile][2] - 1)
                self.assertEqual((path.stat().st_ino, path.stat().st_size), (before.st_ino, before.st_size))
                self.verify(path, profile, {"Data": expected})
                root = 1024 if profile in ("project", "ceres") else 0
                self.assertEqual(timestamps(path, profile, root)["Data"], clock(profile, stamp))

    def test_sparse_append_rename_and_open_unlink(self):
        for profile in PROFILES:
            with self.subTest(profile=profile):
                path = self.image(profile)
                with mounted(path, "--rw", profile) as mountpoint:
                    old, new = mountpoint / "Old", mountpoint / "New"
                    old.write_bytes(b"initial")
                    new.write_bytes(b"replaced")
                    with old.open("r+b", buffering=0) as opened, new.open("rb", buffering=0) as replaced:
                        os.replace(old, new)
                        self.assertEqual(replaced.read(), b"replaced")
                        self.unlinked_metadata(replaced.fileno())
                        opened.seek(10000)
                        opened.write(b"end")
                        os.fsync(opened.fileno())
                        self.assertEqual(new.read_bytes(), b"initial" + bytes(9993) + b"end")
                        new.unlink()
                        self.assertEqual(list(mountpoint.iterdir()), [])
                        self.unlinked_metadata(opened.fileno())
                        opened.seek(0)
                        self.assertEqual(opened.read(7), b"initial")
                        opened.seek(0)
                        opened.write(b"deleted")
                        opened.seek(0)
                        self.assertEqual(opened.read(7), b"deleted")
                    self.assertEqual(list(mountpoint.iterdir()), [])
                    old.write_bytes(b"append")
                    with old.open("ab") as stream:
                        stream.write(b"ed")
                    self.assertEqual(old.read_bytes(), b"appended")
                self.verify(path, profile, {"Old": b"appended"})

    def test_multiple_open_handles_and_simultaneous_copies(self):
        for profile in PROFILES:
            with self.subTest(profile=profile):
                path = self.image(profile)
                expected = {f"Copy{i}": bytes([i]) * (180000 + i) for i in range(2)}
                with mounted(path, "--rw", profile) as mountpoint:
                    with ThreadPoolExecutor(max_workers=2) as pool:
                        list(pool.map(lambda item: (mountpoint / item[0]).write_bytes(item[1]), expected.items()))
                    shared = mountpoint / "Shared"
                    shared.write_bytes(b"0123456789")
                    with shared.open("r+b", buffering=0) as first, shared.open("r+b", buffering=0) as second:
                        first.write(b"abc")
                        self.assertEqual(second.read(5), b"abc34")
                        second.seek(5)
                        second.write(b"xyz")
                        first.seek(0)
                        self.assertEqual(first.read(), b"abc34xyz89")
                    expected["Shared"] = b"abc34xyz89"
                self.verify(path, profile, expected)

    def test_directory_grows_and_shrinks(self):
        for profile in PROFILES:
            with self.subTest(profile=profile):
                path = self.image(profile)
                expected = {f"F{i:03d}": str(i).encode() for i in range(120)}
                with mounted(path, "--rw", profile) as mountpoint:
                    initial_free = os.statvfs(mountpoint).f_bfree
                    for name, data in expected.items():
                        (mountpoint / name).write_bytes(data)
                    self.assertEqual({p.name for p in mountpoint.iterdir()}, set(expected))
                    for name in list(expected):
                        if int(name[1:]) % 12:
                            (mountpoint / name).unlink()
                            del expected[name]
                    for name in expected:
                        (mountpoint / name).unlink()
                    self.assertEqual(os.statvfs(mountpoint).f_bfree, initial_free)
                    for name, data in expected.items():
                        (mountpoint / name).write_bytes(data)
                self.verify(path, profile, expected)

    def test_full_image_leaves_old_file_intact(self):
        for profile in PROFILES:
            with self.subTest(profile=profile):
                path = self.image(profile, 1)
                expected = b"keep this"
                with mounted(path, "--rw", profile) as mountpoint:
                    file = mountpoint / "Keep"
                    file.write_bytes(expected)
                    fd = os.open(file, os.O_RDWR)
                    try:
                        os.ftruncate(fd, 2 * 1024 * 1024)
                    except OSError as error:
                        self.assertEqual(error.errno, errno.ENOSPC)
                    else:
                        self.fail("oversized allocation succeeded")
                    try:
                        os.close(fd)
                    except OSError as error:
                        self.assertEqual(error.errno, errno.ENOSPC)
                    self.assertEqual(file.read_bytes(), expected)
                self.verify(path, profile, {"Keep": expected})

    def test_names_and_unsupported_operations(self):
        for profile in PROFILES:
            with self.subTest(profile=profile):
                path = self.image(profile)
                width = PROFILES[profile][2]
                with mounted(path, "--rw", profile) as mountpoint:
                    (mountpoint / ("x" * (width - 1))).write_bytes(b"long name")
                    with self.assertRaises(OSError) as error:
                        (mountpoint / ("x" * width)).write_bytes(b"no")
                    self.assertEqual(error.exception.errno, errno.ENAMETOOLONG)
                    with self.assertRaises(OSError):
                        (mountpoint / "subdirectory").mkdir()
                    with self.assertRaises(OSError):
                        (mountpoint / "bad\nname").write_bytes(b"no")
                self.verify(path, profile, {"x" * (width - 1): b"long name"})

    def test_rw_refuses_damaged_image_and_salvage(self):
        path = self.directory / "bad.img"
        image, _, headers, root = make_image("ceres", large=False)
        struct.pack_into("<I", image, root + (headers["B.Small"] // 29 - 1) * 1024, 0)
        path.write_bytes(image)
        mountpoint = self.directory / "mnt"
        mountpoint.mkdir()
        for options, code in ((["--rw", "ceres"], 1), (["--rw", "--salvage", "ceres"], 2),
                              (["--utc-offset", "1441", "ceres"], 2)):
            result = subprocess.run([str(ROOT / "build/oberon-fuse"), str(path), str(mountpoint), *options], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, code, result.stderr)
            self.assertEqual(path.read_bytes(), image)

    def test_writable_mount_excludes_readers_and_aliases(self):
        path = self.image("aos2")
        point = self.directory / "mnt"
        point.mkdir()
        with path.open("rb") as locked:
            fcntl.flock(locked, fcntl.LOCK_SH | fcntl.LOCK_NB)
            result = subprocess.run([str(ROOT / "build/oberon-fuse"), str(path), str(point), "--rw", "aos2"], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stderr)
        with mounted(path, "--rw", "aos2") as mountpoint:
            result = subprocess.run([str(TOOL), "check", str(path), "aos2"], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn(b"Resource temporarily unavailable", result.stderr)
            (mountpoint / "File").write_bytes(b"saved")
        before = path.read_bytes()
        alias = self.directory / "alias"
        alias.symlink_to(path)
        for selected in (alias, path):
            if selected == path:
                alias.unlink()
                os.link(path, alias)
            result = subprocess.run([str(ROOT / "build/oberon-fuse"), str(selected), str(point), "--rw", "aos2"], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(path.read_bytes(), before)

    def test_clock_limits_and_nonzero_offset_writes(self):
        for profile in PROFILES:
            with self.subTest(profile=profile):
                path = self.image(profile)
                stamp = datetime(2024, 2, 29, 12, 34, 56, tzinfo=timezone.utc)
                with mounted(path, "--rw", "--utc-offset", 120, profile) as mountpoint:
                    file = mountpoint / "Date"
                    file.write_bytes(b"clock")
                    os.utime(file, (stamp.timestamp(), stamp.timestamp()))
                    self.assertEqual(file.stat().st_mtime, stamp.timestamp())
                    if profile in ("project", "ceres"):
                        invalid = datetime(2070, 1, 1, tzinfo=timezone.utc).timestamp()
                        with self.assertRaises(OSError) as error:
                            os.utime(file, (invalid, invalid))
                        self.assertEqual(error.exception.errno, errno.EOVERFLOW)
                root = 1024 if profile in ("project", "ceres") else 0
                self.assertEqual(timestamps(path, profile, root)["Date"], clock(profile, datetime(2024, 2, 29, 14, 34, 56)))

    def test_cp_timestamp_roundtrip(self):
        source = self.directory / "Source"
        source.write_bytes(b"copy with dates\n")
        stamp = datetime(2001, 9, 9, 1, 46, 40, tzinfo=timezone.utc).timestamp()
        os.utime(source, (stamp, stamp))
        for profile in PROFILES:
            with self.subTest(profile=profile):
                path = self.image(profile)
                output = self.directory / f"output-{profile}"
                with mounted(path, "--rw", profile) as mountpoint:
                    target = mountpoint / "Copied"
                    subprocess.run(["cp", "--preserve=timestamps", str(source), str(target)], check=True, capture_output=True)
                    self.assertEqual(target.stat().st_mtime, stamp)
                    subprocess.run(["cp", "--preserve=timestamps", str(target), str(output)], check=True, capture_output=True)
                self.assertEqual(output.read_bytes(), source.read_bytes())
                self.assertEqual(output.stat().st_mtime, stamp)

    def test_partial_write_error_is_reported_and_old_file_survives(self):
        library = ROOT / "build/FailIO.so"
        if not library.exists():
            subprocess.run(["make", "-s", "build/FailIO.so"], cwd=ROOT, check=True)
        path = self.image("aos2")
        with mounted(path, "--rw", "aos2") as mountpoint:
            (mountpoint / "File").write_bytes(b"original")
        env = dict(os.environ, LD_PRELOAD=str(library), OBERON_TEST_IMAGE=str(path),
                   OBERON_TEST_WRITE_OFFSET="8192")
        with mounted(path, "--rw", "aos2", env=env) as mountpoint:
            fd = os.open(mountpoint / "File", os.O_WRONLY)
            os.write(fd, bytes(10000))
            with self.assertRaises(OSError) as error:
                os.fsync(fd)
            self.assertEqual(error.exception.errno, errno.EIO)
            try:
                os.close(fd)
            except OSError as error:
                self.assertEqual(error.errno, errno.EIO)
            self.assertEqual((mountpoint / "File").read_bytes(), b"original")
        self.verify(path, "aos2", {"File": b"original"})

    def test_uncertain_root_write_stops_further_access(self):
        subprocess.run(["make", "-s", "build/FailIO.so"], cwd=ROOT, check=True)
        path = self.image("aos2")
        with mounted(path, "--rw", "aos2") as mountpoint:
            (mountpoint / "File").write_bytes(b"original")
        env = dict(os.environ, LD_PRELOAD=str(ROOT / "build/FailIO.so"),
                   OBERON_TEST_IMAGE=str(path), OBERON_TEST_WRITE_OFFSET="0", OBERON_TEST_WRITE_LIMIT="4096")
        with mounted(path, "--rw", "aos2", env=env, expected_exit=1) as mountpoint:
            fd = os.open(mountpoint / "File", os.O_WRONLY)
            os.write(fd, b"new data")
            with self.assertRaises(OSError) as error:
                os.fsync(fd)
            self.assertEqual(error.exception.errno, errno.EIO)
            with self.assertRaises(OSError) as error:
                (mountpoint / "File").read_bytes()
            self.assertEqual(error.exception.errno, errno.EIO)
            try:
                os.close(fd)
            except OSError as error:
                self.assertEqual(error.errno, errno.EIO)


if __name__ == "__main__":
    unittest.main(verbosity=2)
