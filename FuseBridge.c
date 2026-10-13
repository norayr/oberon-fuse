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
static OberonFuse_Transfer read_callback, write_callback;
static OberonFuse_Directory directory_callback;
static OberonFuse_Action action_callback;
static OberonFuse_Space space_callback;
static int writable_mount;

static int action(const char *path, const char *other, int operation,
                  struct fuse_file_info *info, int64_t argument)
{
    int64_t handle = info ? (int64_t)info->fh : 0;
    int result = action_callback((intptr_t)path, (intptr_t)other, operation, &handle, argument);
    if (!result && info) info->fh = (uint64_t)handle;
    return result;
}

static void *image_init(struct fuse_conn_info *connection, struct fuse_config *config)
{
    (void)connection;
    config->entry_timeout = config->negative_timeout = config->attr_timeout = 0;
    /* Flat mutable names and shared staged data: no kernel data cache. */
    config->use_ino = 0;
    /* Handles implement open-unlink themselves; do not persist .fuse_hidden names. */
    config->hard_remove = 1;
    config->nullpath_ok = 1;
    return NULL;
}

static int image_getattr(const char *path, struct stat *st, struct fuse_file_info *info)
{
    int64_t size = 0, modified = 0;
    int kind = stat_callback((intptr_t)path, info ? (int64_t)info->fh : 0, &size, &modified);
    if (kind < 0) return kind;
    memset(st, 0, sizeof(*st));
    st->st_uid = getuid();
    st->st_gid = getgid();
    st->st_mode = kind == 1 ? S_IFDIR | (writable_mount ? 0755 : 0555)
                           : S_IFREG | (writable_mount ? 0644 : 0444);
    st->st_nlink = kind == 1 ? 2 : kind == 2 ? 0 : 1;
    st->st_size = size;
    st->st_blksize = 4096;
    st->st_blocks = (size + 511) / 512;
    /* Oberon stores one modification clock, not separate POSIX clocks. */
    st->st_atime = st->st_mtime = st->st_ctime = (time_t)modified;
    return 0;
}

static int open_flags(const struct fuse_file_info *info)
{
    return ((info->flags & O_ACCMODE) != O_RDONLY ? 1 : 0)
           | (info->flags & O_TRUNC ? 2 : 0) | (info->flags & O_APPEND ? 4 : 0);
}

static int image_open(const char *path, struct fuse_file_info *info)
{
    int result = action(path, NULL, OberonFuse_Open, info, open_flags(info));
    if (!result) info->direct_io = 1;
    return result;
}

static int image_create(const char *path, mode_t mode, struct fuse_file_info *info)
{
    (void)mode; /* This format has no Unix mode bits. */
    int result = action(path, NULL, OberonFuse_Create, info, open_flags(info));
    if (!result) info->direct_io = 1;
    return result;
}

static int image_read(const char *path, char *data, size_t size,
                      off_t offset, struct fuse_file_info *info)
{
    if (size > INT32_MAX) return -EINVAL;
    return read_callback((intptr_t)path, (intptr_t)data, (intptr_t)size, offset, (int64_t)info->fh);
}

static int image_write(const char *path, const char *data, size_t size,
                       off_t offset, struct fuse_file_info *info)
{
    if (!writable_mount) return -EROFS;
    if (size > INT32_MAX) return -EINVAL;
    return write_callback((intptr_t)path, (intptr_t)data, (intptr_t)size, offset, (int64_t)info->fh);
}

static int image_truncate(const char *path, off_t size, struct fuse_file_info *info)
{ return action(path, NULL, OberonFuse_Truncate, info, size); }

static int image_unlink(const char *path)
{ return action(path, NULL, OberonFuse_Unlink, NULL, 0); }

static int image_rename(const char *path, const char *other, unsigned flags)
{
    /* Only ordinary POSIX replacement; no exchange or whiteout. */
    if (flags) return -EINVAL;
    return action(path, other, OberonFuse_Rename, NULL, 0);
}

static int image_utimens(const char *path, const struct timespec times[2], struct fuse_file_info *info)
{
    if (!writable_mount) return -EROFS;
    if (times && times[1].tv_nsec == UTIME_OMIT) return 0;
    int64_t modified = (!times || times[1].tv_nsec == UTIME_NOW)
                       ? (int64_t)time(NULL) : (int64_t)times[1].tv_sec;
    return action(path, NULL, OberonFuse_Time, info, modified);
}

static int image_flush(const char *path, struct fuse_file_info *info)
{ return action(path, NULL, OberonFuse_Flush, info, 0); }

static int image_release(const char *path, struct fuse_file_info *info)
{ return action(path, NULL, OberonFuse_Release, info, 0); }

static int image_fsync(const char *path, int data_only, struct fuse_file_info *info)
{
    (void)data_only;
    return action(path, NULL, OberonFuse_Flush, info, 0);
}

static int image_fsyncdir(const char *path, int data_only, struct fuse_file_info *info)
{
    (void)data_only;
    (void)info;
    return action(path, NULL, OberonFuse_Sync, NULL, 0);
}

static int image_statfs(const char *path, struct statvfs *st)
{
    (void)path;
    int64_t blocks, free;
    int32_t block_size, name_size;
    int result = space_callback(&blocks, &free, &block_size, &name_size);
    if (result) return result;
    memset(st, 0, sizeof(*st));
    st->f_bsize = st->f_frsize = (unsigned long)block_size;
    st->f_blocks = (fsblkcnt_t)blocks;
    st->f_bfree = st->f_bavail = (fsblkcnt_t)free;
    st->f_namemax = (unsigned long)name_size;
    return 0;
}

static int image_readdir(const char *path, void *buffer, fuse_fill_dir_t filler,
                         off_t offset, struct fuse_file_info *info, enum fuse_readdir_flags flags)
{
    (void)info;
    (void)flags;
    return directory_callback((intptr_t)path, (intptr_t)buffer, (intptr_t)filler, offset);
}

int32_t OberonFuse_Add(intptr_t buffer, intptr_t filler, const char *name, int64_t cookie)
{ return ((fuse_fill_dir_t)filler)((void *)buffer, name, NULL, cookie, 0) == 0; }

int32_t OberonFuse_Run(const char *mountpoint, int32_t writable, OberonFuse_Stat stat,
                       OberonFuse_Transfer read, OberonFuse_Transfer write,
                       OberonFuse_Directory directory, OberonFuse_Action operation,
                       OberonFuse_Space space)
{
    const struct fuse_operations operations = {
        .init = image_init, .getattr = image_getattr, .open = image_open,
        .read = image_read, .readdir = image_readdir, .create = image_create,
        .write = image_write, .truncate = image_truncate, .unlink = image_unlink,
        .rename = image_rename, .utimens = image_utimens, .flush = image_flush,
        .release = image_release, .fsync = image_fsync, .fsyncdir = image_fsyncdir,
        .statfs = image_statfs
    };
    char *argv[] = { "oberon-fuse", "-f", "-s", "-o",
                    writable ? "rw,default_permissions" : "ro,default_permissions",
                    (char *)mountpoint, NULL };
    writable_mount = writable;
    stat_callback = stat;
    read_callback = read;
    write_callback = write;
    directory_callback = directory;
    action_callback = operation;
    space_callback = space;
    int result = fuse_main(6, argv, &operations, NULL);
    stat_callback = NULL;
    read_callback = write_callback = NULL;
    directory_callback = NULL;
    action_callback = NULL;
    space_callback = NULL;
    return result;
}
