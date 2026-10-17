#!/bin/sh
#
# Download and check the Oberon disk images used by this project.
# Files that already carry their expected SHA-256 are left alone,
# so the script can be re-run at any time.
#
# Requires curl, sha256sum and unzip.
#
set -eu
cd "$(dirname "$0")"

for tool in curl sha256sum unzip; do
    if ! command -v "$tool" >/dev/null; then
        printf '%s is required\n' "$tool" >&2
        exit 1
    fi
done

status() {
    printf '%-8s %s\n' "$1" "$2"
}

# ok SHA256 FILE
ok() {
    [ -f "$2" ] && printf '%s  %s\n' "$1" "$2" | sha256sum --check --quiet -
}

# settle SHA256 DESTINATION: check DESTINATION.part, then move it into place
settle() {
    if ok "$1" "$2.part"; then
        mv "$2.part" "$2"
    else
        rm -f "$2.part"
        printf 'checksum mismatch for %s\n' "$2" >&2
        exit 1
    fi
}

# download URL DESTINATION: a failed transfer leaves no partial file.
# www.bitsavers.org rejects requests without a common browser user agent,
# while SourceForge rejects browser ones.
download() {
    url=$1
    dest=$2
    set -- --fail --location --retry 3 --retry-delay 2 --silent --show-error
    case "$url" in
        *bitsavers.org*) set -- "$@" --user-agent 'Mozilla/5.0 (X11; Linux x86_64)' ;;
    esac
    if curl "$@" --output "$dest" "$url"; then
        return
    fi
    rm -f "$dest"
    exit 1
}

# want SHA256 DESTINATION URL: download unless the file is already correct
want() {
    if ok "$1" "$2"; then
        status ok "$2"
        return
    fi
    status download "$3"
    download "$3" "$2.part"
    settle "$1" "$2"
}

# fetch URL ARCHIVE: download an archive whose own checksum is not known
fetch() {
    if [ -f "$2" ]; then
        return
    fi
    status download "$1"
    download "$1" "$2.part"
    mv "$2.part" "$2"
}

# unpack SHA256 ARCHIVE MEMBER DESTINATION
unpack() {
    if ok "$1" "$4"; then
        status ok "$4"
        return
    fi
    status unpack "$4"
    unzip -p "$2" "$3" >"$4.part"
    settle "$1" "$4"
}

mkdir -p po13 no ceres aos

# Project Oberon 2013: the official SD-card image, one file in RISCimg.zip.
if ok 92382fea824cf8ba1662ea2b8704289d121acab58b70fc4afbe012c79fca197d po13/RISC.img; then
    status ok po13/RISC.img
else
    fetch 'https://www.projectoberon.net/zip/RISCimg.zip' po13/RISCimg.zip
    unpack 92382fea824cf8ba1662ea2b8704289d121acab58b70fc4afbe012c79fca197d po13/RISCimg.zip RISC.img po13/RISC.img
fi

# Native Oberon 1.44 MB installers, from SourceForge.
want b58f5a7a01121749c83f15e2af02e4f3fc90e63ac3c04ec61cce1aa76b84fc4c no/Oberon0.Dsk \
    'https://downloads.sourceforge.net/project/nativeoberon/nativeoberon/Oberon0%20boot%20disk/Oberon0.Dsk'
want 2fc85d6cba64aeda97773f06e2bc7d22926970d3387151e24b5e312873c53801 no/OberonCF0.Dsk \
    'https://downloads.sourceforge.net/project/nativeoberon/nativeoberon/Oberon0%20boot%20disk/OberonCF0.Dsk'

# Native Oberon QEMU hard disks, pinned to commit d43ce6e in asig/native-oberon.
want 65f21c27cd62ceffab303d7266606f4db3c22e83be462f8a70a0f0ea4f8c60d1 no/NativeOberon-2.3.6.img \
    'https://raw.githubusercontent.com/asig/native-oberon/d43ce6e516fee6f3818d20f56abd1e1e6dbd5e9a/2.3.6/Native%20Oberon%202.3.6.img'
want 40135a8f941e70268f3cc0ab02c04ae4957a6fb4756acb2b2756298ff0458c8c no/NativeOberon-2003-01-05.img \
    'https://raw.githubusercontent.com/asig/native-oberon/d43ce6e516fee6f3818d20f56abd1e1e6dbd5e9a/20030105/Native%20Oberon%202003-01-05.img'

# Ceres: the Bitsavers dump, and its extracted files.
if ok 41271eaf358717563f29354bd1991c28c2594760fda8797c85d5f4979f2ad9b4 ceres/ceres.dat; then
    status ok ceres/ceres.dat
else
    fetch 'https://www.bitsavers.org/bits/ETH/Ceres/ceres_xt2190.zip' ceres/ceres_xt2190.zip
    unpack 41271eaf358717563f29354bd1991c28c2594760fda8797c85d5f4979f2ad9b4 ceres/ceres_xt2190.zip ceres_xt2190/ceres.dat ceres/ceres.dat
fi
want d8c59b4c0d47ed3343a91194bc97db9bf0d141c103ea9a31d11490a18ec7e713 ceres/ceres_xt2190_files.zip \
    'https://www.bitsavers.org/bits/ETH/Ceres/ceres_xt2190_files.zip'

# A2 revision 6498 CD, from SourceForge.
want 624ca75b5af7e67a99500159d314b1b8e282873bc6d43604425a0942bfe3eb6c aos/A2_Rev-6498_serial-trace.iso \
    'https://downloads.sourceforge.net/project/a2oberon/A2_Rev-6498_serial-trace.iso'

status done 'all images are present and checked'
