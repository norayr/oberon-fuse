#include "HostBridge.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

_Static_assert(sizeof(off_t) == 8, "64-bit file offsets required");

static int32_t checked_open(int fd, int writable)
{
    if (fd < 0) return -errno;
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int error = errno;
        close(fd);
        return -error;
    }
    /* A hard-linked "copy" could still be the preservation original. */
    if (!S_ISREG(st.st_mode) || (writable && st.st_nlink != 1)) {
        close(fd);
        return -EINVAL;
    }
    if (flock(fd, (writable ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0) {
        int error = errno;
        close(fd);
        return -error;
    }
    return fd;
}

int32_t OberonHost_Open(const char *path)
{
    /* Nonblocking open lets us reject FIFOs without waiting for a writer. */
    return checked_open(open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC), 0);
}

int32_t OberonHost_OpenUpdate(const char *path)
{
    /* Never create, truncate or follow a final-component symlink. */
    return checked_open(open(path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC), 1);
}

int32_t OberonHost_Create(const char *path, int64_t size)
{
    if (size <= 0) return -EINVAL;
    /* O_EXCL also refuses symlinks and existing device nodes. */
    int fd = checked_open(open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0666), 1);
    if (fd < 0) return fd;
    if (ftruncate(fd, (off_t)size) != 0) {
        int error = errno;
        close(fd);
        /* Keep the partial file: another process could have renamed path. */
        return -error;
    }
    return fd;
}

int64_t OberonHost_Size(int32_t fd)
{
    struct stat st;
    if (fstat(fd, &st) != 0) return -errno;
    return st.st_size;
}

int32_t OberonHost_Read(int32_t fd, int64_t offset, void *data, int32_t count)
{
    unsigned char *p = data;
    while (count > 0) {
        ssize_t n = pread(fd, p, (size_t)count, (off_t)offset);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -errno;
        }
        if (n == 0) return -EIO;
        p += n;
        offset += n;
        count -= (int32_t)n;
    }
    return 0;
}

int32_t OberonHost_Write(int32_t fd, int64_t offset, const void *data, int32_t count)
{
    const unsigned char *p = data;
    while (count > 0) {
        ssize_t n = pwrite(fd, p, (size_t)count, (off_t)offset);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -errno;
        }
        if (n == 0) return -EIO;
        p += n;
        offset += n;
        count -= (int32_t)n;
    }
    return 0;
}

int32_t OberonHost_Close(int32_t fd, int32_t sync)
{
    int error = 0;
    if (sync && fsync(fd) != 0) error = errno;
    if (close(fd) != 0 && !error) error = errno;
    return -error;
}

int32_t OberonHost_Sync(int32_t fd)
{
    return fsync(fd) == 0 ? 0 : -errno;
}

int32_t OberonHost_Output(const void *data, int32_t count)
{
    const unsigned char *p = data;
    while (count > 0) {
        ssize_t n = write(STDOUT_FILENO, p, (size_t)count);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -errno;
        }
        if (n == 0) return -EIO;
        p += n;
        count -= (int32_t)n;
    }
    return 0;
}

int32_t OberonHost_CopyString(intptr_t source, char *dest, int32_t capacity)
{
    if (!source || capacity <= 0) return -EINVAL;
    const char *p = (const char *)source;
    size_t n = strnlen(p, (size_t)capacity);
    if (n == (size_t)capacity) return -ENAMETOOLONG;
    memcpy(dest, p, n + 1);
    return 0;
}

void OberonHost_Error(const char *message) { fprintf(stderr, "%s\n", message); }
void OberonHost_Report(const char *message, int32_t error)
{
    fprintf(stderr, "%s: %s (%d)\n", message, strerror(error < 0 ? -error : error), error);
}
void OberonHost_Exit(int32_t status) { exit(status); }
