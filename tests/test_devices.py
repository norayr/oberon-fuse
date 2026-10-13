"""Optional block-device tests using only newly allocated disposable loop devices."""
from contextlib import contextmanager
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from image_fixtures import PROFILES
from reference_image import files as reference_files
from test_mount import mounted, ROOT

TOOL = ROOT / "build/oberon-image"


@contextmanager
def loop_device(path):
    losetup = shutil.which("losetup")
    if not losetup:
        raise unittest.SkipTest("losetup unavailable")
    result = subprocess.run([losetup, "--find", "--show", str(path)], capture_output=True, text=True)
    if result.returncode:
        raise unittest.SkipTest(f"cannot allocate a disposable loop device: {result.stderr.strip()}")
    device = result.stdout.strip()
    try:
        yield device
    finally:
        subprocess.run([losetup, "--detach", device], check=True, capture_output=True)


class Devices(unittest.TestCase):
    def test_format_check_mount_and_device_exclusion(self):
        with tempfile.TemporaryDirectory(prefix="loop-test-", dir=ROOT / "build") as temp:
            path = Path(temp) / "backing.img"
            with path.open("wb") as file:
                file.truncate(16 * 1024 * 1024)
            with loop_device(path) as device:
                for profile in PROFILES:
                    for container in ("raw", "hdd"):
                        if profile == "ceres" and container == "hdd":
                            continue
                        with self.subTest(profile=profile, container=container):
                            subprocess.run([str(TOOL), "mkfs", profile, device, "--erase-device", container], check=True, capture_output=True)
                            options = [profile] if container == "raw" else []
                            subprocess.run([str(TOOL), "check", device, "--device", *options], check=True, capture_output=True)
                            with mounted(device, "--device", "--rw", *options) as mountpoint:
                                (mountpoint / "OnFlash").write_bytes(b"Oberon block device\n")
                                for operation in (["check", device, "--device", *options],
                                                  ["mkfs", profile, device, "--erase-device", container]):
                                    result = subprocess.run([str(TOOL), *operation], capture_output=True)
                                    self.assertEqual(result.returncode, 1, result.stderr)
                            subprocess.run([str(TOOL), "check", device, "--device", *options], check=True, capture_output=True)
                            root = 1024 if profile in ("project", "ceres") else 0
                            if container == "hdd":
                                root += 1048576 if profile == "project" else 1048576 + 32768
                            self.assertEqual(dict(reference_files(path, profile, root)), {"OnFlash": b"Oberon block device\n"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
