# Disk images

We'll provide later a script that downloads the disk images.

Local images for development. The image files are ignored by Git; the
preservation images have not been changed. Derived repair copies are marked as
such. All offsets below are bytes from the start of the image unless stated
otherwise.

The notes date from read-only inspection on 2026-10-13, comparing against the
original filesystem sources. The Oberon reader in this project now passes the
same checks; `make check-images` reruns them together with the ZIP CRC tests.

| Location | Images | Size per image | Layout |
| --- | ---: | ---: | --- |
| `po13/RISC.img` | 1 | 268,865,536 bytes | Project Oberon 2013, 1 KB blocks |
| `no/Oberon0.Dsk` | 1 | 1,474,560 bytes | NatFS, 2 KB blocks; floppy installer |
| `no/OberonCF0.Dsk` | 1 | 1,474,560 bytes | NatFS, 2 KB blocks; CF installer variant |
| `no/NativeOberon-2.3.6.img` | 1 | 83,886,080 bytes | NatFS, 2 KB blocks; installed QEMU system |
| `no/NativeOberon-2003-01-05.img` | 1 | 81,920,000 bytes | AosFS v1, 4 KB blocks; installed QEMU system |
| `ceres/ceres.dat` | 1 | 43,683,840 bytes | Ceres, 1 KB blocks; original dump with inconsistent headers |
| `ceres/ceres-repaired.dat` | 1 | 43,683,840 bytes | Derived Ceres copy; 19 ambiguous/invalid entries excluded |
| `ceres/ceres-inplace.dat` | 1 | 43,683,840 bytes | Separate `dd` working copy, repaired in place; same resulting bytes |
| `aos/A2_Rev-6498_serial-trace.iso` | 1 | 163,889,152 bytes | AosFS v2 inside El Torito/ISO9660 |

## Project Oberon 2013

`po13/RISC.img` has an MBR. Its second partition has type `FFH` and starts at
512-byte sector 524,288 (256 MiB). The root directory is one 1 KB block later,
at byte 268,436,480.

Directory traversal found five B-tree pages and 60 named files. All their
headers and referenced data blocks are within the image. The headers use the
Project Oberon 2013 layout: 32-bit `aleng`, `bleng` and `date` at offsets 36,
40 and 44. For example, `Input.rsc` has 1,131 data bytes.

The MBR declares a 64 MiB second partition, but the image ends only 430,080
bytes after that partition's start. Do not reject the readable filesystem
just because the unused end of the declared partition is absent. Do not read
beyond the actual image either.

## Native Oberon installers

Both images have an `OBERON` boot sector with 491 reserved 512-byte sectors.
Their NatFS root is at byte 251,392 (`491 * 512`). Encoded address 29 denotes
the root block itself; this differs from the Project Oberon image's block
offset convention.

Each directory has two files:

| Image | `Oberon0.zip` | `System.zip` |
| --- | ---: | ---: |
| `no/Oberon0.Dsk` | 570,274 bytes | 633,108 bytes |
| `no/OberonCF0.Dsk` | 570,501 bytes | 633,108 bytes |

The file headers are at bytes 660,992 and 1,234,432 respectively. They have
16-bit length fields and separate 32-bit date/time fields, matching NatFS.
Reading the direct and single-indirect block tables recovered both ZIP
archives from each image. ZIP CRC checks passed for all 102 members of
`Oberon0.zip` and all 154 members of `System.zip` in both images. Nothing was
extracted to disk.

Magic values also appear as constants inside the installer code. Finding a
magic value somewhere in an image is not enough to identify a disk record.

## Native Oberon QEMU hard disks

