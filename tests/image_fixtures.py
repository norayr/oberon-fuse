"""Small disk layouts written independently of the Oberon implementation."""

import struct


PROFILES = {
    "project": (1024, 352, 32, 64, 64, 96, 48, False),
    "natfs": (2048, 352, 32, 48, 64, 96, 48, True),
    "ceres": (1024, 352, 32, 64, 64, 96, 48, True),
    "aos1": (4096, 568, 32, 16, 128, 52, 564, False),
    "aos2": (4096, 664, 128, 16, 128, 148, 660, False),
}


def u32(buffer, offset, value):
    struct.pack_into("<I", buffer, offset, value)


def make_image(profile, large=True, files=None, directory=True):
    block_size, header_size, name_bytes, directory_offset, direct_count, direct_offset, index_offset, short = PROFILES[profile]
    blocks = [bytearray(block_size)]
    if files is None:
        files = {"A.Empty": b"", "B.Small": b"Oberon disk test\n\x00\xff"}
        if large:
            # Cross both the direct/indirect boundary and a second index table.
            size = (direct_count + block_size // 4 + 2) * block_size - header_size - 17
            files["C.Large"] = bytes(range(256)) * (size // 256) + bytes(range(size % 256))
        files["Z" + "x" * (name_bytes - 2)] = b"maximum filename"
    headers = {}

    def allocate():
        blocks.append(bytearray(block_size))
        return len(blocks) * 29

    def block(key):
        return blocks[key // 29 - 1]

    for name, data in sorted(files.items()):
        total = header_size + len(data)
        keys = [allocate() for _ in range((total + block_size - 1) // block_size)]
        head = block(keys[0])
        headers[name] = keys[0]
        u32(head, 0, 0x9BA71D86)
        encoded_name = name.encode("ascii")
        head[4:4 + len(encoded_name)] = encoded_name
        a, z = divmod(total, block_size)
        if z == 0:
            a, z = a - 1, block_size
        struct.pack_into("<HH" if short else "<II", head, name_bytes + 4, a, z)
        for i, key in enumerate(keys[:direct_count]):
            u32(head, direct_offset + i * 4, key)
        extra = keys[direct_count:]
        tables = []
        while extra:
            table = allocate()
            tables.append(table)
            for i, key in enumerate(extra[:block_size // 4]):
                u32(block(table), i * 4, key)
            extra = extra[block_size // 4:]
        if profile.startswith("aos") and tables:
            super_table = allocate()
            u32(head, index_offset, super_table)
            for i, key in enumerate(tables):
                u32(block(super_table), i * 4, key)
        elif tables:
            for i, key in enumerate(tables):
                u32(head, index_offset + i * 4, key)
        for i, value in enumerate(data, header_size):
            block(keys[i // block_size])[i % block_size] = value

    if directory:
        directory = blocks[0]
        u32(directory, 0, 0x9B1EA38D)
        struct.pack_into("<H" if profile in ("ceres", "natfs") else "<I", directory, 4, len(files))
        for i, name in enumerate(sorted(files)):
            offset = directory_offset + i * (name_bytes + 8)
            encoded_name = name.encode("ascii")
            directory[offset:offset + len(encoded_name)] = encoded_name
            u32(directory, offset + name_bytes, headers[name])
    root = 1024 if profile in ("project", "ceres") else 0
    return bytearray(root) + b"".join(blocks), files, headers, root


def make_tree(profile):
    """A balanced tree with a root separator and two half-full leaves."""
    bs, _, names, directory_offset, _, _, _, short = PROFILES[profile]
    minimum = ((bs - directory_offset) // (names + 8)) // 2
    files = {f"F{i:03d}": f"file {i}\n".encode() for i in range(2 * minimum + 1)}
    image, _, headers, root = make_image(profile, files=files, directory=False)
    left, right = [(len(image) - root) // bs * 29 + i * 29 for i in (1, 2)]
    image.extend(bytes(2 * bs))
    image[root:root + bs] = bytes(bs)

    def page(key, entries, p0=0, child=0):
        base = root + (key // 29 - 1) * bs
        u32(image, base, 0x9B1EA38D)
        struct.pack_into("<H" if short else "<I", image, base + 4, len(entries))
        u32(image, base + 8, p0)
        for i, name in enumerate(entries):
            offset = base + directory_offset + i * (names + 8)
            image[offset:offset + len(name)] = name.encode()
            u32(image, offset + names, headers[name])
            u32(image, offset + names + 4, child)

    ordered = sorted(files)
    page(29, ordered[minimum:minimum + 1], left, right)
    page(left, ordered[:minimum])
    page(right, ordered[minimum + 1:])
    return image, files, root, left, right


def make_deep_tree(profile, height=2):
    """A full, balanced multi-level tree with independent real-style headers."""
    bs, _, names, directory_offset, _, _, _, short = PROFILES[profile]
    capacity = (bs - directory_offset) // (names + 8)
    occupied = capacity * 3 // 4

    def count(level, root=False):
        keys = 1 if root else occupied
        return keys if level == 0 else keys + (keys + 1) * count(level - 1)

    total = count(height, True)
    files = {f"F{i:06d}": f"file {i}\n".encode() for i in range(total)}
    image, _, headers, root = make_image(profile, files=files, directory=False)
    ordered = iter(sorted(files))

    def allocate():
        image.extend(bytes(bs))
        return ((len(image) - root) // bs) * 29

    def page(key, level, is_root=False):
        m = 1 if is_root else occupied
        b = bytearray(bs)
        u32(b, 0, 0x9B1EA38D)
        struct.pack_into("<H" if short else "<I", b, 4, m)
        for i in range(m + 1):
            child = 0
            if level > 0:
                child = allocate()
                page(child, level - 1)
            if i == 0:
                u32(b, 8, child)
            else:
                u32(b, directory_offset + (i - 1) * (names + 8) + names + 4, child)
            if i < m:
                name = next(ordered)
                offset = directory_offset + i * (names + 8)
                b[offset:offset + len(name)] = name.encode()
                u32(b, offset + names, headers[name])
        base = root + (key // 29 - 1) * bs
        image[base:base + bs] = b

    page(29, height, True)
    return image, files, headers, root


def make_boot_cd(profile="aos2"):
    """Minimal El Torito metadata for detector tests, not a full ISO writer."""
    payload, files, _, root = make_image(profile, large=False)
    assert root == 0
    start = 23 * 2048
    image = bytearray(start + 4096) + payload
    image[17 * 2048:17 * 2048 + 7] = b"\x00CD001\x01"
    identifier = b"EL TORITO SPECIFICATION"
    image[17 * 2048 + 7:17 * 2048 + 7 + len(identifier)] = identifier
    u32(image, 17 * 2048 + 71, 19)
    catalog = 19 * 2048
    image[catalog] = 1
    image[catalog + 30:catalog + 32] = b"\x55\xaa"
    checksum = (-sum(struct.unpack_from("<16H", image, catalog))) & 0xFFFF
    struct.pack_into("<H", image, catalog + 28, checksum)
    image[catalog + 32:catalog + 34] = b"\x88\x02"
    struct.pack_into("<H", image, catalog + 38, 1)
    u32(image, catalog + 40, 23)
    image[start + 3:start + 9] = b"OBERON"  # Aos footer must take precedence.
    image[start + 510:start + 512] = b"\x55\xaa"
    struct.pack_into("<H", image, start + 14, 8)
    if profile.startswith("aos"):
        struct.pack_into("<III", image, start + 496, 8, len(payload) // 4096, 0x21534F41)
        image[start + 508:start + 510] = bytes([int(profile[-1]), 12])
    else:
        u32(image, start + 32, (4096 + len(payload)) // 512)
    return image, files
