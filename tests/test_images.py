"""No FUSE mount or downloaded images required for the default tests."""

import hashlib
import io
import os
from pathlib import Path
import random
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

from image_fixtures import PROFILES, make_image, make_tree, make_boot_cd, u32
from reference_image import block, directory, files as reference_files, isolated_files, ceres_salvage_files


ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "build/oberon-image"
REAL = "--real" in sys.argv
if REAL:
    sys.argv.remove("--real")


def run(*args, success=True):
    result = subprocess.run([str(TOOL), *map(str, args)], capture_output=True, timeout=30)
    if success:
        assert result.returncode == 0, (args, result.returncode, result.stderr.decode(errors="replace"))
    else:
        assert result.returncode in (1, 2), (args, result.returncode, result.stderr)
    return result.stdout


class Images(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="images-", dir=ROOT / "build")
        self.directory = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_all_profiles_and_indirection(self):
        for profile in PROFILES:
            with self.subTest(profile=profile):
                data, files, _, root = make_image(profile)
                path = self.directory / f"{profile}.img"
                path.write_bytes(data)
                listing = run("list", path, profile, root).decode().splitlines()
                self.assertEqual(listing, [f"{len(value)}\t{name}" for name, value in sorted(files.items())])
                run("check", path, profile, root)
                for name, expected in files.items():
                    self.assertEqual(run("cat", path, name, profile, root), expected)
                    for offset, count in [(0, 1), (671, 73), (4093, 33), (len(expected), 99), (4294967296, 99)]:
                        self.assertEqual(run("read", path, name, offset, count, profile, root), expected[offset:offset + count])

    def test_formatters(self):
        for profile in PROFILES:
            for container in ("raw", "hdd", "floppy"):
                with self.subTest(profile=profile, container=container):
                    path = self.directory / f"{profile}-{container}.img"
                    supported = container == "raw" or (container == "hdd" and profile != "ceres") or (container == "floppy" and profile == "natfs")
                    args = ["create", profile, container, path]
                    if container != "floppy":
                        args.append(8)
                    run(*args, success=supported)
                    if not supported:
                        self.assertFalse(path.exists())
                        continue
                    self.assertEqual(path.stat().st_size, 1474560 if container == "floppy" else 8 * 1048576)
                    options = [profile] if container == "raw" else []
                    run("check", path, *options)
                    self.assertEqual(run("list", path, *options), b"")
                    with path.open("rb") as image:
                        head = image.read(512)
                    if container == "hdd":
                        self.assertEqual(head[510:512], b"\x55\xaa")
                        self.assertEqual(head[450], 0xFF if profile == "project" else 0x4F if profile == "natfs" else 0x4C)
                        self.assertEqual(struct.unpack_from("<I", head, 454)[0], 2048)
        path = self.directory / "mkfs.img"
        run("mkfs", "natfs", path, 2)
        run("check", path, "natfs")

    def test_refuses_overwrite_and_symlinks(self):
        path = self.directory / "keep.img"
        path.write_bytes(b"do not overwrite")
        link = self.directory / "link.img"
        link.symlink_to(path)
        for target in (path, link):
            run("create", "project", "hdd", target, 8, success=False)
            run("mkfs", "project", target, 8, success=False)
        self.assertEqual(path.read_bytes(), b"do not overwrite")
        fifo = self.directory / "fifo"
        os.mkfifo(fifo)
        run("info", fifo, success=False)
        run("create", "natfs", "raw", fifo, 2, success=False)

    def test_tree_structure(self):
        for profile in PROFILES:
            bs, _, names, directory_offset, _, _, _, short = PROFILES[profile]
            image, files, root, left, right = make_tree(profile)
            path = self.directory / "tree.img"
            path.write_bytes(image)
            run("check", path, profile, root)
            self.assertEqual(run("list", path, profile, root).decode().splitlines(),
                             [f"{len(data)}\t{name}" for name, data in sorted(files.items())])
            for name, value in files.items():
                self.assertEqual(run("cat", path, name, profile, root), value)
            cases = {}
            data = image.copy(); u32(data, root + directory_offset + names + 4, 0); cases["missing-child"] = data
            data = image.copy(); u32(data, root + directory_offset + names + 4, left); cases["shared-page"] = data
            data = image.copy(); u32(data, root + (right // 29 - 1) * bs + 4, 1); cases["underfull-leaf"] = data
            data = image.copy(); u32(data, root + (right // 29 - 1) * bs + 8, left); cases["unequal-depth"] = data
            for label, data in cases.items():
                with self.subTest(profile=profile, corruption=label):
                    path.write_bytes(data)
                    run("check", path, profile, root, success=False)

    def test_zero_length_final_block(self):
        # aleng counts an allocated last block even if that block has no data.
        for profile in PROFILES:
            bs, hs, names, _, _, direct_offset, _, short = PROFILES[profile]
            image, _, headers, root = make_image(profile, files={"Boundary": b"x" * (bs - hs)})
            head = root + (headers["Boundary"] // 29 - 1) * bs
            struct.pack_into("<HH" if short else "<II", image, head + names + 4, 1, 0)
            key = ((len(image) - root) // bs + 1) * 29
            image.extend(bytes(bs))
            u32(image, head + direct_offset + 4, key)
            path = self.directory / "boundary.img"
            path.write_bytes(image)
            run("check", path, profile, root)
            self.assertEqual(run("cat", path, "Boundary", profile, root), b"x" * (bs - hs))
            u32(image, head + direct_offset + 4, 29)
            path.write_bytes(image)
            run("check", path, profile, root, success=False)

    def test_partition_ids_and_ambiguity(self):
        for profile, ids in (("project", (0xFF,)), ("natfs", (0x4F, 0x50, 0xFF)), ("aos1", (0x4C, 0xFF)), ("aos2", (0x4C, 0xFF))):
            path = self.directory / f"{profile}.img"
            run("create", profile, "hdd", path, 8)
            image = path.read_bytes()
            for type_id in ids:
                data = bytearray(image); data[450] = type_id
                path.write_bytes(data)
                run("check", path)
            data[462:478] = data[446:462]
            path.write_bytes(data)
            run("check", path, success=False)
            root = 1048576 + (1024 if profile == "project" else 32768)
            run("check", path, profile, root)
            # A partition may end before its otherwise readable root block.
            data[462:478] = bytes(16)
            u32(data, 458, 1)
            path.write_bytes(data)
            run("check", path, success=False)

    def test_old_aos_boot_footer(self):
        data, _ = make_boot_cd("aos1")
        start = 23 * 2048
        data[start + 480:start + 488] = data[start + 496:start + 504]
        data[start + 496:start + 504] = bytes(8)
        u32(data, start + 504, 0x5245424F)
        path = self.directory / "old.iso"
        path.write_bytes(data)
        self.assertIn(b"format: aos1", run("info", path))
        run("check", path)

    def test_el_torito_and_aos_footer_precedence(self):
        for profile in ("natfs", "aos1", "aos2"):
            with self.subTest(profile=profile):
                data, files = make_boot_cd(profile)
                path = self.directory / "boot.iso"
                path.write_bytes(data)
                self.assertIn(f"format: {profile}".encode(), run("info", path))
                run("check", path)
                for name, value in files.items():
                    self.assertEqual(run("cat", path, name), value)
                data[19 * 2048 + 28] ^= 1
                path.write_bytes(data)
                run("check", path, success=False)

    def test_bad_records(self):
        for profile in PROFILES:
            good, files, headers, root = make_image(profile)
            bs, _, names, directory_offset, _, direct_offset, _, short = PROFILES[profile]
            cases = {}
            data = good.copy(); data[root] ^= 1; cases["magic"] = data
            data = good.copy(); u32(data, root + 4, 65535); cases["entry-count"] = data
            data = good.copy(); u32(data, root + 8, 29); cases["cycle"] = data
            data = good.copy(); data[root + directory_offset] = 0; cases["empty-name"] = data
            data = good.copy(); u32(data, root + directory_offset + names, 30); cases["misaligned-header"] = data
            header = root + (headers["B.Small"] // 29 - 1) * bs
            data = good.copy(); data[header + 4] = ord("X"); cases["header-name"] = data
            data = good.copy()
            struct.pack_into("<HH" if short else "<II", data, header + names + 4, 0, 0)
            cases["header-length-underflow"] = data
            data = good.copy()
            struct.pack_into("<H" if short else "<I", data, header + names + 4, 65535 if short else 0xFFFFFFFF)
            cases["file-length"] = data
            header = root + (headers["C.Large"] // 29 - 1) * bs
            data = good.copy(); u32(data, header + direct_offset + 4, 30); cases["bad-data-address"] = data
            data = good.copy(); u32(data, header + direct_offset + 4, 29); cases["overlap"] = data
            cases["truncated"] = good[:-bs]
            for label, data in cases.items():
                with self.subTest(profile=profile, corruption=label):
                    path = self.directory / "bad.img"
                    path.write_bytes(data)
                    run("check", path, profile, root, success=False)

    def test_cli_numbers(self):
        for value in ("-1", "abc", "9223372036854775808", "1x"):
            run("mkfs", "natfs", self.directory / "bad.img", value, success=False)
        run("create", "auto", "hdd", self.directory / "bad.img", success=False)
        run("info", self.directory / "missing.img", success=False)

    def test_read_past_two_gib(self):
        # A partly allocated AosFS file: only the requested high-offset block
        # exists. Reads of that block must work; the full checker must reject it.
        data, _, headers, root = make_image("aos2", large=False)
        bs = 4096
        header = root + (headers["B.Small"] // 29 - 1) * bs
        offset = 3 * 1024**3 + 1234
        marker = b"64-bit data offset"
        total = offset + len(marker) + 664
        struct.pack_into("<II", data, header + 132, *divmod(total, bs))
        keys = []
        for _ in range(3):
            data.extend(bytes(bs))
            keys.append((len(data) // bs) * 29)
        super_key, sub_key, data_key = keys
        number, within = divmod(offset + 664, bs)
        index, slot = divmod(number - 128, bs // 4)
        u32(data, header + 660, super_key)
        u32(data, (super_key // 29 - 1) * bs + index * 4, sub_key)
        u32(data, (sub_key // 29 - 1) * bs + slot * 4, data_key)
        start = (data_key // 29 - 1) * bs + within
        data[start:start + len(marker)] = marker
        path = self.directory / "high-offset.img"
        path.write_bytes(data)
        self.assertEqual(run("read", path, "B.Small", offset, len(marker), "aos2", root), marker)
        self.assertEqual(run("read", path, "B.Small", 4294967296, 99, "aos2", root), b"")
        run("check", path, "aos2", root, success=False)

    def test_mutated_metadata_does_not_crash(self):
        good, _, _, root = make_image("project", large=False)
        rng = random.Random(20261013)
        path = self.directory / "mutated.img"
        for _ in range(100):
            data = good.copy()
            for _ in range(4):
                offset = rng.randrange(root, len(data))
                data[offset] = rng.randrange(256)
            path.write_bytes(data)
            result = subprocess.run([str(TOOL), "check", str(path), "project", str(root)], capture_output=True, timeout=5)
            self.assertIn(result.returncode, (0, 1))

    def test_unsafe_module_boundary(self):
        for source in ROOT.glob("*.Mod"):
            if source.name not in ("Host.Mod", "FuseABI.Mod"):
                self.assertNotIn("SYSTEM", source.read_text(), str(source))


@unittest.skipUnless(REAL, "run make check-images for local preservation images")
class PreservationImages(unittest.TestCase):
    def test_ceres_dump(self):
        path = Path(os.environ.get("CERES_IMAGE", ROOT / "disks/ceres/ceres.dat"))
        extracted = Path(os.environ.get("CERES_FILES", ROOT / "disks/ceres/ceres_xt2190_files.zip"))
        if not path.exists() or not extracted.exists():
            self.skipTest("Ceres dump and extracted-file archive not installed")
        before = hashlib.sha256(path.read_bytes()).digest()
        entries = dict(directory(path, "ceres", 1024))
        self.assertEqual(len(entries), 589)
        damaged = []
        with path.open("rb") as image:
            for name, key in entries.items():
                head = block(image, key, 1024, 1024)
                a, z = struct.unpack_from("<HH", head, 36)
                if a * 1024 + z < 352:
                    damaged.append(name)
        self.assertEqual(len(damaged), 16)
        run("check", path, "ceres", success=False)
        with zipfile.ZipFile(extracted) as archive:
            archive_names = set(archive.namelist())
            self.assertEqual(len(archive_names), 588)
            self.assertIsNone(archive.testzip())
            missing = []
            for name, data in reference_files(path, "ceres", 1024):
                if name not in archive_names:
                    missing.append((name, len(data)))
                else:
                    self.assertEqual(data, archive.read(name), name)
                    archive_names.remove(name)
            self.assertEqual(missing, [("Huebner.Text", 1783)])
            self.assertEqual(archive_names, set())
            # Test the production decoder against unmodified real file records
            # in an explicitly derived fixture, without hiding the dump's damage.
            good = sorted(i.filename for i in archive.infolist() if i.file_size > 0)
            largest = max(archive.infolist(), key=lambda i: i.file_size).filename
            chosen = sorted({good[0], good[len(good) // 2], largest})
            with tempfile.TemporaryDirectory(prefix="ceres-records-", dir=ROOT / "build") as temp:
                fixture = Path(temp) / "isolated.img"
                fixture.write_bytes(isolated_files(path, "ceres", 1024, chosen))
                run("check", fixture, "ceres")
                for name in chosen:
                    self.assertEqual(run("cat", fixture, name, "ceres"), archive.read(name), name)
        self.assertEqual(hashlib.sha256(path.read_bytes()).digest(), before)

    def test_ceres_salvage_and_repair(self):
        path = Path(os.environ.get("CERES_IMAGE", ROOT / "disks/ceres/ceres.dat"))
        extracted = Path(os.environ.get("CERES_FILES", ROOT / "disks/ceres/ceres_xt2190_files.zip"))
        if not path.exists() or not extracted.exists():
            self.skipTest("Ceres dump and extracted-file archive not installed")
        before = path.read_bytes()
        expected = ceres_salvage_files(path)
        self.assertEqual(len(expected), 570)
        report = run("check", path, "ceres", success=False).decode()
        self.assertIn("issues: 32", report)
        self.assertIn("usable files: 570 of 589", report)
        listing = run("list", path, "--salvage", "ceres").decode().splitlines()
        self.assertEqual(listing, [f"{len(data)}\t{name}" for name, data in sorted(expected.items())])
        with tempfile.TemporaryDirectory(prefix="ceres-repair-", dir=ROOT / "build") as temp:
            output = Path(temp) / "repaired.img"
            run("repair", path, output, "--drop-invalid", "ceres")
            run("check", output, "ceres")
            self.assertEqual(dict(reference_files(output, "ceres", 1024)), expected)
            with zipfile.ZipFile(extracted) as archive:
                archived = set(archive.namelist())
                for name, data in expected.items():
                    self.assertEqual(run("cat", path, name, "--salvage", "ceres"), data, name)
                    self.assertEqual(run("cat", output, name, "ceres"), data, name)
                    if name in archived:
                        self.assertEqual(data, archive.read(name), name)
            after = output.read_bytes()
            changed = {offset for offset in range(0, len(before), 1024) if before[offset:offset + 1024] != after[offset:offset + 1024]}
            # Independently collect directory addresses; no file block may change.
            todo = [29]
            pages = set()
            with path.open("rb") as image:
                while todo:
                    key = todo.pop()
                    self.assertNotIn(key, pages)
                    pages.add(key)
                    page = block(image, key, 1024, 1024)
                    count = struct.unpack_from("<H", page, 4)[0]
                    children = [struct.unpack_from("<I", page, 8)[0]]
                    children.extend(struct.unpack_from("<I", page, 64 + i * 40 + 36)[0] for i in range(count))
                    todo.extend(child for child in children if child)
            self.assertTrue(changed)
            self.assertTrue(changed <= {key // 29 * 1024 for key in pages})
            self.assertEqual(len(before), len(after))
            manifest = Path(str(output) + ".repair.txt").read_text()
            self.assertTrue(manifest.startswith("status: complete\n"))
            self.assertIn("keep: 570; drop: 19", manifest)
            working = Path(temp) / "working.img"
            subprocess.run(["dd", f"if={path}", f"of={working}", "bs=1M", "conv=excl", "status=none"], check=True, timeout=30)
            inode = working.stat().st_ino
            run("repair", working, "--in-place", "--drop-invalid", "ceres")
            self.assertEqual(working.stat().st_ino, inode)
            run("check", working, "ceres")
            self.assertEqual(working.read_bytes(), after)
            self.assertEqual(dict(reference_files(working, "ceres", 1024)), expected)
            manifest = Path(str(working) + ".repair.txt").read_text()
            self.assertTrue(manifest.startswith("status: complete\nmode: in-place\n"))
        self.assertEqual(path.read_bytes(), before)

    def test_native_hard_disks(self):
        cases = [
            ("NativeOberon-2.3.6.img", "natfs", 1159),
            ("NativeOberon-2003-01-05.img", "aos1", 1331),
        ]
        for filename, profile, count in cases:
            with self.subTest(image=filename):
                path = ROOT / "disks/no" / filename
                if not path.exists():
                    self.skipTest("Native Oberon QEMU hard disk not installed")
                before = hashlib.sha256(path.read_bytes()).digest()
                info = run("info", path)
                self.assertIn(f"format: {profile}".encode(), info)
                self.assertIn(f"files: {count}".encode(), info)
                run("check", path)
                self.assertTrue(run("cat", path, "FileDir.Mod"))
                self.assertEqual(hashlib.sha256(path.read_bytes()).digest(), before)

    def test_project(self):
        path = ROOT / "disks/po13/RISC.img"
        if not path.exists():
            self.skipTest("Project Oberon image not installed")
        self.assertIn(b"files: 60", run("info", path))
        self.assertEqual(len(run("cat", path, "Input.rsc")), 1131)
        run("check", path)

    def test_native_zip_crc(self):
        for filename in ("Oberon0.Dsk", "OberonCF0.Dsk"):
            path = ROOT / "disks/no" / filename
            if not path.exists():
                self.skipTest("Native installer images not installed")
            before = hashlib.sha256(path.read_bytes()).digest()
            run("check", path)
            for name, count in (("Oberon0.zip", 102), ("System.zip", 154)):
                with zipfile.ZipFile(io.BytesIO(run("cat", path, name))) as archive:
                    self.assertEqual(len(archive.infolist()), count)
                    self.assertIsNone(archive.testzip())
            self.assertEqual(hashlib.sha256(path.read_bytes()).digest(), before)

    def test_a2(self):
        path = Path(os.environ.get("A2_IMAGE", "/tmp/A2_Rev-6498_serial-trace.iso"))
        if not path.exists() or path.stat().st_size == 0:
            self.skipTest("complete A2 ISO not installed")
        self.assertIn(b"files: 2516", run("info", path))
        run("check", path)
        names = [line.split(b"\t", 1)[1].decode() for line in run("list", path).splitlines()]
        archives = [name for name in names if name.lower().endswith(".zip")]
        self.assertTrue(archives)
        for name in archives:
            with self.subTest(archive=name):
                with zipfile.ZipFile(io.BytesIO(run("cat", path, name))) as archive:
                    self.assertIsNone(archive.testzip())


if __name__ == "__main__":
    unittest.main(verbosity=2)
