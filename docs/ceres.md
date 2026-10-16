# Ceres disk layout and reference dump

The Ceres profile follows the disk records in the Oberon V2/V4 `FileDir` and
`Files` modules. We checked the record layout against the disk dump and
extracted files in the [Bitsavers Ceres archive](https://www.bitsavers.org/bits/ETH/Ceres/).

## Disk layout

The filesystem uses little-endian numbers and 1,024-byte blocks. Disk addresses
are multiples of 29. In a raw image beginning at logical block zero:

```text
byte offset = (disk address DIV 29) * 1024
root address = 29
root byte offset = 1024
```

`FileDir` defines a B-tree with 24 entries per directory page. Each entry is
40 bytes: a 32-byte zero-terminated name, a 32-bit file-header address and a
32-bit right-child address. A non-root page contains at least 12 entries.

| Directory-page offset | Bytes | Meaning |
| ---: | ---: | --- |
| 0 | 4 | `9B1EA38DH` directory marker |
| 4 | 2 | Entry count |
| 6 | 2 | Alignment padding |
| 8 | 4 | Left-child address |
| 12 | 52 | Filler |
| 64 | 960 | 24 directory entries |

Files start in the unused portion of their first block, after a 352-byte
header. The first direct address points back to that same header block.

| File-header offset | Bytes | Meaning |
| ---: | ---: | --- |
| 0 | 4 | `9BA71D86H` header marker |
| 4 | 32 | Filename, including terminating zero |
| 36 | 2 | `aleng`: index of final allocated block |
| 38 | 2 | `bleng`: bytes used in that block |
| 40 | 4 | Date |
| 44 | 4 | Time |
| 48 | 48 | 12 single-indirect table addresses |
| 96 | 256 | 64 direct block addresses |
| 352 | 672 | First bytes of file content |

Each indirect table holds 256 addresses. File length, excluding the header,
is `aleng * 1024 + bleng - 352`. An empty file has
`aleng = 0, bleng = 352`. A zero-byte final block with a positive `aleng`
still counts as an allocated block.

The [Project Oberon 2013 (PO13)](https://people.inf.ethz.ch/wirth/ProjectOberon/)
SD-card filesystem for the Xilinx Spartan-3 FPGA computer uses the same block
and header sizes, but 32-bit length fields and a packed timestamp. Raw images
of the two formats look alike, so open them with an explicit profile.

## Real dump

The dump referenced by [obdisk](https://github.com/gh055/obdisk) is archived
at Bitsavers:

* [Original archive](https://www.bitsavers.org/bits/ETH/Ceres/ceres_xt2190.zip).
* [Archived extracted files](https://www.bitsavers.org/bits/ETH/Ceres/ceres_xt2190_files.zip).

The dump archive contains the raw image `ceres_xt2190/ceres.dat` and the
additional capture files `ceres.em` and `ceres.tr`. The driver reads
`ceres.dat`; the capture files remain undecoded.

The local raw copy is `disks/ceres/ceres.dat`, 43,683,840 bytes. Its root is
at byte 1,024. Traversal found 38 directory pages and 589 named files.

Sixteen headers have `aleng = 0, bleng = 0`, although their marker, name and
first direct address are present. Their calculated payload length is -352.
The `Files` code we looked at requires a nonnegative payload length. We do
not know what produced these values. Strict opening rejects the volume when
it reaches `Ceres1.Boot`.

We compared the archive against the dump with an independent reader; all 588
members matched byte for byte. For the sixteen headers with negative
calculated lengths, obdisk exports zero-byte files. The directory also
contains `Huebner.Text`, 1,783 bytes, which is absent from that archive.

## Allocation conflicts, salvage and repair

The allocation checker also finds eight references to invalid entries' header
blocks from three otherwise decodable files:

| Data owner | Conflicting header entries |
| --- | --- |
| `ET.Mod2` | `Syntax14.Scn.Fnt`, `Syntax14b.Scn.Fnt`, `Syntax14i.Scn.Fnt`, `Syntax20.Scn.Fnt`, `Syntax20b.Scn.Fnt`, `Syntax20i.Scn.Fnt` |
| `FPGABoard.Text` | `Ceres1.Boot0` |
| `TerminalFrames.Mod` | `Miscellaneous.Tool` |

Ownership of the shared blocks is ambiguous. Salvage and repair exclude all
sixteen entries with invalid lengths and all three conflicting data owners:
**19 excluded entries, 570 retained files**.
The checker reports 32 issues: sixteen short lengths and sixteen overlap
diagnostics (both sides of the eight conflicts).

Mount the original dump read-only with `--salvage ceres` to expose the 570
usable files. Salvage leaves the image unchanged. Strict mounting rejects
the original dump.

`repair IMAGE --in-place --drop-invalid ceres` rebuilds the directory of an
existing working copy, excluding these nineteen entries. Make a separate
copy of the original first. Repair can also copy the source to a new output
file before rebuilding its directory.

Both modes preserve file headers and data and reuse original directory
blocks. The rebuilt tree has 24 pages and 570 files and passes strict
decoding and allocation checks. Keep the original dump and its archives for
further recovery: they retain the excluded directory entries and all
available data. Later writes in Oberon can reuse blocks left unreachable
in the repaired copy.

The local repaired copies are:

* `disks/ceres/ceres-repaired.dat`, created in new-output mode, with
  `ceres-repaired.dat.repair.txt`.
* `disks/ceres/ceres-inplace.dat`, copied from the original with `dd` and
  repaired in place, with its own `mode: in-place` report.

The repaired bytes are identical. In-place tests also check that the image
retains its inode and size. The repaired copies have not been boot-tested on
a Ceres system. See the [copy/check/repair/mount workflow](../readme.md#copy-an-original-check-it-and-repair-the-copy-in-place).

## Tests and limits

`make check-images` checks:

* Strict rejection of the original dump and preservation of its bytes.
* All 588 archived files against an independent reader.
* Selected valid file records through the production decoder, using a
  temporary fixture whose root references the original headers, addresses
  and content.
* Salvage of the original and both repair modes on temporary working copies.
* Byte-for-byte equality of new-output and in-place repair results, with
  changes confined to original directory blocks.
* All 570 retained files against the independent reader, including the 569
  also present in the extracted-file archive.

`make check-mount` mounts the fixture containing the three largest valid
archived files, the original dump in salvage mode, and copies repaired by
both modes in strict mode. It compares all 570 retained files through FUSE
and verifies that mounting leaves image bytes unchanged.

Set `CERES_IMAGE` and `CERES_FILES` to use the raw dump and extracted-file ZIP
from other paths. Supply these files locally; tests keep the preservation
images unchanged.

## Sources

* [Ceres V4 FileDir](https://github.com/Project-Oberon/Source-Code/blob/cf7f6a6cda1c5e58299726ec578ffde76ce8a6bf/CERES%20Oberon%20V4/ASCII/FileDir.Mod.txt): constants and disk records.
* [Ceres V4 Files](https://github.com/Project-Oberon/Source-Code/blob/cf7f6a6cda1c5e58299726ec578ffde76ce8a6bf/CERES%20Oberon%20V4/ASCII/Files.Mod.txt): length convention and file-block tables.
* [obdisk header definitions](https://github.com/gh055/obdisk/blob/aa79b7981c4de9dc20ac9ebc7d09c7c13dd1206c/src/_obdisk/obdisk.h) and [disk reader](https://github.com/gh055/obdisk/blob/aa79b7981c4de9dc20ac9ebc7d09c7c13dd1206c/src/_obdisk/ob_disk.c): independent layout comparison. The obdisk code is GPL-3.0; this project uses it as a format reference.
