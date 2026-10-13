"""Diagnostics, quarantine and new-copy repair regressions; no mount required."""

import hashlib
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import unittest

from image_fixtures import PROFILES, make_image, make_tree, make_deep_tree, u32
from reference_image import directory, files as reference_files


ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "build/oberon-image"


def run(*args, success=True):
    result = subprocess.run([str(TOOL), *map(str, args)], capture_output=True, timeout=60)
    if success:
        assert result.returncode == 0, (args, result.returncode, result.stdout, result.stderr)
    else:
        assert result.returncode in (1, 2), (args, result.returncode, result.stdout, result.stderr)
    return result


def damaged_header(image, profile, root, key):
    bs, _, names, _, _, _, _, short = PROFILES[profile]
    base = root + (key // 29 - 1) * bs
    struct.pack_into("<HH" if short else "<II", image, base + names + 4, 0, 0)


def directory_pages(image, profile, root):
    bs, _, names, entries, _, _, _, short = PROFILES[profile]
    todo = [29]
    pages = set()
    while todo:
        key = todo.pop()
        assert key not in pages
        pages.add(key)
        base = root + (key // 29 - 1) * bs
        m = struct.unpack_from("<H" if short else "<I", image, base + 4)[0]
        children = [struct.unpack_from("<I", image, base + 8)[0]]
        children.extend(struct.unpack_from("<I", image, base + entries + i * (names + 8) + names + 4)[0] for i in range(m))
        todo.extend(key for key in children if key)
    return pages


class Repair(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="repair-", dir=ROOT / "build")
        self.directory = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def check_copy(self, source, output, profile, root, expected, drops):
        before = source.read_bytes()
        run("repair", source, output, "--drop-invalid", profile, root)
        self.assertEqual(source.read_bytes(), before)
        run("check", output, profile, root)
        self.assertEqual(dict(reference_files(output, profile, root)), expected)
        manifest = Path(str(output) + ".repair.txt").read_text()
        self.assertTrue(manifest.startswith("status: complete\n"))
        self.assertIn(f"keep: {len(expected)}; drop: {len(drops)}", manifest)
        for name in drops:
            self.assertIn(f"DROP\t{name} [header address=", manifest)
        # Only old directory pages may change, never original file records.
        after = output.read_bytes()
        bs = PROFILES[profile][0]
        allowed = {root + (key // 29 - 1) * bs for key in directory_pages(before, profile, root)}
        self.assertEqual(len(after), len(before))
        for base in range(0, len(before), bs):
            if base not in allowed:
                self.assertEqual(after[base:base + bs], before[base:base + bs], base)
        for name, data in expected.items():
            self.assertEqual(run("cat", output, name, profile, root).stdout, data)

    def test_multiple_header_errors_and_salvage(self):
        for profile in PROFILES:
            with self.subTest(profile=profile):
                image, files, headers, root = make_image(profile, large=False)
                dropped = {"A.Empty", "B.Small"}
                for name in dropped:
                    damaged_header(image, profile, root, headers[name])
                source = self.directory / f"{profile}.img"
                source.write_bytes(image)
                before = hashlib.sha256(image).digest()
                report = run("check", source, profile, root, success=False).stdout.decode()
                self.assertEqual(report.count("file length is shorter than its header"), 2)
                self.assertIn("issues: 2", report)
                run("info", source, profile, root, success=False)
                info = run("info", source, "--salvage", profile, root).stdout
                self.assertIn(b"usable files: 1", info)
                expected = {name: data for name, data in files.items() if name not in dropped}
                listing = run("list", source, "--salvage", profile, root).stdout.decode().splitlines()
                self.assertEqual(listing, [f"{len(data)}\t{name}" for name, data in sorted(expected.items())])
                for name in dropped:
                    run("cat", source, name, "--salvage", profile, root, success=False)
                plan = run("repair-plan", source, profile, root).stdout.decode()
                self.assertIn("keep: 1; drop: 2", plan)
                self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), before)
                output = self.directory / f"{profile}-repaired.img"
                self.check_copy(source, output, profile, root, expected, dropped)

    def test_overlaps_exclude_both_owners(self):
        for profile in PROFILES:
            with self.subTest(profile=profile):
                bs, _, _, _, _, direct_offset, _, _ = PROFILES[profile]
                image, files, headers, root = make_image(profile)
                large = root + (headers["C.Large"] // 29 - 1) * bs
                u32(image, large + direct_offset + 4, headers["B.Small"])
                source = self.directory / f"{profile}.img"
                source.write_bytes(image)
                report = run("check", source, profile, root, success=False).stdout.decode()
                self.assertIn("ERROR\tB.Small\tallocation overlaps", report)
                self.assertIn("ERROR\tC.Large\tallocation overlaps", report)
                dropped = {"B.Small", "C.Large"}
                expected = {name: data for name, data in files.items() if name not in dropped}
                self.check_copy(source, self.directory / f"{profile}-out.img", profile, root, expected, dropped)

    def test_invalid_data_and_index_addresses(self):
        for profile in PROFILES:
            bs, _, _, _, _, direct_offset, index_offset, _ = PROFILES[profile]
            for damage in ("direct", "index", "extension"):
                if damage == "extension" and not profile.startswith("aos"):
                    continue
                with self.subTest(profile=profile, damage=damage):
                    image, files, headers, root = make_image(profile)
                    base = root + (headers["C.Large"] // 29 - 1) * bs
                    if damage == "direct":
                        # Two failures must both be reported, not just the first.
                        u32(image, base + direct_offset + 4, 0)
                        u32(image, base + direct_offset + 8, 1)
                    elif damage == "extension" or not profile.startswith("aos"):
                        u32(image, base + index_offset, 1)
                    else:
                        extension = struct.unpack_from("<I", image, base + index_offset)[0]
                        u32(image, root + (extension // 29 - 1) * bs, 1)
                    source = self.directory / f"{profile}-{damage}.img"
                    source.write_bytes(image)
                    report = run("check", source, profile, root, success=False).stdout.decode()
                    errors = 2 if damage == "direct" else 1
                    self.assertEqual(report.count("unreadable, missing or invalid block address"), errors)
                    dropped = {"C.Large"}
                    expected = {name: data for name, data in files.items() if name not in dropped}
                    self.check_copy(source, self.directory / f"{profile}-{damage}-out.img", profile, root, expected, dropped)

    def test_all_invalid_rebuilds_empty_root(self):
        for profile in PROFILES:
            with self.subTest(profile=profile):
                image, files, headers, root = make_image(profile, large=False)
                for key in headers.values():
                    damaged_header(image, profile, root, key)
                source = self.directory / f"{profile}.img"
                source.write_bytes(image)
                self.assertEqual(run("list", source, "--salvage", profile, root).stdout, b"")
                self.check_copy(source, self.directory / f"{profile}-out.img", profile, root, {}, set(files))

    def test_saved_allocation_cache_invalidation(self):
        for profile in ("natfs", "aos1", "aos2"):
            with self.subTest(profile=profile):
                bs = PROFILES[profile][0]
                image, files, headers, root = make_image(profile, large=False)
                damaged_header(image, profile, root, headers["A.Empty"])
                # An unreferenced final block holding a recognized saved-map index.
                image.extend(bytes(bs))
                u32(image, len(image) - bs, 0x9C2F977F)
                source = self.directory / f"{profile}.img"
                output = self.directory / f"{profile}-out.img"
                source.write_bytes(image)
                run("repair", source, output, "--drop-invalid", profile, root)
                run("check", output, profile, root)
                self.assertEqual(output.read_bytes()[-bs:-bs + 4], bytes(4))
                self.assertEqual(output.read_bytes()[-bs + 4:], image[-bs + 4:])
                self.assertEqual(source.read_bytes(), image)
                self.assertEqual(dict(reference_files(output, profile, root)), {n: d for n, d in files.items() if n != "A.Empty"})

    def test_diagnostic_storage_limit(self):
        image, files, headers, root = make_deep_tree("aos1")
        self.assertGreater(len(files), 10000)
        for key in headers.values():
            damaged_header(image, "aos1", root, key)
        source = self.directory / "many-errors.img"
        source.write_bytes(image)
        report = run("check", source, "aos1", root, success=False).stdout.decode()
        self.assertEqual(report.count("ERROR\t"), 10000)
        self.assertIn(f"Additional issues omitted from report: {len(files) - 10000}", report)
        self.assertIn(f"issues: {len(files)}", report)
        self.assertIn(f"usable files: 0 of {len(files)}", report)

    def test_checker_work_limit_refuses_salvage_and_repair(self):
        bs = PROFILES["aos2"][0]
        image, _, headers, root = make_image("aos2", large=False)
        table = len(image) // bs * 29 + 29
        extension = table + 29
        image.extend(bytes(bs) + struct.pack("<1024I", *([table] * 1024)))
        for key in headers.values():
            base = (key // 29 - 1) * bs
            struct.pack_into("<II", image, base + 132, 128 + 1024 * 1024 - 1, 0)
            u32(image, base + 660, extension)
        source = self.directory / "excessive-work.img"
        source.write_bytes(image)
        report = run("check", source, "aos2", root, success=False)
        self.assertIn(b"allocation checker resource limit", report.stderr)
        run("list", source, "--salvage", "aos2", root, success=False)
        output = self.directory / "refused.img"
        run("repair", source, output, "--drop-invalid", "aos2", root, success=False)
        self.assertFalse(output.exists())
        run("repair", source, "--in-place", "--drop-invalid", "aos2", root, success=False)
        self.assertFalse(Path(str(source) + ".repair.txt").exists())
        self.assertEqual(source.read_bytes(), image)

    def test_directory_root_collapse(self):
        for profile in PROFILES:
            image, files, root, _, _ = make_tree(profile)
            source = self.directory / f"{profile}.img"
            source.write_bytes(image)
            headers = dict(directory(source, profile, root))
            dropped = {sorted(files)[len(files) // 2]}
            damaged_header(image, profile, root, headers[next(iter(dropped))])
            source.write_bytes(image)
            expected = {name: data for name, data in files.items() if name not in dropped}
            output = self.directory / f"{profile}-out.img"
            self.check_copy(source, output, profile, root, expected, dropped)
            self.assertEqual(len(directory_pages(output.read_bytes(), profile, root)), 1)

    def test_multilevel_directory_rebuild(self):
        for profile in ("project", "natfs", "aos2"):
            with self.subTest(profile=profile):
                image, files, headers, root = make_deep_tree(profile)
                dropped = {sorted(files)[len(files) // 2]}
                damaged_header(image, profile, root, headers[next(iter(dropped))])
                source = self.directory / f"{profile}.img"
                source.write_bytes(image)
                output = self.directory / f"{profile}-out.img"
                expected = {name: data for name, data in files.items() if name not in dropped}
                # Independent all-file comparison; avoid thousands of redundant CLI startups.
                before = source.read_bytes()
                run("repair", source, output, "--drop-invalid", profile, root)
                run("check", output, profile, root)
                self.assertEqual(dict(reference_files(output, profile, root)), expected)
                self.assertEqual(source.read_bytes(), before)
                self.assertGreater(len(directory_pages(output.read_bytes(), profile, root)), 3)

    def test_clean_image_copy_is_byte_identical(self):
        for profile in PROFILES:
            image, _, _, root = make_image(profile, large=False)
            source = self.directory / f"{profile}.img"
            source.write_bytes(image)
            output = self.directory / f"{profile}-out.img"
            run("repair", source, output, "--drop-invalid", profile, root)
            self.assertEqual(output.read_bytes(), image)
            self.assertIn("drop: 0", Path(str(output) + ".repair.txt").read_text())

    def test_existing_paths_and_explicit_policy(self):
        image, _, _, root = make_image("ceres", large=False)
        source = self.directory / "original.img"
        source.write_bytes(image)
        output = self.directory / "output.img"
        run("repair", source, output, "ceres", root, success=False)
        self.assertFalse(output.exists())
        link = self.directory / "link.img"
        link.symlink_to(source)
        for target in (source, link):
            run("repair", source, target, "--drop-invalid", "ceres", root, success=False)
        self.assertEqual(source.read_bytes(), image)
        output.write_bytes(b"keep output")
        run("repair", source, output, "--drop-invalid", "ceres", root, success=False)
        self.assertEqual(output.read_bytes(), b"keep output")
        another = self.directory / "another.img"
        manifest = Path(str(another) + ".repair.txt")
        manifest.write_bytes(b"keep report")
        run("repair", source, another, "--drop-invalid", "ceres", root, success=False)
        self.assertEqual(manifest.read_bytes(), b"keep report")
        self.assertEqual(source.read_bytes(), image)

    def test_interrupted_copy_preserves_original(self):
        image, _, headers, root = make_image("ceres", large=False)
        damaged_header(image, "ceres", root, headers["A.Empty"])
        source = self.directory / "original.img"
        source.write_bytes(image)
        # Sparse padding makes the copy long enough to interrupt without a huge fixture.
        size = 2 * 1024 * 1024 * 1024
        with source.open("r+b") as file:
            file.truncate(size)
        output = self.directory / "interrupted.img"
        process = subprocess.Popen([str(TOOL), "repair", str(source), str(output), "--drop-invalid", "ceres", str(root)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while not output.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.001)
            self.assertTrue(output.exists())
            self.assertIsNone(process.poll())
            process.terminate()
            process.communicate(timeout=10)
            self.assertNotEqual(process.returncode, 0)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=10)
        self.assertEqual(source.stat().st_size, size)
        with source.open("rb") as file:
            self.assertEqual(file.read(len(image)), image)
            file.seek(size - 1)
            self.assertEqual(file.read(1), b"\0")
        manifest = Path(str(output) + ".repair.txt")
        if manifest.exists():
            self.assertNotIn("status: complete", manifest.read_text())

    def test_structurally_bad_tree_refused(self):
        image, _, _, root = make_image("ceres", large=False)
        u32(image, root + 8, 29)
        source = self.directory / "bad-tree.img"
        source.write_bytes(image)
        output = self.directory / "refused.img"
        for command in ("info", "list"):
            run(command, source, "--salvage", "ceres", root, success=False)
        run("repair-plan", source, "ceres", root, success=False)
        run("repair", source, output, "--drop-invalid", "ceres", root, success=False)
        self.assertFalse(output.exists())
        self.assertEqual(source.read_bytes(), image)


if __name__ == "__main__":
    unittest.main(verbosity=2)
