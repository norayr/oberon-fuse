#define FUSE_USE_VERSION 31
#include "FuseBridge.h"
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <fuse.h>
#include <string.h>
#include <unistd.h>

_Static_assert(sizeof(off_t) == 8, "64-bit FUSE offsets required");

static OberonFuse_Stat stat_callback;
static OberonFuse_Read read_callback;
static OberonFuse_Directory directory_callback;

static int image_getattr(const char *path, struct stat *st, struct fuse_file_info *info)
{
    (void)info;
    int64_t size = 0;
    int kind = stat_callback((intptr_t)path, &size);
    if (kind < 0) return kind;
    memset(st, 0, sizeof(*st));
    st->st_uid = getuid();
    st->st_gid = getgid();
    st->st_mode = kind == 1 ? S_IFDIR | 0555 : S_IFREG | 0444;
    st->st_nlink = kind == 1 ? 2 : 1;
    st->st_size = size;
    st->st_blksize = 4096;
    st->st_blocks = (size + 511) / 512;
    return 0;
}

static int image_open(const char *path, struct fuse_file_info *info)
{
    int64_t size;
    int kind = stat_callback((intptr_t)path, &size);
    if (kind < 0) return kind;
    if (kind == 1) return -EISDIR;
    if ((info->flags & O_ACCMODE) != O_RDONLY || (info->flags & O_TRUNC)) return -EROFS;
    return 0;
}

static int image_read(const char *path, char *data, size_t size,
                       off_t offset, struct fuse_file_info *info)
{
    (void)info;
    if (size > INT32_MAX) return -EINVAL;
    return read_callback((intptr_t)path, (intptr_t)data, (intptr_t)size, offset);
}

static int image_readdir(const char *path, void *buffer, fuse_fill_dir_t filler,
                         off_t offset, struct fuse_file_info *info,
                         enum fuse_readdir_flags flags)
{
    (void)info;
    (void)flags;
    return directory_callback((intptr_t)path, (intptr_t)buffer, (intptr_t)filler, offset);
}

int32_t OberonFuse_Add(intptr_t buffer, intptr_t filler, const char *name, int64_t cookie)
{
    return ((fuse_fill_dir_t)filler)((void *)buffer, name, NULL, cookie, 0) == 0;
}

int32_t OberonFuse_Run(const char *mountpoint, OberonFuse_Stat stat,
                       OberonFuse_Read read, OberonFuse_Directory directory)
{
    const struct fuse_operations operations = {
        .getattr = image_getattr, .open = image_open,
        .read = image_read, .readdir = image_readdir
    };
    char *argv[] = { "oberon-fuse", "-f", "-s", "-o", "ro,default_permissions",
                     (char *)mountpoint, NULL };
    stat_callback = stat;
    read_callback = read;
    directory_callback = directory;
    int result = fuse_main(6, argv, &operations, NULL);
    stat_callback = NULL;
    read_callback = NULL;
    directory_callback = NULL;
    return result;
}
