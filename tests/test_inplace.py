"""Explicit existing-image formatting and working-copy repair regressions."""

import fcntl
import os
from pathlib import Path
import resource
import signal
import subprocess
import tempfile
import unittest

from image_fixtures import PROFILES, make_image, make_deep_tree, u32
from reference_image import files as reference_files
from test_repair import damaged_header, directory_pages, run


ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "build/oberon-image"


def limit_writes(size):
    def limit():
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        resource.setrlimit(resource.RLIMIT_FSIZE, (size, size))
    return limit


class InPlace(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="inplace-", dir=ROOT / "build")
        self.directory = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_dd_and_format_all_layouts(self):
        for profile in PROFILES:
            for container in ("raw", "hdd", "floppy"):
                supported = container == "raw" or (container == "hdd" and profile != "ceres") or (container == "floppy" and profile == "natfs")
                if not supported:
                    continue
                with self.subTest(profile=profile, container=container):
                    path = self.directory / f"{profile}-{container}.img"
                    geometry = ["bs=512", "count=2880"] if container == "floppy" else ["bs=1M", "count=2"]
                    subprocess.run(["dd", "if=/dev/zero", f"of={path}", *geometry, "conv=excl", "status=none"], check=True, timeout=30)
                    before = path.stat()
                    # Stale boot metadata, file data and cache markers must all be erased.
                    with path.open("r+b") as file:
                        for offset in (0, 496, 4096, before.st_size - 16):
                            file.seek(offset)
                            file.write(b"old data")
                    args = ["mkfs", profile, path, "--in-place"]
                    if container != "raw":
                        args.append(container)
                    run(*args)
                    self.assertEqual((path.stat().st_dev, path.stat().st_ino, path.stat().st_size), (before.st_dev, before.st_ino, before.st_size))
                    options = [profile] if container == "raw" else []
                    run("check", path, *options)
                    self.assertEqual(run("list", path, *options).stdout, b"")
                    fresh = self.directory / f"fresh-{profile}-{container}.img"
                    create = ["create", profile, container, fresh]
                    if container != "floppy":
                        create.append(2)
                    run(*create)
                    self.assertEqual(path.read_bytes(), fresh.read_bytes())

    def test_repair_preserves_inode_and_matches_new_copy(self):
        for profile in PROFILES:
            for damage in ("header", "overlap", "all", "clean", "tree"):
                with self.subTest(profile=profile, damage=damage):
                    if damage == "tree":
                        image, files, headers, root = make_deep_tree(profile)
                        drops = {sorted(files)[len(files) // 2]}
                    else:
                        image, files, headers, root = make_image(profile)
                        drops = {"B.Small"} if damage == "header" else set()
                    if damage == "all":
                        drops = set(files)
                    if damage == "overlap":
                        bs, _, _, _, _, direct, _, _ = PROFILES[profile]
                        base = root + (headers["C.Large"] // 29 - 1) * bs
                        u32(image, base + direct + 4, headers["B.Small"])
                        drops = {"B.Small", "C.Large"}
                    else:
                        for name in drops:
                            damaged_header(image, profile, root, headers[name])
                    original = self.directory / f"{profile}-{damage}-original.img"
                    original.write_bytes(image)
                    working = self.directory / f"{profile}-{damage}-working.img"
                    working.write_bytes(image)
                    output = self.directory / f"{profile}-{damage}-output.img"
                    before = working.stat()
                    run("repair", original, output, "--drop-invalid", profile, root)
                    run("repair", working, "--in-place", "--drop-invalid", profile, root)
                    self.assertEqual(working.read_bytes(), output.read_bytes())
                    self.assertEqual(original.read_bytes(), image)
                    self.assertEqual((working.stat().st_dev, working.stat().st_ino, working.stat().st_size), (before.st_dev, before.st_ino, before.st_size))
                    run("check", working, profile, root)
                    self.assertEqual(dict(reference_files(working, profile, root)), {n: d for n, d in files.items() if n not in drops})
                    report = Path(str(working) + ".repair.txt").read_text()
                    self.assertTrue(report.startswith("status: complete\nmode: in-place\n"))
                    self.assertIn(f"keep: {len(files) - len(drops)}; drop: {len(drops)}", report)
                    if damage == "clean":
                        self.assertEqual(working.read_bytes(), image)
                    else:
                        bs = PROFILES[profile][0]
                        after = working.read_bytes()
                        changed = {i for i in range(0, len(image), bs) if image[i:i + bs] != after[i:i + bs]}
                        self.assertTrue(changed <= {root + (key // 29 - 1) * bs for key in directory_pages(image, profile, root)})

    def test_requires_explicit_flags(self):
        image, _, _, root = make_image("ceres", large=False)
        path = self.directory / "working.img"
        path.write_bytes(image)
        for args in (("mkfs", "ceres", path, 2), ("mkfs", "ceres", path),
                     ("repair", path, "--in-place", "ceres", root),
                     ("repair", path, "--in-place", "--drop-invalid", "--salvage", "ceres", root)):
            run(*args, success=False)
            self.assertEqual(path.read_bytes(), image)
        self.assertFalse(Path(str(path) + ".repair.txt").exists())

    def test_in_place_invalidates_saved_allocation_cache(self):
        for profile in ("natfs", "aos1", "aos2"):
            with self.subTest(profile=profile):
                bs = PROFILES[profile][0]
                image, files, headers, root = make_image(profile, large=False)
                damaged_header(image, profile, root, headers["B.Small"])
                image.extend(bytes(bs))
                u32(image, len(image) - bs, 0x9C2F977F)
                path = self.directory / f"{profile}.img"
                path.write_bytes(image)
                run("repair", path, "--in-place", "--drop-invalid", profile, root)
                run("check", path, profile, root)
                after = path.read_bytes()
                self.assertEqual(after[-bs:-bs + 4], bytes(4))
                self.assertEqual(after[-bs + 4:], image[-bs + 4:])
                self.assertEqual(dict(reference_files(path, profile, root)), {n: d for n, d in files.items() if n != "B.Small"})

    def test_rejects_aliases_devices_and_missing_paths(self):
        image, _, _, root = make_image("ceres", large=False)
        original = self.directory / "original.img"
        original.write_bytes(image)
        link = self.directory / "symlink.img"
        link.symlink_to(original)
        hardlink = self.directory / "hardlink.img"
        os.link(original, hardlink)
        fifo = self.directory / "fifo"
        os.mkfifo(fifo)
        missing = self.directory / "missing.img"
        for target in (original, link, hardlink, fifo, missing, self.directory, Path("/dev/null")):
            for args in (("mkfs", "ceres", target, "--in-place"),
                         ("repair", target, "--in-place", "--drop-invalid", "ceres", root)):
                run(*args, success=False)
        self.assertEqual(original.read_bytes(), image)
        self.assertFalse(missing.exists())

    @unittest.skipIf(os.geteuid() == 0, "root bypasses read-only file permissions")
    def test_rejects_read_only_working_image(self):
        image, _, _, root = make_image("ceres", large=False)
        path = self.directory / "read-only.img"
        path.write_bytes(image)
        path.chmod(0o444)
        try:
            run("repair", path, "--in-place", "--drop-invalid", "ceres", root, success=False)
            run("mkfs", "ceres", path, "--in-place", success=False)
            self.assertEqual(path.read_bytes(), image)
        finally:
            path.chmod(0o644)

    def test_validates_format_before_writing(self):
        for profile, container, size in (("ceres", "hdd", 2 * 1048576), ("aos2", "raw", 4096),
                                          ("natfs", "floppy", 2 * 1048576), ("project", "raw", 8193),
                                          ("natfs", "unknown", 1048576)):
            with self.subTest(profile=profile, container=container, size=size):
                path = self.directory / f"invalid-{profile}-{container}.img"
                contents = b"x" * size
                path.write_bytes(contents)
                run("mkfs", profile, path, "--in-place", container, success=False)
                self.assertEqual(path.read_bytes(), contents)

    def test_existing_report_refuses_repair_before_changes(self):
        image, _, headers, root = make_image("ceres", large=False)
        damaged_header(image, "ceres", root, headers["B.Small"])
        path = self.directory / "working.img"
        path.write_bytes(image)
        report = Path(str(path) + ".repair.txt")
        report.write_bytes(b"keep this report")
        run("repair", path, "--in-place", "--drop-invalid", "ceres", root, success=False)
        self.assertEqual(path.read_bytes(), image)
        self.assertEqual(report.read_bytes(), b"keep this report")

    def test_invalid_tree_refuses_repair_before_changes(self):
        image, _, _, root = make_image("ceres", large=False)
        u32(image, root + 8, 29)
        path = self.directory / "working.img"
        path.write_bytes(image)
        run("repair", path, "--in-place", "--drop-invalid", "ceres", root, success=False)
        self.assertEqual(path.read_bytes(), image)
        self.assertFalse(Path(str(path) + ".repair.txt").exists())

    def test_shared_and_exclusive_locks(self):
        image, _, _, root = make_image("ceres", large=False)
        path = self.directory / "working.img"
        path.write_bytes(image)
        with path.open("rb") as file:
            fcntl.flock(file, fcntl.LOCK_SH | fcntl.LOCK_NB)
            run("info", path, "ceres", root)
            run("repair", path, "--in-place", "--drop-invalid", "ceres", root, success=False)
            run("mkfs", "ceres", path, "--in-place", success=False)
            self.assertEqual(path.read_bytes(), image)
            self.assertFalse(Path(str(path) + ".repair.txt").exists())
            fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            run("info", path, "ceres", root, success=False)
            run("repair", path, "--in-place", "--drop-invalid", "ceres", root, success=False)
            run("mkfs", "ceres", path, "--in-place", success=False)
        run("check", path, "ceres", root)

    def test_partial_repair_write_failure_marks_report_failed(self):
        image, _, headers, root = make_deep_tree("ceres")
        damaged_header(image, "ceres", root, headers[sorted(headers)[0]])
        original = self.directory / "original.img"
        original.write_bytes(image)
        working = self.directory / "working.img"
        working.write_bytes(image)
        before = working.stat()
        # First rebuilt leaf uses the penultimate old page. Permit only half a write.
        limit = len(image) - 2 * 1024 + 512
        result = subprocess.run([str(TOOL), "repair", str(working), "--in-place", "--drop-invalid", "ceres", str(root)],
                                capture_output=True, timeout=60, preexec_fn=limit_writes(limit))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"File too large", result.stderr)
        self.assertNotEqual(working.read_bytes(), image)
        self.assertEqual(original.read_bytes(), image)
        self.assertEqual((working.stat().st_ino, working.stat().st_size), (before.st_ino, before.st_size))
        report = Path(str(working) + ".repair.txt").read_text()
        self.assertTrue(report.startswith("status: failed  \nmode: in-place\n"))

    def test_partial_format_write_failure_preserves_size(self):
        path = self.directory / "working.img"
        contents = b"x" * 65536
        path.write_bytes(contents)
        before = path.stat()
        result = subprocess.run([str(TOOL), "mkfs", "ceres", str(path), "--in-place"],
                                capture_output=True, timeout=60, preexec_fn=limit_writes(32768))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(path.stat().st_ino, before.st_ino)
        self.assertEqual(path.read_bytes(), bytes(32768) + contents[32768:])


if __name__ == "__main__":
    unittest.main(verbosity=2)
