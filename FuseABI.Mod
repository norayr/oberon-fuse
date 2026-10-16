MODULE FuseABI;
  (* All libfuse addresses and callback marshalling stay in this module. *)
  IMPORT SYSTEM, Host, DiskTypes;
  CONST Open* = 1; Create* = 2; Truncate* = 3; Unlink* = 4; Rename* = 5;
    Time* = 6; Flush* = 7; Release* = 8; Sync* = 9;
  TYPE
    StatProc* = PROCEDURE(name: ARRAY OF CHAR; handle: LONGINT; VAR size, modified: LONGINT): INTEGER;
    TransferProc* = PROCEDURE(name: ARRAY OF CHAR; handle, offset: LONGINT; VAR data: ARRAY OF CHAR; count: INTEGER): INTEGER;
    DirectoryProc* = PROCEDURE(name: ARRAY OF CHAR; offset: LONGINT): INTEGER;
    ActionProc* = PROCEDURE(name, other: ARRAY OF CHAR; operation: INTEGER; VAR handle: LONGINT; argument: LONGINT): INTEGER;
    SpaceProc* = PROCEDURE(VAR blocks, free: LONGINT; VAR blockSize, nameSize: INTEGER): INTEGER;
  VAR
    stat: StatProc; read, write: TransferProc; directory: DirectoryProc;
    action: ActionProc; space: SpaceProc; writableMount: BOOLEAN;
    outputBuffer, outputFiller: SYSTEM.ADDRESS;

  (* A code body is stored with a one-byte length: keep every quoted string
     under 256 characters and compose longer operations from fragments. *)
  PROCEDURE -A0FuseVersion '#define FUSE_USE_VERSION 31';
  PROCEDURE -A1Fuse '#include <fuse.h>';
  PROCEDURE -A2Fcntl '#include <fcntl.h>';
  PROCEDURE -A3Stat '#include <sys/stat.h>';
  PROCEDURE -A4Statvfs '#include <sys/statvfs.h>';
  PROCEDURE -A5Stdint '#include <stdint.h>';
  PROCEDURE -A6String '#include <string.h>';
  PROCEDURE -A7Time '#include <time.h>';
  PROCEDURE -A8Types '#include <sys/types.h>';
  PROCEDURE -A9Unix '#include <unistd.h>';
  PROCEDURE -ZOffGuard 'extern char oberon_fuse_off_t_guard[sizeof(off_t) == 8 ? 1 : -1];';
  PROCEDURE -ZPragma '#pragma GCC diagnostic ignored "-Wcast-function-type"';

  (* Field access for the libfuse structures. *)
  PROCEDURE -Handle(info: SYSTEM.ADDRESS): SYSTEM.INT64
    '((struct fuse_file_info *)info)->fh';
  PROCEDURE -SetHandle(info: SYSTEM.ADDRESS; handle: LONGINT)
    '((struct fuse_file_info *)info)->fh = (uint64_t)handle';
  PROCEDURE -SetDirectIO(info: SYSTEM.ADDRESS)
    '((struct fuse_file_info *)info)->direct_io = 1';
  PROCEDURE -OpenFlags(info: SYSTEM.ADDRESS): INTEGER
    '((((struct fuse_file_info *)info)->flags & O_ACCMODE) != O_RDONLY ? 1 : 0) | (((struct fuse_file_info *)info)->flags & O_TRUNC ? 2 : 0) | (((struct fuse_file_info *)info)->flags & O_APPEND ? 4 : 0)';
  PROCEDURE -CfgTimeouts(config: SYSTEM.ADDRESS)
    '((struct fuse_config *)config)->entry_timeout = ((struct fuse_config *)config)->negative_timeout = ((struct fuse_config *)config)->attr_timeout = 0';
  PROCEDURE -CfgFlags(config: SYSTEM.ADDRESS)
    '((struct fuse_config *)config)->use_ino = 0; ((struct fuse_config *)config)->hard_remove = 1; ((struct fuse_config *)config)->nullpath_ok = 1';
  PROCEDURE -OmitTime(times: SYSTEM.ADDRESS): BOOLEAN
    '((const struct timespec *)times)[1].tv_nsec == UTIME_OMIT';
  PROCEDURE -NowTime(times: SYSTEM.ADDRESS): BOOLEAN
    '((const struct timespec *)times)[1].tv_nsec == UTIME_NOW';
  PROCEDURE -TimeSeconds(times: SYSTEM.ADDRESS): LONGINT
    '((const struct timespec *)times)[1].tv_sec';

  (* Result structures are zeroed before the fields are set. *)
  PROCEDURE -FillStat0(st: SYSTEM.ADDRESS)
    '({ struct stat *s_ = (struct stat *)st; memset(s_, 0, sizeof *s_); s_->st_uid = getuid(); s_->st_gid = getgid(); s_->st_blksize = 4096; })';
  PROCEDURE -FillStatKind(st: SYSTEM.ADDRESS; kind, w: INTEGER)
    '({ struct stat *s_ = (struct stat *)st; s_->st_mode = kind == 1 ? S_IFDIR | (w ? 0755 : 0555) : S_IFREG | (w ? 0644 : 0444); s_->st_nlink = kind == 1 ? 2 : kind == 2 ? 0 : 1; })';
  PROCEDURE -FillStatSize(st: SYSTEM.ADDRESS; size: LONGINT)
    '({ struct stat *s_ = (struct stat *)st; s_->st_size = (off_t)size; s_->st_blocks = (size + 511) / 512; })';
  PROCEDURE -FillStatTimes(st: SYSTEM.ADDRESS; modified: LONGINT)
    '({ struct stat *s_ = (struct stat *)st; s_->st_atime = s_->st_mtime = s_->st_ctime = (time_t)modified; })';
  PROCEDURE -FillStat(st: SYSTEM.ADDRESS; kind: INTEGER; size, modified: LONGINT; w: INTEGER)
    '({ FuseABI_FillStat0(st); FuseABI_FillStatKind(st, kind, w); FuseABI_FillStatSize(st, size); FuseABI_FillStatTimes(st, modified); })';
  PROCEDURE -FillStatvfs0(st: SYSTEM.ADDRESS; blockSize, nameSize: INTEGER)
    '({ struct statvfs *v_ = (struct statvfs *)st; memset(v_, 0, sizeof *v_); v_->f_bsize = v_->f_frsize = (unsigned long)blockSize; v_->f_namemax = (unsigned long)nameSize; })';
  PROCEDURE -FillStatvfs1(st: SYSTEM.ADDRESS; blocks, free: LONGINT)
    '({ struct statvfs *v_ = (struct statvfs *)st; v_->f_blocks = (fsblkcnt_t)blocks; v_->f_bfree = v_->f_bavail = (fsblkcnt_t)free; })';
  PROCEDURE -FillStatvfs(st: SYSTEM.ADDRESS; blocks, free: LONGINT; blockSize, nameSize: INTEGER)
    '({ FuseABI_FillStatvfs0(st, blockSize, nameSize); FuseABI_FillStatvfs1(st, blocks, free); })';

  (* The operations table is a local of Run; the callbacks fill it. *)
  PROCEDURE -OpsLocal 'struct fuse_operations ops_';
  PROCEDURE -OpsClear 'memset(&ops_, 0, sizeof ops_)';
  PROCEDURE -OpsFill0
    'ops_.init = (void *(*)(struct fuse_conn_info *, struct fuse_config *))FuseABI_CbInit; ops_.getattr = (int (*)(const char *, struct stat *, struct fuse_file_info *))FuseABI_CbGetattr';
  PROCEDURE -OpsFill1
    'ops_.open = (int (*)(const char *, struct fuse_file_info *))FuseABI_CbOpen; ops_.create = (int (*)(const char *, mode_t, struct fuse_file_info *))FuseABI_CbCreate';
  PROCEDURE -OpsFill2
    'ops_.read = (int (*)(const char *, char *, size_t, off_t, struct fuse_file_info *))FuseABI_CbRead; ops_.write = (int (*)(const char *, const char *, size_t, off_t, struct fuse_file_info *))FuseABI_CbWrite';
  PROCEDURE -OpsFill3
    'ops_.truncate = (int (*)(const char *, off_t, struct fuse_file_info *))FuseABI_CbTruncate; ops_.unlink = (int (*)(const char *))FuseABI_CbUnlink; ops_.rename = (int (*)(const char *, const char *, unsigned int))FuseABI_CbRename';
  PROCEDURE -OpsFill4
    'ops_.readdir = (int (*)(const char *, void *, fuse_fill_dir_t, off_t, struct fuse_file_info *, enum fuse_readdir_flags))FuseABI_CbReaddir';
  PROCEDURE -OpsFill5
    'ops_.utimens = (int (*)(const char *, const struct timespec *, struct fuse_file_info *))FuseABI_CbUtimens; ops_.statfs = (int (*)(const char *, struct statvfs *))FuseABI_CbStatfs';
  PROCEDURE -OpsFill6
    'ops_.flush = (int (*)(const char *, struct fuse_file_info *))FuseABI_CbFlush; ops_.release = (int (*)(const char *, struct fuse_file_info *))FuseABI_CbRelease';
  PROCEDURE -OpsFill7
    'ops_.fsync = (int (*)(const char *, int, struct fuse_file_info *))FuseABI_CbFsync; ops_.fsyncdir = (int (*)(const char *, int, struct fuse_file_info *))FuseABI_CbFsyncdir';
  PROCEDURE -Mount(mountpoint: SYSTEM.ADDRESS; writable: SYSTEM.INT32): SYSTEM.INT32
    '({ char *argv_[] = { "oberon-fuse", "-f", "-s", "-o", writable ? "rw,default_permissions" : "ro,default_permissions", (char *)mountpoint, NULL }; fuse_main(6, argv_, &ops_, NULL); })';
  PROCEDURE -Add0(buffer, filler, name: SYSTEM.ADDRESS; cookie: SYSTEM.INT64): SYSTEM.INT32
    '(((fuse_fill_dir_t)filler)((void *)buffer, (const char *)name, NULL, (off_t)cookie, 0) == 0)';

  PROCEDURE Name(path: SYSTEM.ADDRESS; VAR name: ARRAY OF CHAR): INTEGER;
  BEGIN IF path = 0 THEN name[0] := 0X; RETURN 0 END; RETURN Host.CopyString(path, name) END Name;

  PROCEDURE DoAction(path, other: SYSTEM.ADDRESS; operation: INTEGER; info: SYSTEM.ADDRESS; argument: LONGINT): INTEGER;
    VAR name, target: ARRAY 1024 OF CHAR; res: INTEGER; h: LONGINT;
  BEGIN
    res := Name(path, name); IF res # 0 THEN RETURN res END;
    res := Name(other, target); IF res # 0 THEN RETURN res END;
    IF info # 0 THEN h := Handle(info) ELSE h := 0 END;
    res := action(name, target, operation, h, argument);
    IF (res = 0) & (info # 0) THEN SetHandle(info, h) END;
    RETURN res
  END DoAction;

  PROCEDURE Transfer(path, data: SYSTEM.ADDRESS; size, offset, handle: SYSTEM.INT64; writing: BOOLEAN): SYSTEM.INT32;
    VAR name: ARRAY 1024 OF CHAR; b: DiskTypes.Buffer; res, count: INTEGER; done: LONGINT;
  BEGIN
    IF (offset < 0) OR (size < 0) OR (size > 2147483647) THEN RETURN -22 END;
    res := Name(path, name); IF res # 0 THEN RETURN res END;
    done := 0;
    WHILE done < size DO
      count := LEN(b); IF count > size-done THEN count := SHORT(size-done) END;
      IF offset > MAX(LONGINT)-done THEN RETURN -22 END;
      IF writing THEN
        SYSTEM.MOVE(data+done, SYSTEM.ADR(b), count); res := write(name, handle, offset+done, b, count)
      ELSE res := read(name, handle, offset+done, b, count) END;
      IF res < 0 THEN IF done > 0 THEN RETURN SHORT(done) ELSE RETURN res END END;
      IF res = 0 THEN RETURN SHORT(done) END;
      IF res > count THEN RETURN -5 END;
      IF ~writing THEN SYSTEM.MOVE(SYSTEM.ADR(b), data+done, res) END;
      INC(done, res)
    END;
    RETURN SHORT(done)
  END Transfer;

  (* The libfuse callbacks are ordinary Oberon procedures; the operations
     table is filled with casts through the pragma above. *)
  PROCEDURE CbInit(connection, config: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
  BEGIN
    CfgTimeouts(config); CfgFlags(config);
    RETURN 0
  END CbInit;

  PROCEDURE CbGetattr(path: SYSTEM.ADDRESS; st: SYSTEM.ADDRESS; info: SYSTEM.ADDRESS): SYSTEM.INT32;
    VAR name: ARRAY 1024 OF CHAR; kind, flag, res: INTEGER; size, modified, handle: LONGINT;
  BEGIN
    res := Name(path, name); IF res # 0 THEN RETURN res END;
    IF info # 0 THEN handle := Handle(info) ELSE handle := 0 END;
    IF writableMount THEN flag := 1 ELSE flag := 0 END;
    size := 0; modified := 0;
    kind := stat(name, handle, size, modified);
    IF kind < 0 THEN RETURN kind END;
    FillStat(st, kind, size, modified, flag);
    RETURN 0
  END CbGetattr;

  PROCEDURE CbOpen(path: SYSTEM.ADDRESS; info: SYSTEM.ADDRESS): SYSTEM.INT32;
    VAR res: INTEGER;
  BEGIN
    res := DoAction(path, 0, Open, info, OpenFlags(info));
    IF res = 0 THEN SetDirectIO(info) END;
    RETURN res
  END CbOpen;

  PROCEDURE CbCreate(path: SYSTEM.ADDRESS; mode: SYSTEM.INT32; info: SYSTEM.ADDRESS): SYSTEM.INT32;
    VAR res: INTEGER;
  BEGIN
    res := DoAction(path, 0, Create, info, OpenFlags(info));
    IF res = 0 THEN SetDirectIO(info) END;
    RETURN res
  END CbCreate;

  PROCEDURE CbRead(path, data: SYSTEM.ADDRESS; size, offset: SYSTEM.INT64; info: SYSTEM.ADDRESS): SYSTEM.INT32;
  BEGIN
    RETURN Transfer(path, data, size, offset, Handle(info), FALSE)
  END CbRead;

  PROCEDURE CbWrite(path, data: SYSTEM.ADDRESS; size, offset: SYSTEM.INT64; info: SYSTEM.ADDRESS): SYSTEM.INT32;
  BEGIN
    IF ~writableMount THEN RETURN -30 END;
    RETURN Transfer(path, data, size, offset, Handle(info), TRUE)
  END CbWrite;

  PROCEDURE CbTruncate(path: SYSTEM.ADDRESS; size: SYSTEM.INT64; info: SYSTEM.ADDRESS): SYSTEM.INT32;
  BEGIN
    RETURN DoAction(path, 0, Truncate, info, size)
  END CbTruncate;

  PROCEDURE CbUnlink(path: SYSTEM.ADDRESS): SYSTEM.INT32;
  BEGIN
    RETURN DoAction(path, 0, Unlink, 0, 0)
  END CbUnlink;

  PROCEDURE CbRename(path, other: SYSTEM.ADDRESS; flags: SYSTEM.INT32): SYSTEM.INT32;
  BEGIN
    IF flags # 0 THEN RETURN -22 END;
    RETURN DoAction(path, other, Rename, 0, 0)
  END CbRename;

  PROCEDURE CbUtimens(path: SYSTEM.ADDRESS; times: SYSTEM.ADDRESS; info: SYSTEM.ADDRESS): SYSTEM.INT32;
    VAR modified: LONGINT;
  BEGIN
    IF ~writableMount THEN RETURN -30 END;
    IF times = 0 THEN modified := Host.Now()
    ELSIF OmitTime(times) THEN RETURN 0
    ELSIF NowTime(times) THEN modified := Host.Now()
    ELSE modified := TimeSeconds(times)
    END;
    RETURN DoAction(path, 0, Time, info, modified)
  END CbUtimens;

  PROCEDURE CbFlush(path: SYSTEM.ADDRESS; info: SYSTEM.ADDRESS): SYSTEM.INT32;
  BEGIN
    RETURN DoAction(path, 0, Flush, info, 0)
  END CbFlush;

  PROCEDURE CbRelease(path: SYSTEM.ADDRESS; info: SYSTEM.ADDRESS): SYSTEM.INT32;
  BEGIN
    RETURN DoAction(path, 0, Release, info, 0)
  END CbRelease;

  PROCEDURE CbFsync(path: SYSTEM.ADDRESS; dataOnly: SYSTEM.INT32; info: SYSTEM.ADDRESS): SYSTEM.INT32;
  BEGIN
    RETURN DoAction(path, 0, Flush, info, 0)
  END CbFsync;

  PROCEDURE CbFsyncdir(path: SYSTEM.ADDRESS; dataOnly: SYSTEM.INT32; info: SYSTEM.ADDRESS): SYSTEM.INT32;
  BEGIN
    RETURN DoAction(path, 0, Sync, 0, 0)
  END CbFsyncdir;

  PROCEDURE CbStatfs(path: SYSTEM.ADDRESS; st: SYSTEM.ADDRESS): SYSTEM.INT32;
    VAR blocks, free: LONGINT; blockSize, nameSize, res: INTEGER;
  BEGIN
    res := space(blocks, free, blockSize, nameSize);
    IF res # 0 THEN RETURN res END;
    FillStatvfs(st, blocks, free, blockSize, nameSize);
    RETURN 0
  END CbStatfs;

  PROCEDURE CbReaddir(path, buffer, filler: SYSTEM.ADDRESS; offset: SYSTEM.INT64;
                      info: SYSTEM.ADDRESS; flags: SYSTEM.INT32): SYSTEM.INT32;
    VAR name: ARRAY 1024 OF CHAR; res: INTEGER;
  BEGIN
    res := Name(path, name); IF res # 0 THEN RETURN res END;
    outputBuffer := buffer; outputFiller := filler;
    res := directory(name, offset);
    outputBuffer := 0; outputFiller := 0;
    RETURN res
  END CbReaddir;

  PROCEDURE Add*(name: ARRAY OF CHAR; cookie: LONGINT): BOOLEAN;
  BEGIN
    IF outputFiller = 0 THEN RETURN FALSE END;
    RETURN Add0(outputBuffer, outputFiller, SYSTEM.ADR(name), cookie) # 0
  END Add;

  PROCEDURE Run*(mountpoint: ARRAY OF CHAR; writable: BOOLEAN; getstat: StatProc;
                 getread, getwrite: TransferProc; getdirectory: DirectoryProc;
                 getaction: ActionProc; getspace: SpaceProc): INTEGER;
    VAR res, flag: INTEGER;
  BEGIN
    stat := getstat; read := getread; write := getwrite; directory := getdirectory;
    action := getaction; space := getspace; writableMount := writable;
    flag := 0; IF writable THEN flag := 1 END;
    OpsLocal; OpsClear; OpsFill0; OpsFill1; OpsFill2; OpsFill3;
    OpsFill4; OpsFill5; OpsFill6; OpsFill7;
    res := Mount(SYSTEM.ADR(mountpoint), flag);
    stat := NIL; read := NIL; write := NIL; directory := NIL; action := NIL; space := NIL;
    RETURN res
  END Run;
END FuseABI.