Downloaded read-only test copies from [asig/native-oberon](https://github.com/asig/native-oberon)
at commit `d43ce6e516fee6f3818d20f56abd1e1e6dbd5e9a`. Both files are raw
disk images, not qcow2, and their Git blob hashes were verified after download:

* [Native Oberon 2.3.6](https://raw.githubusercontent.com/asig/native-oberon/d43ce6e516fee6f3818d20f56abd1e1e6dbd5e9a/2.3.6/Native%20Oberon%202.3.6.img):
  Git blob `5f3e6fdfdadb0b9c2a2fb3987e7a259f75a0cc0e`.
* [Native Oberon 2003-01-05](https://raw.githubusercontent.com/asig/native-oberon/d43ce6e516fee6f3818d20f56abd1e1e6dbd5e9a/20030105/Native%20Oberon%202003-01-05.img):
  Git blob `72ab9b492a6377a495eccda04ac0dd4bc66ae5d7`.

The 2.3.6 image has one type-`4FH` partition, starting at sector 63. Its
`OBERON` header reserves eight 512-byte sectors; the NatFS root is at byte
36,352. It has 33 B-tree pages, 1,159 files and 23,235,413 file-data bytes.

The 2003-01-05 image has one type-`4CH` partition, also starting at sector 63.
Its footer specifies AosFS v1 and a filesystem offset of 1,032 512-byte
sectors. The root is at byte 560,640. It has 21 B-tree pages, 1,331 files and
28,275,632 file-data bytes. The `OBERON` OEM string alone would misidentify it
as NatFS.

Both images pass the standalone filesystem checker. The mount regression
compares all their files with an independent byte-level reader.

## Ceres

[obdisk](https://github.com/gh055/obdisk) links to a Bitsavers reference dump.
The README's lowercase `eth` path is broken; uppercase `ETH` works:
[disk archive](https://www.bitsavers.org/bits/ETH/Ceres/ceres_xt2190.zip) and
[extracted-file archive](https://www.bitsavers.org/bits/ETH/Ceres/ceres_xt2190_files.zip).
The raw ZIP member is `ceres_xt2190/ceres.dat`.

The image confirms the Ceres profile's byte offsets, integer widths and
block-address convention. It has 38 directory pages and 589 named files.
Sixteen headers have zero length fields, implying negative payload lengths;
the strict reader rejects these instead of showing them as empty files. All
588 independently archived extracted files match byte for byte, including the
empty outputs that the reference extractor produces for those headers.

Allocation checking additionally finds eight overlaps involving three other
files. Salvage and conservative repair therefore exclude 19 entries and retain
570 files. The local new-copy result is `ceres/ceres-repaired.dat`; its report
is `ceres/ceres-repaired.dat.repair.txt`. It passes the checker and read-only
FUSE comparisons, but is not evidence of recovered data or Ceres bootability.
The original dump bytes remain unchanged.

`ceres/ceres-inplace.dat` shows the copy-then-repair workflow: it was copied
from `ceres.dat` with `dd`, then repaired with
`repair ... --in-place --drop-invalid ceres`. That repair creates no
replacement image. Its bytes match `ceres-repaired.dat`; its report is
`ceres/ceres-inplace.dat.repair.txt`. Both are disposable derived artifacts.

See the [Ceres notes](../docs/ceres.md) for record tables, exact conflicts,
repair policy and independent all-file comparisons.

## A2 CDs

[SourceForge](https://sourceforge.net/projects/a2oberon/files/) lists several
installer ISOs from 2014 and 2015. The
[revision 6498 image](https://sourceforge.net/projects/a2oberon/files/A2_Rev-6498_serial-trace.iso/download)
is dated 2015-10-23 and is 163,889,152 bytes. The local copy is
`disks/aos/A2_Rev-6498_serial-trace.iso`.

The image confirms the A2 build scripts' layout. The outer ISO9660 root has
only `.` and `..` records. The boot catalog is at CD sector 19; its embedded
boot image starts at CD sector 23. The boot header's Aos footer specifies
version 2, 4 KB blocks and a filesystem offset of 2,056 512-byte sectors.
The resulting root is at byte 1,099,776. Traversal found 121 B-tree pages and
2,516 named files.

The embedded boot sector still has an `OBERON` OEM identifier. Check the Aos
footer first, or it will be misidentified as NatFS. The driver now follows
the catalog and footer, reads the files, and passes allocation checks. All
ZIP archives recovered by `make check-images` pass their CRC checks. See
the source links in the [main readme](../readme.md#source-material).

## Checksums

SHA-256 for the local Oberon images:

```text
92382fea824cf8ba1662ea2b8704289d121acab58b70fc4afbe012c79fca197d  po13/RISC.img
b58f5a7a01121749c83f15e2af02e4f3fc90e63ac3c04ec61cce1aa76b84fc4c  no/Oberon0.Dsk
2fc85d6cba64aeda97773f06e2bc7d22926970d3387151e24b5e312873c53801  no/OberonCF0.Dsk
65f21c27cd62ceffab303d7266606f4db3c22e83be462f8a70a0f0ea4f8c60d1  no/NativeOberon-2.3.6.img
40135a8f941e70268f3cc0ab02c04ae4957a6fb4756acb2b2756298ff0458c8c  no/NativeOberon-2003-01-05.img
41271eaf358717563f29354bd1991c28c2594760fda8797c85d5f4979f2ad9b4  ceres/ceres.dat
d8c59b4c0d47ed3343a91194bc97db9bf0d141c103ea9a31d11490a18ec7e713  ceres/ceres_xt2190_files.zip
624ca75b5af7e67a99500159d314b1b8e282873bc6d43604425a0942bfe3eb6c  aos/A2_Rev-6498_serial-trace.iso
```

Derived repair artifact (not a preservation image):

```text
14cf2ee6903975ed5d3e5e8d80e8c6bb2f46cd18399c502864827e59624fb18d  ceres/ceres-repaired.dat
14cf2ee6903975ed5d3e5e8d80e8c6bb2f46cd18399c502864827e59624fb18d  ceres/ceres-inplace.dat
```

The original `ceres_xt2190.zip` archive is 85,598,177 bytes, with SHA-256
`30611675468c0829e4f67478f56cee7ec43f49f5956bc23a341bed85b17e4e90`.
