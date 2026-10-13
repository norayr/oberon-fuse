#ifndef OBERON_HOST_BRIDGE_H
#define OBERON_HOST_BRIDGE_H

#include <stdint.h>

int32_t OberonHost_Open(const char *path);
int32_t OberonHost_OpenUpdate(const char *path);
int32_t OberonHost_Create(const char *path, int64_t size);
int64_t OberonHost_Size(int32_t fd);
int32_t OberonHost_Read(int32_t fd, int64_t offset, void *data, int32_t count);
int32_t OberonHost_Write(int32_t fd, int64_t offset, const void *data, int32_t count);
int32_t OberonHost_Close(int32_t fd, int32_t sync);
int32_t OberonHost_Sync(int32_t fd);
int32_t OberonHost_Output(const void *data, int32_t count);
int32_t OberonHost_CopyString(intptr_t source, char *dest, int32_t capacity);
void OberonHost_Error(const char *message);
void OberonHost_Report(const char *message, int32_t error);
void OberonHost_Exit(int32_t status);

#endif
