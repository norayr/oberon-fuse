#ifndef OBERON_FUSE_BRIDGE_H
#define OBERON_FUSE_BRIDGE_H

#include <stdint.h>

typedef int32_t (*OberonFuse_Stat)(intptr_t path, int64_t handle, int64_t *size, int64_t *modified);
typedef int32_t (*OberonFuse_Transfer)(intptr_t path, intptr_t data, intptr_t size, int64_t offset, int64_t handle);
typedef int32_t (*OberonFuse_Directory)(intptr_t path, intptr_t buffer, intptr_t filler, int64_t offset);
typedef int32_t (*OberonFuse_Action)(intptr_t path, intptr_t other, int32_t operation, int64_t *handle, int64_t argument);
typedef int32_t (*OberonFuse_Space)(int64_t *blocks, int64_t *free, int32_t *block_size, int32_t *name_size);
enum { OberonFuse_Open = 1, OberonFuse_Create, OberonFuse_Truncate,
       OberonFuse_Unlink, OberonFuse_Rename, OberonFuse_Time,
       OberonFuse_Flush, OberonFuse_Release, OberonFuse_Sync };

int32_t OberonFuse_Run(const char *mountpoint, int32_t writable, OberonFuse_Stat stat,
                       OberonFuse_Transfer read, OberonFuse_Transfer write,
                       OberonFuse_Directory directory, OberonFuse_Action action,
                       OberonFuse_Space space);
int32_t OberonFuse_Add(intptr_t buffer, intptr_t filler, const char *name, int64_t cookie);

#endif
