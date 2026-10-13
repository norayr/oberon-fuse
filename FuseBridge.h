#ifndef OBERON_FUSE_BRIDGE_H
#define OBERON_FUSE_BRIDGE_H

#include <stdint.h>

typedef int32_t (*OberonFuse_Stat)(intptr_t path, int64_t *size);
typedef int32_t (*OberonFuse_Read)(intptr_t path, intptr_t data, intptr_t size, int64_t offset);
typedef int32_t (*OberonFuse_Directory)(intptr_t path, intptr_t buffer, intptr_t filler, int64_t offset);

int32_t OberonFuse_Run(const char *mountpoint, OberonFuse_Stat stat,
                       OberonFuse_Read read, OberonFuse_Directory directory);
int32_t OberonFuse_Add(intptr_t buffer, intptr_t filler, const char *name, int64_t cookie);

#endif
