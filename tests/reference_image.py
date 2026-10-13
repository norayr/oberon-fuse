"""Independent byte-level reader used only to compare known preservation images."""

import os
import struct

from image_fixtures import PROFILES


def block(image, key, bs, root):
    assert key > 0 and key % 29 == 0
    image.seek(root + (key // 29 - 1) * bs)
    data = image.read(bs)
    assert len(data) == bs
    return data


def directory(path, profile, root):
    bs, _, names, directory_offset, _, _, _, short = PROFILES[profile]
    with path.open("rb") as image:
        def walk(key):
            page = block(image, key, bs, root)
            assert page[:4] == b"\x8d\xa3\x1e\x9b"
            count = struct.unpack_from("<H" if short else "<I", page, 4)[0]
            child = struct.unpack_from("<I", page, 8)[0]
            if child:
                yield from walk(child)
            for i in range(count):
                offset = directory_offset + i * (names + 8)
                name = page[offset:offset + names].split(b"\0", 1)[0]
                pointer, child = struct.unpack_from("<II", page, offset + names)
                yield os.fsdecode(name), pointer
                if child:
                    yield from walk(child)

        yield from walk(29)


def files(path, profile, root):
    bs, hs, names, _, direct_count, direct_offset, index_offset, short = PROFILES[profile]
    with path.open("rb") as image:
        def read(key):
            head = block(image, key, bs, root)
            assert head[:4] == b"\x86\x1d\xa7\x9b"
            a, z = struct.unpack_from("<HH" if short else "<II", head, names + 4)
            keys = list(struct.unpack_from(f"<{direct_count}I", head, direct_offset))
            if a >= direct_count:
                if profile.startswith("aos"):
                    pointer = struct.unpack_from("<I", head, index_offset)[0]
                    indexes = struct.unpack(f"<{bs // 4}I", block(image, pointer, bs, root))
                else:
                    indexes = struct.unpack_from("<12I", head, index_offset)
                for pointer in indexes[:(a - direct_count) // (bs // 4) + 1]:
                    keys.extend(struct.unpack(f"<{bs // 4}I", block(image, pointer, bs, root)))
            content = b"".join(block(image, pointer, bs, root) for pointer in keys[:a + 1])
            # This test reader mirrors obdisk's empty output for underflowing
            # lengths. The production checker must reject those headers.
            return content[hs:a * bs + z]

        for name, key in directory(path, profile, root):
            yield name, read(key)


def ceres_salvage_files(path):
    """Expected intact files in the Bitsavers dump, independent of the CLI.

    Sixteen short headers plus three data owners conflicting with some of
    those headers are excluded. This is deliberately not a general checker.
    """
    rejected = {"ET.Mod2", "FPGABoard.Text", "TerminalFrames.Mod"}
    with path.open("rb") as image:
        for name, key in directory(path, "ceres", 1024):
            head = block(image, key, 1024, 1024)
            a, z = struct.unpack_from("<HH", head, 36)
            if a * 1024 + z < 352:
                rejected.add(name)
    assert len(rejected) == 19
    return {name: data for name, data in files(path, "ceres", 1024) if name not in rejected}


def isolated_files(path, profile, root, names):
    """Derived test fixture: replace only the directory root, not file records.

    Unselected allocations remain in the copy but are unreachable. Never write
    the result back to a preservation image or interpret it as a disk repair.
    """
    bs, _, width, offset, _, _, _, short = PROFILES[profile]
    names = sorted(names)
    assert len(names) <= (bs - offset) // (width + 8)
    pointers = dict(directory(path, profile, root))
    data = bytearray(path.read_bytes())
    data[root:root + bs] = bytes(bs)
    struct.pack_into("<I", data, root, 0x9B1EA38D)
    struct.pack_into("<H" if short else "<I", data, root + 4, len(names))
    for i, name in enumerate(names):
        entry = root + offset + i * (width + 8)
        encoded = os.fsencode(name)
        assert len(encoded) < width
        data[entry:entry + len(encoded)] = encoded
        struct.pack_into("<I", data, entry + width, pointers[name])
    return data
