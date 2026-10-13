/* Test-only faults limited to the exact selected backing file, not scratch I/O. */
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

static int selected(int fd)
{
    const char *path = getenv("OBERON_TEST_IMAGE");
    struct stat image, current;
    return path && stat(path, &image) == 0 && fstat(fd, &current) == 0
           && image.st_dev == current.st_dev && image.st_ino == current.st_ino;
}

ssize_t pread(int fd, void *data, size_t size, off_t offset)
{
    static ssize_t (*real_read)(int, void *, size_t, off_t);
    if (!real_read) *(void **)&real_read = dlsym(RTLD_NEXT, "pread64");
    const char *fault = getenv("OBERON_TEST_READ_OFFSET");
    if (fault && selected(fd) && offset >= (off_t)strtoll(fault, NULL, 10)) {
        errno = EIO;
        return -1;
    }
    return real_read(fd, data, size, offset);
}

ssize_t pwrite(int fd, const void *data, size_t size, off_t offset)
{
    static ssize_t (*real_write)(int, const void *, size_t, off_t);
    static int partial;
    if (!real_write) *(void **)&real_write = dlsym(RTLD_NEXT, "pwrite");
    const char *fault = getenv("OBERON_TEST_WRITE_OFFSET");
    const char *limit = getenv("OBERON_TEST_WRITE_LIMIT");
    if (fault && selected(fd) && offset >= (off_t)strtoll(fault, NULL, 10)
        && (!limit || offset < (off_t)strtoll(limit, NULL, 10))) {
        if (!partial && size > 1) { partial = 1; return real_write(fd, data, size / 2, offset); }
        errno = EIO;
        return -1;
    }
    return real_write(fd, data, size, offset);
}

int fsync(int fd)
{
    static int (*real_sync)(int);
    static int calls;
    if (!real_sync) *(void **)&real_sync = dlsym(RTLD_NEXT, "fsync");
    const char *fault = getenv("OBERON_TEST_SYNC_CALL");
    if (fault && selected(fd) && ++calls >= atoi(fault)) { errno = EIO; return -1; }
    return real_sync(fd);
}
