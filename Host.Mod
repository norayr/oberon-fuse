MODULE Host;
  (* The only OS-facing module. Addresses never escape into disk decoders. *)
  IMPORT SYSTEM;

  (* A code body is stored with a one-byte length: keep every quoted string
     under 256 characters and compose longer operations from fragments. *)
  PROCEDURE -A0Errno  '#include <errno.h>';
  PROCEDURE -A1Fcntl  '#include <fcntl.h>';
  PROCEDURE -A2Linux  '#include <linux/fs.h>';
  PROCEDURE -A3Stdint '#include <stdint.h>';
  PROCEDURE -A4Stdio  '#include <stdio.h>';
  PROCEDURE -A5Stdlib '#include <stdlib.h>';
  PROCEDURE -A6String '#include <string.h>';
  PROCEDURE -A7File   '#include <sys/file.h>';
  PROCEDURE -A8Stat   '#include <sys/stat.h>';
  PROCEDURE -A9Ioctl  '#include <sys/ioctl.h>';
  PROCEDURE -B0Time   '#include <time.h>';
  PROCEDURE -B1Unix   '#include <unistd.h>';
  PROCEDURE -ZOffGuard 'extern char oberon_host_off_t_guard[sizeof(off_t) == 8 ? 1 : -1];';

  (* Identity and locking checks for the open entry points. Each takes the
     descriptor as an lvalue and replaces it with -errno when it rejects it. *)
  PROCEDURE -CheckFile(f: SYSTEM.INT32; w: INTEGER)
    '({ struct stat s_; int e_ = 0; if (fstat(f, &s_) != 0) e_ = errno; if (!e_ && (!S_ISREG(s_.st_mode) || (w && s_.st_nlink != 1))) e_ = EINVAL; if (e_) { close(f); f = -e_; } })';
  PROCEDURE -CheckBlock(f: SYSTEM.INT32)
    '({ struct stat s_; int e_ = 0; if (fstat(f, &s_) != 0) e_ = errno; if (!e_ && !S_ISBLK(s_.st_mode)) e_ = EINVAL; if (e_) { close(f); f = -e_; } })';
  PROCEDURE -CheckLock(f: SYSTEM.INT32; w: INTEGER)
    '({ if (flock(f, (w ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0) { int e_ = errno; close(f); f = -e_; } })';

  PROCEDURE -Open0(path: SYSTEM.ADDRESS): SYSTEM.INT32
    '({ int f_ = open((const char *)path, O_RDONLY | O_NONBLOCK | O_CLOEXEC); if (f_ < 0) f_ = -errno; else { Host_CheckFile(f_, 0); Host_CheckLock(f_, 0); } f_; })';
  PROCEDURE -Update0(path: SYSTEM.ADDRESS): SYSTEM.INT32
    '({ int f_ = open((const char *)path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC); if (f_ < 0) f_ = -errno; else { Host_CheckFile(f_, 1); Host_CheckLock(f_, 1); } f_; })';
  PROCEDURE -Device0(path: SYSTEM.ADDRESS; writable: SYSTEM.INT32): SYSTEM.INT32
    '({ int f_ = open((const char *)path, (writable ? O_RDWR : O_RDONLY) | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC); if (f_ < 0) f_ = -errno; else { Host_CheckBlock(f_); Host_CheckLock(f_, writable); } f_; })';
  PROCEDURE -OpenNew(path: SYSTEM.ADDRESS): SYSTEM.INT32
    '({ int f_ = open((const char *)path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0666); if (f_ < 0) f_ = -errno; else { Host_CheckFile(f_, 1); Host_CheckLock(f_, 1); } f_; })';

  PROCEDURE -ScratchName(p: SYSTEM.ADDRESS): SYSTEM.INT32
    '({ const char *d_ = getenv("TMPDIR"); int n_; if (!d_ || !*d_) d_ = "/tmp"; n_ = snprintf((char *)p, 4096, "%s/oberon-fuse-XXXXXX", d_); (n_ < 0 || (size_t)n_ >= 4096) ? -ENAMETOOLONG : n_; })';
  PROCEDURE -ScratchMake(p: SYSTEM.ADDRESS; f: SYSTEM.INT32)
    'f = mkstemp((char *)p); if (f < 0) f = -errno';
  PROCEDURE -ScratchUnlink(p: SYSTEM.ADDRESS; f: SYSTEM.INT32)
    'if (f >= 0) { if (unlink((char *)p) != 0) { int e_ = errno; close(f); f = -e_; } else if (fcntl(f, F_SETFD, FD_CLOEXEC) != 0) { int e_ = errno; close(f); f = -e_; } }';
  PROCEDURE -Scratch0(): SYSTEM.INT32
    '({ char p_[4096]; int n_ = Host_ScratchName(p_), f_; if (n_ < 0) f_ = n_; else { Host_ScratchMake(p_, f_); Host_ScratchUnlink(p_, f_); } f_; })';

  PROCEDURE -Resize0(fd: SYSTEM.INT32; size: SYSTEM.INT64): SYSTEM.INT32
    '({ int64_t s_ = size; s_ < 0 ? -EINVAL : (ftruncate(fd, (off_t)s_) == 0 ? 0 : -errno); })';
  PROCEDURE -Now0(): SYSTEM.INT64
    '(INT64)time(NULL)';
  PROCEDURE -Create0(path: SYSTEM.ADDRESS; size: SYSTEM.INT64): SYSTEM.INT32
    '({ int64_t n_ = size; int f_ = n_ <= 0 ? -EINVAL : Host_OpenNew(path); if (n_ > 0 && f_ >= 0 && ftruncate(f_, (off_t)n_) != 0) { int e_ = errno; close(f_); f_ = -e_; } f_; })';
  PROCEDURE -BlockSize(fd: SYSTEM.INT32): SYSTEM.INT64
    '({ uint64_t z_; ioctl(fd, BLKGETSIZE64, &z_) != 0 ? -errno : (z_ > INT64_MAX ? -EOVERFLOW : (INT64)z_); })';
  PROCEDURE -Size0(fd: SYSTEM.INT32): SYSTEM.INT64
    '({ struct stat s_; fstat(fd, &s_) != 0 ? -errno : (S_ISBLK(s_.st_mode) ? Host_BlockSize(fd) : (INT64)s_.st_size); })';

  (* One pread/pwrite/write at the current position; EINTR retries and
     short-transfer accounting stay in the Oberon loops below. *)
  PROCEDURE -ReadSome(fd: SYSTEM.INT32; position: LONGINT; address: SYSTEM.ADDRESS; done: LONGINT; count: INTEGER): LONGINT
    'pread(fd, (void *)((ADDRESS)address + done), count - done, position)';
  PROCEDURE -WriteSome(fd: SYSTEM.INT32; position: LONGINT; address: SYSTEM.ADDRESS; done: LONGINT; count: INTEGER): LONGINT
    'pwrite(fd, (const void *)((ADDRESS)address + done), count - done, position)';
  PROCEDURE -WriteStd(address: SYSTEM.ADDRESS; done: LONGINT; count: INTEGER): LONGINT
    'write(STDOUT_FILENO, (const void *)((ADDRESS)address + done), count - done)';
  PROCEDURE -Interrupted(): BOOLEAN
    '(errno == EINTR)';
  PROCEDURE -Errno(): INTEGER
    'errno';

  PROCEDURE -Close0(fd: SYSTEM.INT32; sync: SYSTEM.INT32): SYSTEM.INT32
    '({ int e_ = 0; if (sync && fsync(fd) != 0) e_ = errno; if (close(fd) != 0 && !e_) e_ = errno; -e_; })';
  PROCEDURE -Sync0(fd: SYSTEM.INT32): SYSTEM.INT32
    'fsync(fd) == 0 ? 0 : -errno';
  PROCEDURE -Copy0(source: SYSTEM.ADDRESS; dest: SYSTEM.ADDRESS; capacity: SYSTEM.INT32): SYSTEM.INT32
    '({ const char *s_ = (const char *)source; int r_; if (!s_ || capacity <= 0) r_ = -EINVAL; else { size_t n_ = strnlen(s_, (size_t)capacity); if (n_ == (size_t)capacity) r_ = -ENAMETOOLONG; else { memcpy((char *)dest, s_, n_ + 1); r_ = 0; } } r_; })';
  PROCEDURE -Error0(message: SYSTEM.ADDRESS)
    'fprintf(stderr, "%s\n", (const char *)message)';
  PROCEDURE -Report0(message: SYSTEM.ADDRESS; error: SYSTEM.INT32)
    'fprintf(stderr, "%s: %s (%d)\n", (const char *)message, strerror(error < 0 ? -error : error), error)';
  PROCEDURE -Exit0(status: SYSTEM.INT32)
    'exit(status)';

  PROCEDURE Open*(path: ARRAY OF CHAR): LONGINT;
  BEGIN RETURN Open0(SYSTEM.ADR(path)) END Open;

  PROCEDURE OpenUpdate*(path: ARRAY OF CHAR): LONGINT;
  BEGIN RETURN Update0(SYSTEM.ADR(path)) END OpenUpdate;

  PROCEDURE OpenDevice*(path: ARRAY OF CHAR; writable: BOOLEAN): LONGINT;
    VAR flag: INTEGER;
  BEGIN IF writable THEN flag := 1 ELSE flag := 0 END; RETURN Device0(SYSTEM.ADR(path), flag) END OpenDevice;

  PROCEDURE Scratch*(): LONGINT;
  BEGIN RETURN Scratch0() END Scratch;

  PROCEDURE Resize*(fd, size: LONGINT): INTEGER;
  BEGIN RETURN SHORT(Resize0(SHORT(fd), size)) END Resize;

  PROCEDURE Now*(): LONGINT;
  BEGIN RETURN Now0() END Now;

  PROCEDURE Create*(path: ARRAY OF CHAR; size: LONGINT): LONGINT;
  BEGIN RETURN Create0(SYSTEM.ADR(path), size) END Create;

  PROCEDURE Size*(fd: LONGINT): LONGINT;
  BEGIN RETURN Size0(SHORT(fd)) END Size;

  PROCEDURE Read*(fd, offset: LONGINT; VAR data: ARRAY OF CHAR; count: INTEGER): INTEGER;
    VAR done, n: LONGINT;
  BEGIN
    IF (offset < 0) OR (count < 0) OR (count > LEN(data)) THEN RETURN -22 END;
    done := 0;
    WHILE done < count DO
      n := ReadSome(SHORT(fd), offset + done, SYSTEM.ADR(data), done, count);
      IF n < 0 THEN
        IF ~Interrupted() THEN RETURN -Errno() END
      ELSIF n = 0 THEN RETURN -5
      ELSE INC(done, n)
      END
    END;
    RETURN 0
  END Read;

  PROCEDURE Write*(fd, offset: LONGINT; VAR data: ARRAY OF CHAR; count: INTEGER): INTEGER;
    VAR done, n: LONGINT;
  BEGIN
    IF (offset < 0) OR (count < 0) OR (count > LEN(data)) THEN RETURN -22 END;
    done := 0;
    WHILE done < count DO
      n := WriteSome(SHORT(fd), offset + done, SYSTEM.ADR(data), done, count);
      IF n < 0 THEN
        IF ~Interrupted() THEN RETURN -Errno() END
      ELSIF n = 0 THEN RETURN -5
      ELSE INC(done, n)
      END
    END;
    RETURN 0
  END Write;

  PROCEDURE Close*(fd: LONGINT; sync: BOOLEAN): INTEGER;
    VAR flag: INTEGER;
  BEGIN
    IF sync THEN flag := 1 ELSE flag := 0 END;
    RETURN SHORT(Close0(SHORT(fd), flag))
  END Close;

  PROCEDURE Sync*(fd: LONGINT): INTEGER;
  BEGIN RETURN SHORT(Sync0(SHORT(fd))) END Sync;

  PROCEDURE Output*(VAR data: ARRAY OF CHAR; count: INTEGER): INTEGER;
    VAR done, n: LONGINT;
  BEGIN
    IF (count < 0) OR (count > LEN(data)) THEN RETURN -22 END;
    done := 0;
    WHILE done < count DO
      n := WriteStd(SYSTEM.ADR(data), done, count);
      IF n < 0 THEN
        IF ~Interrupted() THEN RETURN -Errno() END
      ELSIF n = 0 THEN RETURN -5
      ELSE INC(done, n)
      END
    END;
    RETURN 0
  END Output;

  PROCEDURE CopyString*(source: SYSTEM.ADDRESS; VAR dest: ARRAY OF CHAR): INTEGER;
  BEGIN RETURN SHORT(Copy0(source, SYSTEM.ADR(dest), SHORT(LEN(dest)))) END CopyString;

  PROCEDURE Error*(message: ARRAY OF CHAR);
  BEGIN Error0(SYSTEM.ADR(message)) END Error;

  PROCEDURE Report*(message: ARRAY OF CHAR; error: INTEGER);
  BEGIN Report0(SYSTEM.ADR(message), error) END Report;

  PROCEDURE Exit*(status: INTEGER);
  BEGIN Exit0(status) END Exit;
END Host.
