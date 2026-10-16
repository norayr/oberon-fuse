# oberon-fuse

This is a FUSE driver for different formats of Oberon disk images.
The driver is written in Oberon by using [voc](https://github.com/vishapoberon/voc).

Supported formats are [Project Oberon 2013][wirth] (PO13), NatFS, Ceres and
AosFS versions 1 and 2.

By default mounts are read-only. Option `--rw` exists to create, overwrite, append, truncate, delete and rename files on a working volume.

The `oberon-image` tool is able to inspect images, exports files, check
allocations, create and format filesystems, and repairs directories.

Formatting or repairing an existing file requires `--in-place`.

THIS IS NOT a production ready stable driver.
Make sure you have backups of images (and devices?) you are working with.

Repair excludes directory entries with invalid headers or conflicting
allocations and preserves file data.
The formatter creates empty, nonbootable filesystems.

We have tested images from PO13, both Native Oberon installers, the [Native Oberon QEMU hard disks](https://github.com/asig/native-oberon), and the A2 revision 6498 CD, including kernel FUSE mounts.
The 2003 image uses AosFS v1. The [Ceres dump archived by Bitsavers](https://www.bitsavers.org/bits/ETH/Ceres/)
has sixteen inconsistent headers and allocation overlaps: strict opening
rejects it, while salvage and repair retain 570 files.

See the [Ceres notes](docs/ceres.md).

## Disk formats

The supported filesystems all come from Wirth's B-tree directory design, but
each has its own disk layout, so each gets its own decoding profile.

The `project` profile handles PO13's SD-card layout for the Xilinx Spartan-3
FPGA computer.

| Format | Block size | Maximum filename | File header | Directory entries per block |
| --- | ---: | ---: | ---: | ---: |
| Ceres Oberon V2/V4 | 1,024 bytes | 31 bytes | 352 bytes | 24 |
| PO13 / Extended Oberon | 1,024 bytes | 31 bytes | 352 bytes | 24 |
| PC Native Oberon: NatFS / N2KFS | 2,048 bytes | 31 bytes | 352 bytes | 50 |
| AosFS version 1 | 4,096 bytes | 31 bytes | 568 bytes | 102 |
| AosFS version 2 | 4,096 bytes | 127 bytes | 664 bytes | 30 |

Filename limits are in bytes, excluding the terminating zero. All five
profiles read directories and files through the shared code in
`OberonBTree.Mod`.

Ceres and PO13 both have 1 KB blocks, 352-byte file headers, 32-byte filename
fields, 64 direct block addresses and 12 single-indirect block tables.

Two file-header fields encode the file length:

* `aleng` is the zero-based index of the final allocated file block. Block
  zero contains the file header.
* `bleng` is the number of bytes used in that final block. For a single-block
  file, this includes the header.

The length of the file content is:

```text
content length = aleng * block size + bleng - header size
```

An empty file has `aleng = 0` and `bleng = 352`, accounting for its header.
The same fields sit at different offsets and have different widths:

| Header offset | Ceres | PO13 |
| ---: | --- | --- |
| 36 | 16-bit `aleng` | 32-bit `aleng` |
| 38 | 16-bit `bleng` | continuation of `aleng` |
| 40 | 32-bit `date` | 32-bit `bleng` |
| 44 | 32-bit `time` | 32-bit `date` |

Directory entry counts also use different integer widths, so pick the profile
that matches the image's field layout.

Later ETH/A2 sources call the PC Native Oberon 2 KB format NatFS or N2KFS.
`CeresFS.Mod` implements the Ceres 1 KB profile.

The [NativeOberon-2.3.6-Extracted repository][native] holds files from a full
Native Oberon 2.3.6 installation, converted to plain text under
`FullInstall_ASCII/`. Its `Files.Mod` and `FileDir.Mod` implement NatFS.

The later alpha sources keep those two names but make them shims over a
generic layer: `OFS.Mod` dispatches file operations to mounted file systems,
`OFSN2KFiles.Mod` carries the 2 KB NatFS format, and `OFSAosFiles.Mod` is an
AosFS v1 driver. The [Oberon-Linux-Revival repository][olr] has the whole
OFS module family as plain-text conversions.

AosFS uses 128 direct block addresses and a double-indirect extension. Version
2 expands the filename field from 32 to 128 bytes. Aos boot headers from
before March 2000 locate volumes differently; their metadata uses the AosFS
v1 profile. The driver accepts both boot header layouts.

Two more custom formats turn up in the source collections:

* The Oberon backup-floppy format uses FAT12-style allocation, custom 32-byte
  directory entries and a 22-byte filename field. It needs a separate decoder.
  Ceres and later Native implementations differ in their volume markers and
  date handling.
* A2's SSFS (Simple Silly File System) is an educational filesystem with 4 KB
  blocks, a superblock, a free-block bitmap and inodes.

A2 also has modules for FAT, ISO9660, ZIP, host and network filesystems. The
list above covers the formats found in the examined source collections.

### Installer images

The Native Oberon installers `Oberon0.Dsk` and `OberonCF0.Dsk` are 1.44 MB
NatFS images.

[asig/native-oberon][native-vms] hosts installed raw QEMU hard disks for
Native Oberon 2.3.6 and 2003-01-05. They contain 1,159 NatFS files and 1,331
AosFS v1 files respectively. See the [disk notes](disks/readme.md#native-oberon-qemu-hard-disks)
for download locations and checksums. QEMU's `qcow2` container must be
converted to raw first: `qemu-img convert -f qcow2 -O raw INPUT.qcow2 NEW-OUTPUT.img`.

A2's [CD build script][a2-build] formats an AosFS v2 disk image and wraps it in
ISO9660 with an El Torito boot catalog. The system files are in that embedded
image; [the ISO writer][a2-iso] creates an otherwise empty ISO9660 directory.
[`DiskVolumes.GetOberonFS`][a2-volumes] follows the catalog to the embedded boot
sector, then reads the filesystem offset. The driver locates that container
and reads its contents with the AosFS v2 profile.

Published A2 CDs are still listed in the [SourceForge archive][a2-images],
including [revision 6498, dated 2015-10-23][a2-6498]. The downloaded image has
2,516 named files in AosFS v2, with its root at byte 1,099,776. Its ISO9660 root
contains only the `.` and `..` directory records.

## Limits and metadata

### File and image sizes

The table lists what the decoder reads and what the formatter writes.
Large-volume compatibility with the original Oberon systems is untested.
MiB is 1,048,576 bytes, GiB is 1,073,741,824 bytes.

| Profile | Maximum file payload | Approximate payload size | Formatter's maximum filesystem block area |
| --- | ---: | ---: | ---: |
| Ceres | 3,210,912 bytes | 3.06 MiB | 70.62 GiB |
| PO13 | 3,210,912 bytes | 3.06 MiB | 70.62 GiB |
| NatFS | 12,713,632 bytes | 12.12 MiB | 141.24 GiB |
| AosFS v1 | 4,295,491,016 bytes | 4 GiB + 512 KiB - 568 bytes | 282.48 GiB |
| AosFS v2 | 4,295,490,920 bytes | 4 GiB + 512 KiB - 664 bytes | 282.48 GiB |

File capacities exclude the header and come from the address tables in
`OberonBTree.Mod`: `(64 + 12 * (blockSize DIV 4)) * blockSize - headerSize`
for Ceres, PO13 and NatFS, and
`(128 + (blockSize DIV 4) * (blockSize DIV 4)) * blockSize - headerSize`
for AosFS. We have not tested maximum-size files.

`ImageCreate.Mod` limits the filesystem block count to
`2147483647 DIV 29 = 74,051,160`, following the historical signed
disk-address range and the address multiplier of 29. The table shows that
count times the block size; reserved prefixes and any trailing partial block
change the total image size. The reader is not bound by this formatter limit:
it uses 64-bit host offsets and checks accesses against the actual image and
volume sizes.

Formatting requires a 512-byte-aligned image size and room for at least four
complete filesystem blocks from the root offset. Raw minimum sizes are 5 KiB
for Ceres and PO13, 8 KiB for NatFS and 16 KiB for AosFS. HDD images need their
reserved prefix too. Native floppy images have the fixed size 1,474,560 bytes.
Formatting also limits the image's 512-byte sector count to `2^32 - 1`.

### Driver and checker limits

The filesystem has a flat directory. Dots are part of filenames.
Filename limits are 31 bytes for Ceres, PO13, NatFS and AosFS v1, and 127 bytes
for AosFS v2, excluding the terminating zero.

The directory loader accepts at most 100,000 files and a tree depth of 32.
The checker tracks at most 1,048,576 distinct allocated blocks, including
directory and index blocks, and allows 2,097,152 work steps. It stores the
first 10,000 diagnostic records and counts more issues without storing them.
Salvage and repair stop when an allocation or work limit is reached.

The allocation budget covers at most 1 GiB of allocated blocks for Ceres and
PO13, 2 GiB for NatFS, or 4 GiB for AosFS, including metadata. Empty space
costs nothing. An AosFS file near the layout maximum exceeds the full
checker's budget. Ordinary reads and read-only mounts validate directory and
header structure; writable mounts run the full allocation check before
publishing each changed file or directory.

Regular image files are the default; Linux block-device access requires
`--device`. Convert qcow2 containers to raw before opening them. The driver
handles a flat file namespace, file contents and modification times. It does
not handle subdirectories, links, Unix ownership or mode changes, xattrs, or
executable permission bits. In-place repair can leave an inconsistent image
after an interruption or write error.

### Concurrent clients

The FUSE request loop runs libfuse's single-threaded `-s` mode: Linux queues
requests from multiple processes and the daemon executes one callback at a
time. Requests from concurrent file copies can interleave. Image reads use
explicit offsets through `pread`.

Concurrent clients share the throughput of one request-processing worker. The
tests run two Linux `cp` processes on synthetic images of all five profiles
and compare the copied bytes and the original images. Concurrent Oberon
callbacks would need a separate review of VOC runtime thread safety first.

Writable mounts also serialize requests. Open handles keep their file identity
across rename and unlink, and clients see shared staged updates. Kernel
file-data and attribute caching are off. The disposable-image tests exercise
two simultaneous writing clients and shared open handles.

### Read cache

The mount option `--cache-mib N` enables a bounded read-through block cache:

```sh
build/oberon-fuse working.img mnt --cache-mib 32 aos2
build/oberon-fuse working.img mnt --rw --cache-mib 32 aos2
```

Pick one command per working image. `--cache-mib 0` disables the cache and is
the default; the accepted range is 0..256 MiB. Options come before the
format/root arguments and can be combined with `--salvage`, `--device` and
`--utc-offset`.

`ReadCache.Mod` caches full 1/2/4 KiB filesystem blocks: directory, header,
index and file-data blocks. Lookup goes through a hash table, and a
least-recently-used list picks eviction victims. The requested size bounds
cached payload bytes; metadata takes extra space (about 3.1% for 1 KiB blocks,
1.6% for 2 KiB and 0.8% for 4 KiB). Memory is allocated on the first
filesystem-block read. Each open image has its own cache; this module does not
cache temporary staged files.

Every write to the backing store invalidates overlapping cached blocks first,
including partial writes and writes through shared volume plans. Resizing
clears the cache; closing discards it. Only successful complete reads enter
the cache. Keep other programs away from the backing image or device while it
is mounted.

The cache holds completed reads only. Writes still go through the staging,
publication and `fsync` sequence from [writable mounts](#writable-mounts),
including whole-file rewrites and the same interruption risks. Linux also
caches backing-file and device reads; this cache avoids repeated `pread`
calls, though how much it helps physical I/O depends on the workload. Kernel
FUSE file-data caching stays disabled.

### Timestamps

All five profiles store timestamps on disk. The driver decodes them and
exposes the file modification date. Header offsets are relative to the file
header:

| Profile | Timestamp fields |
| --- | --- |
| Ceres | 32-bit `date` at 40, 32-bit `time` at 44 |
| PO13 | One packed 32-bit date/time value named `date` at 44 |
| NatFS | 32-bit `date` at 40, 32-bit `time` at 44 |
| AosFS v1 | 32-bit `date` at 44, 32-bit `time` at 48 |
| AosFS v2 | 32-bit `date` at 140, 32-bit `time` at 144 |

The Oberon clock encodings for Ceres, NatFS and AosFS are
`year*512 + month*32 + day` and `hour*4096 + minute*64 + second`.
NatFS/AosFS years count from 1900. Ceres uses a two-digit year: the driver
interprets 70..99 as 1970..1999 and 00..69 as 2000..2069. PO13 packs a year
relative to 2000, month, day and time into bits 26..31, 22..25,
17..21 and 0..16 respectively; supported years are 2000..2063.

The fields keep local clock values with no timezone. Mounts interpret them as
UTC unless `--utc-offset MINUTES` supplies a fixed offset east of UTC, for
example `--utc-offset 120` for UTC+02:00. Pass the right offset yourself
during daylight-saving time. Reads and writes use the same offset. Gregorian
dates, leap years and clock fields are validated. Invalid or unset timestamps
show as zero (the Unix epoch); the file still loads.

The stored modification time fills `st_mtime`, `st_atime` and `st_ctime`.
Reads leave it alone; there is no separate stored access time. New content and
truncation get the current clock. `touch`/`utimens` set the modification time
at whole-second precision; dates outside the profile range return `EOVERFLOW`.
Read-only access and repair preserve the original timestamp bytes. Use
`cp --preserve=timestamps` to copy dates. `cp -p` also requests Unix
permissions and ownership, which this driver cannot store.

## Source material

The format profiles follow the disk records and constants in these modules:

| Collection | Relevant sources |
| --- | --- |
| [Project-Oberon/Source-Code][historical] | [Ceres V2 `FileDir`][ceres-v2], [Ceres V4 `FileDir`][ceres-v4], their `Files.Mod.txt` modules; Ceres V4 `C3.Kernel.Asm.txt` and `C2.Diskette.Mod.txt` |
| [NativeOberon-2.3.6-Extracted][native] | [`FullInstall_ASCII/FileDir.Mod`][natfs], `Files.Mod`, `Disk.Mod`, `Diskette.Mod` |
| [Oberon-Linux-Revival][olr] | [`Gadgets/Text_Converted/OFSAosFiles.Mod`][olr-aos], [`OFSN2KFiles.Mod`][olr-n2k], [`OFS.Mod`][olr-ofs], `Files.Mod`, `FileDir.Mod` and the rest of the OFS module family |
| [ETH A2/AOS][a2] | [`source/OberonFS.Mod`][a2-natfs], [`OldDiskFS.Mod`][aos-v1], [`DiskFS.Mod`][aos-v2], [`DiskVolumes.Mod`][a2-volumes], `OldDiskVolumes.Mod`, [`PartitionsLib.Mod`][detection], [`SSFS.Mod`][ssfs], [`Build.Tool`][a2-build], [`IsoImages.Mod`][a2-iso] |
| [Wirth's PO13][wirth] | [`FileDir.Mod.txt`][project-fs], [`Kernel.Mod.txt`][project-kernel] |
| [Andreas Pirklbauer's Extended Oberon][extended] | [`Sources/FileDir.Mod`][extended-fs], `Sources/Files.Mod`, [`Sources/Disk.Mod`][extended-disk] |
| [gh055/obdisk][obdisk] | Independent Ceres decoder; [`obdisk.h`][obdisk-header] and [`ob_disk.c`][obdisk-reader]; links to the Bitsavers dump |
| [MEDOS and Emulith archive][emulith] | [MEDOS sources][medos-source]: `DiskSystem.DEF`, `DiskSystem.MOD`, `D140Disk.DEF`, `D140Disk.MOD`, `DiskCheck.MOD`, `DiskPatch.MOD`; [Emulith sources][emulith-source]: `include/img_lil.h`, `Src/img_cde.c`, `Src/io_MD120.c` |

Extended Oberon's `FileDir.Mod` and `Files.Mod` are unchanged since its first
Git commit, `3107792` (2021-06-11). Commit `3678fd2` (2022-08-31) changes the
boot-reserved area from 160 to 192 blocks, without changing the directory or
file-header structures. The bundled `Documentation/S3RISCinstall.tar.gz`
image was also checked: its headers match the PO13 profile.

Revisions inspected on 2026-10-13:

```text
Source-Code:                    cf7f6a6cda1c5e58299726ec578ffde76ce8a6bf
NativeOberon-2.3.6-Extracted:     d0d166706f15829dcdd6cdb7ce5d7ea219a36761
A2/AOS:                         ec4ce23120a0e392b1d3be17ef77d23bafae435c
Oberon-extended:                48e9fb7
```

The repository contains an independent implementation of these layouts.
Check each upstream project's licence before porting source code.

## Module split

The filesystem code is independent of FUSE:

```text
Fuse.Mod             FUSE handlers and mount lifecycle
FuseABI.Mod          Callback marshalling; contains SYSTEM operations and libfuse calls
Host.Mod             OS boundary; contains SYSTEM operations and POSIX file I/O
BlockIO.Mod          Checked image access
ReadCache.Mod        Bounded per-image read-through block cache
DiskBytes.Mod        Byte decoding and encoding
DiskTime.Mod         Oberon clock validation and Unix time conversion
DiskTypes.Mod        Volume and directory-entry types
OberonBTree.Mod      Shared directory/header decoding and file reads
CeresFS.Mod          Ceres layout
NatFS.Mod            Native Oberon 2 KB layout
ProjectFS.Mod        PO13 layout
AosFS.Mod            AosFS v1 and v2 layouts
Formats.Mod          Profile selection
DetectFS.Mod         Boot sectors, MBR partitions and A2 CDs
FileSystem.Mod       Open, find, read and close
FSCheck.Mod          Read-only consistency checks
Diagnostics.Mod      Bounded, structured issue records
AllocationMap.Mod    Allocation ownership and overlap checks
WriteBitmap.Mod      Compact writable allocation map
AllocationCache.Mod  Saved allocation-cache invalidation
FSWrite.Mod          FUSE-independent staged file and directory updates
FSReports.Mod        Diagnostic reports and repair manifests
ReportWriter.Mod     Checked report output
BTreeRebuild.Mod     Balanced directory reconstruction
FSRepair.Mod         Directory repair and verification, in place or in a copy
ImageCreate.Mod      Empty filesystem and container creation
ImageTool.Mod        Standalone inspector, exporter, mkfs and repair
```

`Host.Mod` and `FuseABI.Mod` contain the `SYSTEM` operations at the host and
FUSE boundaries. Filesystem modules decode and encode disk fields byte by
byte. `oberon-image` links the filesystem modules and host adapter; the FUSE
executable adds the libfuse adapter. One executable handles all five layouts.

`BlockSet.Mod` holds bounded sets for directory cycle checks.
`AllocationMap.Mod` tracks block owners, and the checker excludes both
owners of an overlap. `CommandLine.Mod` parses profiles, offsets, salvage
and mount options.

The build uses VOC's OC size model: 32-bit `INTEGER` and 64-bit `LONGINT`.
Disk decoding is independent of host record layout. Index, range, type and
assertion checks stay enabled. The FUSE loop runs in the foreground with
serialized callbacks and read-only access by default.

Detection handles Native/Aos boot headers, MBR partition IDs `4CH` (Aos),
`4FH`/`50H` (Native) and `FFH` (PO13), and A2's El Torito boot image.
The Aos footer takes precedence over an `OBERON`
OEM string. Multiple recognized partitions require an explicit root offset.
Raw Ceres images need an explicit profile; shared magic values alone do not
distinguish Ceres from PO13.

Every read is bounded by the actual image size and the selected volume.
Directory loading checks ordering, occupancy, balanced leaves, cycles and
headers. It is limited to 100,000 files and a tree depth of 32. On-disk
timestamp fields are decoded with explicit calendar and timezone rules.
Capacities, resource safeguards, concurrent clients and timestamp layouts are
in [limits and metadata](#limits-and-metadata).

## Building

Requirements: VOC with its OC runtime, a C compiler, GNU make 4.3 or newer,
`pkg-config` and the libfuse 3 development files. Tests also need Python 3.

```sh
make
make check
make check-images
make check-mount
make check-devices # optional; needs loop-device permissions
```

`make` builds `build/oberon-fuse` and `build/oberon-image`. Generated C, symbol
files, object files and binaries stay under `build/`.

`make check` runs the bridge smoke test and independent synthetic-image tests
for all five layouts, direct/single/double indirection, long offsets, damaged
records, image creation and overwrite guards, salvage and both repair modes.
The repair tests cover multi-level rebuilding, root collapse, empty results,
overlaps, missing blocks, saved-map invalidation, resource limits,
interruption during copying, partial write failures, inode preservation and
symlink/hard-link/lock refusals.
Clock tests check Gregorian validation, century policies, profile ranges and
UTC offsets. Standalone writer tests inject partial writes and sync failures;
device guards reject regular files, aliases, FIFOs and missing paths.
Cache tests compare LRU behaviour against an independent reference model and
exercise hash collisions, 64-bit offsets, cache isolation, failed reads and
partial-write invalidation through shared image records.

`make check-images` checks local preservation images and ZIP CRCs, including
every ZIP archive on the A2 CD. The Ceres regression compares the Bitsavers
dump with its archived extracted files, verifies strict rejection, and compares
all 570 retained files after salvage and repair. Changes in the repaired
Ceres copy are confined to original directory blocks.

Run `make check-mount` separately to mount the fixtures and available
preservation images. It compares every file through the kernel with an
independent Python reader, checks ZIP CRCs, verifies the images are unchanged,
and unmounts them. It reports a skip if FUSE mounting is unavailable.
Writable tests use only disposable images, covering file/directory changes,
allocation reclamation, simultaneous clients, open-file rename/unlink,
full-volume and I/O errors, and timestamp-preserving `cp` roundtrips.
Cached mount tests compare disabled, 1 MiB and 32 MiB caches, file/block reuse,
directory changes and salvage on every layout. Set `OBERON_TEST_CACHE_MIB=1`
when running `make check-mount` to also run the existing preservation, writable
and injected-failure mount tests with caching enabled.

The A2 tests look for `/tmp/A2_Rev-6498_serial-trace.iso` by default; set
`A2_IMAGE` when the copy is elsewhere, for example
`A2_IMAGE=disks/aos/A2_Rev-6498_serial-trace.iso`. Supply the images locally before
running preservation tests.
For Ceres, use `disks/ceres/ceres.dat` and `disks/ceres/ceres_xt2190_files.zip`,
or set `CERES_IMAGE` and `CERES_FILES`. Ceres mount tests cover selected real
records in a derived fixture, the original dump in explicit salvage mode,
and temporary copies repaired in place or into new files, mounted without salvage.

The Makefile looks for VOC's headers and runtime beside its installation.
For a compiler built in its source tree, set `VOC` to the executable in its
installation image:

```sh
make VOC="/path/to/voc/install/bin/voc"
```

For other layouts, set `VOC_HOME` (the directory containing `C/include` and
`C/sym`) and `VOC_RUNTIME` (the path to `libvoc-OC.a`). `CC`, `CPPFLAGS`,
`CFLAGS`, `LDFLAGS` and `LDLIBS` can also be overridden.

Use `make clean` to remove the generated files under `build/`.

## Using the driver and tools

Inspect or export without mounting:

```sh
build/oberon-image info disks/po13/RISC.img
build/oberon-image list disks/no/Oberon0.Dsk
build/oberon-image cat disks/no/Oberon0.Dsk System.zip > System.zip
build/oberon-image read disks/po13/RISC.img Input.rsc 0 64
build/oberon-image check disks/aos/A2_Rev-6498_serial-trace.iso
```

Mount in the foreground; unmount from another terminal:

```sh
mkdir -p mnt
build/oberon-fuse disks/po13/RISC.img mnt
fusermount3 -u mnt
```

Inspection and mounting accept `[--salvage] [FORMAT [ROOT-OFFSET]]` after their normal
arguments. Formats are `project`, `natfs`, `ceres`, `aos1` and `aos2`; the
default is `auto`. `ROOT-OFFSET` is the absolute byte offset of the root
directory (encoded address 29), not the partition start. For raw images the
default root is 1,024 bytes for `project` and `ceres`, and zero for `natfs`,
`aos1` and `aos2`.

### Create an image with `dd`, format it, and mount

These commands create a **new 64 MiB image**, then format that existing file
as a raw NatFS volume. Run them from this project's directory, checking each
command succeeds before continuing:

```sh
dd if=/dev/zero of=new-natfs.img bs=1M count=64 conv=excl status=progress
build/oberon-image mkfs natfs new-natfs.img --in-place
build/oberon-image check new-natfs.img natfs
build/oberon-image list new-natfs.img natfs
mkdir -p mnt
build/oberon-fuse new-natfs.img mnt natfs
```

GNU `dd`'s `conv=excl` refuses an existing output name. Choose a new name,
and keep preservation images out of `of=`. **`mkfs --in-place` erases the
entire selected file**, including old partition tables, boot code, files and
allocation caches. It preserves the file's size and inode, uses the existing
size instead of a size argument, and verifies the empty filesystem afterwards.

The mount runs in the foreground. Unmount from another terminal in the same
directory:

```sh
fusermount3 -u mnt
```

Use any of these profiles for a raw image; create the corresponding filename
with `dd` first:

| Filesystem | Format existing image | Check / mount profile |
| --- | --- | --- |
| PO13 | `build/oberon-image mkfs project new-project.img --in-place` | `project` |
| NatFS / N2KFS | `build/oberon-image mkfs natfs new-natfs.img --in-place` | `natfs` |
| Ceres | `build/oberon-image mkfs ceres new-ceres.dat --in-place` | `ceres` |
| AosFS v1 | `build/oberon-image mkfs aos1 new-aos1.img --in-place` | `aos1` |
| AosFS v2 | `build/oberon-image mkfs aos2 new-aos2.img --in-place` | `aos2` |

For example, check Ceres with `build/oberon-image check new-ceres.dat ceres`
and mount with `build/oberon-fuse new-ceres.dat mnt ceres`. Always specify the
profile for raw images because the formats share markers.

To format the **whole existing file** as a partitioned HDD image, add `hdd`:

```sh
dd if=/dev/zero of=new-aos-hdd.img bs=1M count=128 conv=excl status=progress
build/oberon-image mkfs aos2 new-aos-hdd.img --in-place hdd
build/oberon-image check new-aos-hdd.img
build/oberon-fuse new-aos-hdd.img mnt
```

For a Native Oberon floppy image:

```sh
dd if=/dev/zero of=new-floppy.img bs=512 count=2880 conv=excl status=progress
build/oberon-image mkfs natfs new-floppy.img --in-place floppy
build/oberon-image check new-floppy.img
build/oberon-fuse new-floppy.img mnt
```

HDD and floppy containers are detected automatically. Existing-image `mkfs`
replaces the whole selected image, including its partition table. Not every
layout supports every container:

Mounts remain read-only by default. Add `--rw` to populate a disposable image:

```sh
build/oberon-fuse new-aos-hdd.img mnt --rw
```

From another terminal, copy files into `mnt`, then `fusermount3 -u mnt` before
checking or using the image elsewhere. These filesystems require a bootloader
and system installation before they can boot an Oberon system.

### Writable mounts

```sh
build/oberon-image mkfs aos2 working.img 64
build/oberon-image check working.img aos2
mkdir -p mnt
build/oberon-fuse working.img mnt --rw aos2
```

The daemon stays in the foreground. From a second terminal:

```sh
cp --preserve=timestamps example.txt mnt/Example.Text
cat mnt/Example.Text
mv mnt/Example.Text mnt/Renamed.Text
fusermount3 -u mnt
build/oberon-image check working.img aos2
```

Writable opening takes an exclusive advisory lock and requires a complete,
clean allocation check. `--rw` cannot be combined with `--salvage`. Regular-file
updates reject final-component symlinks and files with multiple hard links.
Select a separate working copy and stop VMs or other programs using the
volume.

Changed files are staged in private, unlinked host temporary files (`TMPDIR`,
or `/tmp` by default). Reads see those staged bytes. Closing/flushing or `fsync`
publishes the entire changed file into spare image blocks; a rename also rewrites
the file so its header name matches. New directory children use spare blocks,
then the fixed root is written last, after syncing the file and children.
Successful publication is synced before returning. Creation, deletion and
rename publish immediately. Unlinked files remain available to existing handles
until their last close; they are not restored to the directory.

Unlink removes the on-disk directory entry immediately, without leaving
libfuse's temporary `.fuse_hidden` entries on disk. Handle-based read/write,
flush and release continue to work. The high-level libfuse path API can still
return `ESTALE`/`ENOENT` for metadata operations such as `fstat` on an already
unlinked or overwritten open file.

The writer rewrites whole changed files and rebuilds and checks the directory.
Large-file edits and many small updates therefore require substantial I/O.
The old file stays allocated during replacement; free space must accommodate
the complete new file and fresh directory children. Sparse host writes become
zero-filled, fully allocated disk files. A full volume can return `ENOSPC` on
truncate, flush, close or `fsync` after a successful staged write. Check the
results of these operations. Failed final-close publication discards the
staged changes and returns an error.

**There is no power-loss atomicity.** The fixed-root write can tear, and
unsynced staged data is lost if the process dies. An uncertain publication I/O
failure stops further access in that mount. Always unmount before unplugging a
device, keep backups, and run the checker after an interruption. Do not use
this writer for irreplaceable or sole-copy data.

### Flash drives and Linux block devices

A raw AosFS v2 volume uses the device directly, without a partition table. It
has the longest names and largest per-file capacity of the supported layouts.
Compatible Oberon/A2 tools and other AosFS decoders can read it. Other
operating systems may offer to reformat an unrecognized volume.

The automated device tests use disposable loop devices. For a physical USB
drive, identify the target by model, serial, size and existing mounts before
running the destructive command below. Unmount all its partitions and stop
every other program using it.

```sh
lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS
```

Replace `/dev/SELECTED_USB_DEVICE` with the verified device node, not a by-id
symlink. **The next command erases the entire selected device, including old
partitions and all data.** Do not run it on a system disk or preservation source.

```sh
sudo build/oberon-image mkfs aos2 /dev/SELECTED_USB_DEVICE --erase-device raw
sudo build/oberon-image check /dev/SELECTED_USB_DEVICE --device aos2
mkdir -p mnt
sudo build/oberon-fuse /dev/SELECTED_USB_DEVICE mnt --device --rw aos2
```

The last command stays in the foreground. When run as root the mount is
root-owned: perform copies from a second root terminal, then unmount with
`sudo umount mnt`.
Alternatively arrange narrowly scoped device permissions for your user and
mount without `sudo`; do not make the device world-writable. After unmounting,
check it again before removal. Later, `--device aos2` mounts the same drive
read-only; `--device --rw aos2` mounts writable, without formatting again.

`--device` accepts only Linux block devices, determines their size with
`BLKGETSIZE64`, rejects final-component symlinks and requests kernel exclusive
device access (`O_EXCL`) as well as an advisory lock. It refuses already
mounted/claimed devices. Device formatting requires `--erase-device`;
`--in-place` accepts regular image files. Device formatting clears the
whole selected node, which can take time on large drives. Formatting only a
selected partition node clears that partition, not its parent disk. Device
repair is not implemented: image the media and repair a separate regular-file
copy instead.

`make check-devices` verifies formatting, checking, mounting and exclusion on
newly allocated disposable loop devices. It skips when loop-device permissions
are unavailable. Physical-device testing requires a separately selected target.

### Create and format in one command

`create` and the size-taking form of `mkfs` create the output file:

```sh
build/oberon-image create project hdd new-project.img 64
build/oberon-image create aos2 hdd new-aos.img 128
build/oberon-image create natfs floppy new-floppy.img
build/oberon-image mkfs natfs new-volume.img 16
build/oberon-image check new-volume.img natfs
```

Sizes are in MiB. HDD creation defaults to 64 MiB and creates one inactive
partition aligned to 1 MiB, with type `FFH` for PO13, `4FH` for NatFS or `4CH`
for AosFS. `floppy` creates a 1,474,560-byte NatFS
image. `raw` and `mkfs` without a container argument use a filesystem without
a partition table.

| Layout | Raw / mkfs | HDD | Floppy |
| --- | --- | --- | --- |
| PO13 | yes | yes | no |
| NatFS | yes | yes | yes |
| Ceres | yes | no | no |
| AosFS v1/v2 | yes | yes | no |

`create` and `mkfs FORMAT OUTPUT SIZE-MiB` create a **new regular file**, refusing
existing outputs. Those images are sparse, with an empty B-tree and zeroed
free space. `mkfs FORMAT IMAGE --in-place [raw|hdd|floppy]` overwrites an
existing regular file; it requires a link count of one and refuses symlinks,
devices and missing files. Explicit in-place formatting writes zeros across
the entire image and may consume its full size on the host filesystem.
Created images are untested in the original Oberon operating systems. An I/O
failure can leave a partially formatted image; the command returns nonzero
in that case.

### Checking, salvage and repair

`check` reads the reachable B-tree and every file header, then validates the
allocations of files whose headers can be decoded. It reports per-file
failures with names, addresses and byte offsets and continues through other
entries. Header blocks are reserved even for invalid entries, so overlaps
with their headers are also reported. Both owners of an overlap are marked
unusable. A structurally invalid directory stops the scan and marks it
incomplete. The image is opened read-only.

The checker looks at directory structure, headers and allocation ownership. It
does not validate payloads, recover deleted files or compare saved allocation
maps. ZIP CRC validation belongs to the test suite. The final allocated block
is still counted when its stored data length is zero. Limits are 1,048,576
distinct allocations, 2,097,152 work steps and 10,000 stored diagnostic
records; extra issues are counted. Hitting an allocation or work limit stops
salvage and repair.

Use read-only salvage to list or mount the files accepted by the full checker:

```sh
build/oberon-image check disks/ceres/ceres.dat ceres
build/oberon-image list disks/ceres/ceres.dat --salvage ceres
build/oberon-fuse disks/ceres/ceres.dat mnt --salvage ceres
```

`check` returns nonzero for an inconsistent filesystem. `--salvage` runs the
full allocation checker, exposes the usable entries and leaves the image
unchanged. Excluded entries disappear from listings and mounts, and reads by
name are refused. Run `check` to see why entries were excluded. Salvage trusts
the reachable directory and the stored lengths; lost entries and damaged
lengths stay unrecovered. Ordinary inspection and mounting default to strict
header and directory validation; the full allocation check is a separate step.

### Copy an original, check it, and repair the copy in place

Keep the preservation original untouched. Make a separate working file with
its own inode. For the Ceres dump:

```sh
dd if=disks/ceres/ceres.dat of=ceres-working.dat bs=1M conv=excl status=progress
build/oberon-image check ceres-working.dat ceres
build/oberon-image repair-plan ceres-working.dat ceres
build/oberon-image repair ceres-working.dat --in-place --drop-invalid ceres
build/oberon-image check ceres-working.dat ceres
mkdir -p mnt
build/oberon-fuse ceres-working.dat mnt ceres
```

The first `check` returns nonzero and reports the original dump's
inconsistencies. Inspect `repair-plan` before accepting `--drop-invalid`.
The second `check` must succeed before mounting; a successfully repaired image
mounts in strict mode. For another filesystem, substitute its profile and
input image. HDD/floppy detection supplies the profile automatically.

`repair IMAGE --in-place --drop-invalid` modifies the existing file,
preserving its inode, size and file data. Make a backup before running it.
A pending `IMAGE.repair.txt` report is written and synced before directory
changes; the result is checked and synced before the report is marked complete.
A clean image's bytes are left unchanged.

**Unmount before formatting or repairing.** The driver and tools use shared
read locks and exclusive update locks. Updates are refused while the image
is mounted by this driver or opened by a cooperating `flock` user. Other
programs, including VMs and `dd`, may not honor those locks: stop them too.
In-place operations reject final-component symlinks, multiply hard-linked
files, devices and missing files.

In-place repair is **not atomic or crash-safe**. An interruption or write
error can leave the working copy inconsistent. The report stays pending or
is marked failed; keep the original and restart from a fresh copy. Existing
reports are not overwritten: archive/rename a prior report before a later
repair run. If preflight rejects the tree, checker limits, or an existing
report, no image bytes are changed.

### Repair directly into a new output image

To preserve the input file and write a separate repaired image:

```sh
build/oberon-image repair-plan disks/ceres/ceres.dat ceres
build/oberon-image repair disks/ceres/ceres.dat new-ceres.dat --drop-invalid ceres
build/oberon-image check new-ceres.dat ceres
build/oberon-fuse new-ceres.dat mnt ceres
```

`repair-plan` opens the image read-only and prints a plan. It returns zero
when the scan is complete, even if the source has file errors. Repair
requires `--drop-invalid`: it excludes all unusable entries, including both
owners of allocation overlaps. Both modes rebuild a balanced B-tree using
only original directory blocks and check the result again with strict decoding
and allocation checks. File headers and data are
not rewritten. New-copy mode first copies the entire source, then repairs
that output; a clean source is copied byte-for-byte.
For NatFS/AosFS, a recognized saved-allocation-map marker in an unclaimed final
block is invalidated after rebuilding; the original system must rebuild its map.

The report is `NEW-IMAGE.repair.txt` (or `IMAGE.repair.txt` for in-place mode),
with the mode, diagnostics, every excluded entry, and a `pending`, `failed`
or `complete` status. New-copy mode refuses existing output files; both modes
refuse existing reports. An error or interruption may leave a partial image
and report; only a zero exit status and a complete report indicate successful
verification. Do not run either mode while another program modifies the image.

Keep the original and its archives: they retain excluded directory entries
and available file data. Repair also leaves data blocks in the copy, but
future writes in Oberon can reuse blocks that the rebuilt directory leaves
unreachable. Use the preserved original for further recovery. Repaired images
have not been boot-tested in the original systems.

[VOC]: https://github.com/vishapoberon/compiler
[historical]: https://github.com/Project-Oberon/Source-Code
[ceres-v2]: https://github.com/Project-Oberon/Source-Code/blob/cf7f6a6cda1c5e58299726ec578ffde76ce8a6bf/CERES%20Oberon%20V2/ASCII/FileDir.Mod.txt
[ceres-v4]: https://github.com/Project-Oberon/Source-Code/blob/cf7f6a6cda1c5e58299726ec578ffde76ce8a6bf/CERES%20Oberon%20V4/ASCII/FileDir.Mod.txt
[native]: https://github.com/schierlm/NativeOberon-2.3.6-Extracted
[native-vms]: https://github.com/asig/native-oberon
[obdisk]: https://github.com/gh055/obdisk
[obdisk-header]: https://github.com/gh055/obdisk/blob/aa79b7981c4de9dc20ac9ebc7d09c7c13dd1206c/src/_obdisk/obdisk.h
[obdisk-reader]: https://github.com/gh055/obdisk/blob/aa79b7981c4de9dc20ac9ebc7d09c7c13dd1206c/src/_obdisk/ob_disk.c
[natfs]: https://github.com/schierlm/NativeOberon-2.3.6-Extracted/blob/d0d166706f15829dcdd6cdb7ce5d7ea219a36761/FullInstall_ASCII/FileDir.Mod
[olr]: https://github.com/schierlm/Oberon-Linux-Revival
[olr-ofs]: https://github.com/schierlm/Oberon-Linux-Revival/blob/cb5792db3f235d5bd7c735c386cf60a3285164b5/Gadgets/Text_Converted/OFS.Mod
[olr-aos]: https://github.com/schierlm/Oberon-Linux-Revival/blob/cb5792db3f235d5bd7c735c386cf60a3285164b5/Gadgets/Text_Converted/OFSAosFiles.Mod
[olr-n2k]: https://github.com/schierlm/Oberon-Linux-Revival/blob/cb5792db3f235d5bd7c735c386cf60a3285164b5/Gadgets/Text_Converted/OFSN2KFiles.Mod
[a2]: https://gitlab.inf.ethz.ch/felixf/oberon
[a2-natfs]: https://gitlab.inf.ethz.ch/felixf/oberon/-/blob/ec4ce23120a0e392b1d3be17ef77d23bafae435c/source/OberonFS.Mod
[aos-v1]: https://gitlab.inf.ethz.ch/felixf/oberon/-/blob/ec4ce23120a0e392b1d3be17ef77d23bafae435c/source/OldDiskFS.Mod
[aos-v2]: https://gitlab.inf.ethz.ch/felixf/oberon/-/blob/ec4ce23120a0e392b1d3be17ef77d23bafae435c/source/DiskFS.Mod
[a2-volumes]: https://gitlab.inf.ethz.ch/felixf/oberon/-/blob/ec4ce23120a0e392b1d3be17ef77d23bafae435c/source/DiskVolumes.Mod
[a2-build]: https://gitlab.inf.ethz.ch/felixf/oberon/-/blob/ec4ce23120a0e392b1d3be17ef77d23bafae435c/source/Build.Tool
[a2-iso]: https://gitlab.inf.ethz.ch/felixf/oberon/-/blob/ec4ce23120a0e392b1d3be17ef77d23bafae435c/source/IsoImages.Mod
[a2-images]: https://sourceforge.net/projects/a2oberon/files/
[a2-6498]: https://sourceforge.net/projects/a2oberon/files/A2_Rev-6498_serial-trace.iso/download
[detection]: https://gitlab.inf.ethz.ch/felixf/oberon/-/blob/ec4ce23120a0e392b1d3be17ef77d23bafae435c/source/PartitionsLib.Mod
[ssfs]: https://gitlab.inf.ethz.ch/felixf/oberon/-/blob/ec4ce23120a0e392b1d3be17ef77d23bafae435c/source/SSFS.Mod
[wirth]: https://people.inf.ethz.ch/wirth/ProjectOberon/
[project-fs]: https://people.inf.ethz.ch/wirth/ProjectOberon/Sources/FileDir.Mod.txt
[project-kernel]: https://people.inf.ethz.ch/wirth/ProjectOberon/Sources/Kernel.Mod.txt
[extended]: https://github.com/andreaspirklbauer/Oberon-extended
[extended-fs]: https://github.com/andreaspirklbauer/Oberon-extended/blob/48e9fb7/Sources/FileDir.Mod
[extended-disk]: https://github.com/andreaspirklbauer/Oberon-extended/blob/48e9fb7/Sources/Disk.Mod
[emulith]: http://pascal.hansotten.com/niklaus-wirth/lilith/emulith/
[medos-source]: http://pascal.hansotten.com/uploads/lilith/medos.zip
[emulith-source]: http://pascal.hansotten.com/uploads/lilith/Emulith_v13.tgz
