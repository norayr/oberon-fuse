#ifndef OBERON_FUSE_PROBE_BRIDGE_H
#define OBERON_FUSE_PROBE_BRIDGE_H

#include <errno.h>
#include <stdint.h>

typedef int32_t (*OberonFuseProbe_Read)(intptr_t path, intptr_t buffer,
                                       intptr_t size, int64_t offset);

int32_t OberonFuseProbe_Run(OberonFuseProbe_Read read_callback);

#endif
