#define FUSE_USE_VERSION 31
#include "FuseProbeBridge.h"
#include <time.h>
#include <fuse.h>
#include <string.h>

_Static_assert(sizeof(off_t) == 8, "FUSE requires 64-bit file offsets");

/* The smoke test has one instance and runs on the calling thread. */
static OberonFuseProbe_Read callback;

static int read_probe(const char *path, char *buffer, size_t size,
                      off_t offset, struct fuse_file_info *info)
{
    (void)info;
    return callback((intptr_t)path, (intptr_t)buffer,
                    (intptr_t)size, (int64_t)offset);
}

int32_t OberonFuseProbe_Run(OberonFuseProbe_Read read_callback)
{
    struct fuse_operations operations = { .read = read_probe };
    char *argv[] = { "FuseProbe", NULL };
    struct fuse_args args = FUSE_ARGS_INIT(1, argv);
    struct fuse_file_info info = {0};
    char buffer[32] = {0};

    callback = read_callback;
    struct fuse *instance = fuse_new(&args, &operations, sizeof(operations), NULL);
    if (!instance) {
        fuse_opt_free_args(&args);
        callback = NULL;
        return 1;
    }

    /* Without a mount there is no kernel request context. Call the registered
       callback directly, rather than using the stacking-only fuse_fs_read. */
    int count = operations.read("/probe", buffer, sizeof(buffer), 0, &info);
    int eof = operations.read("/probe", buffer, sizeof(buffer),
                               INT64_C(4294967296), &info);
    int short_buffer = operations.read("/probe", buffer, 1, 0, &info);
    int ok = count == 11 && eof == 0 && short_buffer == -EINVAL &&
             memcmp(buffer, "VOC-FUSE OK", 11) == 0;

    fuse_destroy(instance);
    fuse_opt_free_args(&args);
    callback = NULL;
    return ok ? 0 : 2;
}
