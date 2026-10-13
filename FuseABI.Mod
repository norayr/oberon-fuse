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
    RawStat = PROCEDURE(path: SYSTEM.ADDRESS; handle: SYSTEM.INT64; VAR size, modified: SYSTEM.INT64): SYSTEM.INT32;
    RawTransfer = PROCEDURE(path, data, size: SYSTEM.ADDRESS; offset, handle: SYSTEM.INT64): SYSTEM.INT32;
    RawDirectory = PROCEDURE(path, buffer, filler: SYSTEM.ADDRESS; offset: SYSTEM.INT64): SYSTEM.INT32;
    RawAction = PROCEDURE(path, other: SYSTEM.ADDRESS; operation: SYSTEM.INT32; VAR handle: SYSTEM.INT64; argument: SYSTEM.INT64): SYSTEM.INT32;
    RawSpace = PROCEDURE(VAR blocks, free: SYSTEM.INT64; VAR blockSize, nameSize: SYSTEM.INT32): SYSTEM.INT32;
  VAR
    stat: StatProc; read, write: TransferProc; directory: DirectoryProc;
    action: ActionProc; space: SpaceProc;
    outputBuffer, outputFiller: SYSTEM.ADDRESS;

  PROCEDURE -Include '#include "FuseBridge.h"';
  PROCEDURE -Run0(mountpoint: SYSTEM.ADDRESS; writable: SYSTEM.INT32; stat: RawStat;
                 read, write: RawTransfer; directory: RawDirectory; action: RawAction; space: RawSpace): SYSTEM.INT32
    'OberonFuse_Run((const char *)mountpoint, writable, stat, read, write, directory, action, space)';
  PROCEDURE -Add0(buffer, filler, name: SYSTEM.ADDRESS; cookie: SYSTEM.INT64): SYSTEM.INT32
    'OberonFuse_Add(buffer, filler, (const char *)name, cookie)';

  PROCEDURE Name(path: SYSTEM.ADDRESS; VAR name: ARRAY OF CHAR): INTEGER;
  BEGIN IF path = 0 THEN name[0] := 0X; RETURN 0 END; RETURN Host.CopyString(path, name) END Name;

  PROCEDURE Stat(path: SYSTEM.ADDRESS; handle: SYSTEM.INT64; VAR size, modified: SYSTEM.INT64): SYSTEM.INT32;
    VAR name: ARRAY 1024 OF CHAR; res: INTEGER; n, time: LONGINT;
  BEGIN
    res := Name(path, name); IF res # 0 THEN RETURN res END;
    n := 0; time := 0; res := stat(name, handle, n, time); size := n; modified := time;
    RETURN res
  END Stat;

  PROCEDURE Transfer(path, data, size: SYSTEM.ADDRESS; offset, handle: SYSTEM.INT64; writing: BOOLEAN): SYSTEM.INT32;
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

  PROCEDURE Read(path, data, size: SYSTEM.ADDRESS; offset, handle: SYSTEM.INT64): SYSTEM.INT32;
  BEGIN RETURN Transfer(path, data, size, offset, handle, FALSE) END Read;

  PROCEDURE Write(path, data, size: SYSTEM.ADDRESS; offset, handle: SYSTEM.INT64): SYSTEM.INT32;
  BEGIN RETURN Transfer(path, data, size, offset, handle, TRUE) END Write;

  PROCEDURE Action(path, other: SYSTEM.ADDRESS; operation: SYSTEM.INT32;
                   VAR handle: SYSTEM.INT64; argument: SYSTEM.INT64): SYSTEM.INT32;
    VAR name, target: ARRAY 1024 OF CHAR; res: INTEGER; h: LONGINT;
  BEGIN
    res := Name(path, name); IF res # 0 THEN RETURN res END;
    res := Name(other, target); IF res # 0 THEN RETURN res END;
    h := handle; res := action(name, target, SHORT(operation), h, argument); handle := h;
    RETURN res
  END Action;

  PROCEDURE Space(VAR blocks, free: SYSTEM.INT64; VAR blockSize, nameSize: SYSTEM.INT32): SYSTEM.INT32;
    VAR n, f: LONGINT; bs, ns, res: INTEGER;
  BEGIN
    res := space(n, f, bs, ns); blocks := n; free := f; blockSize := bs; nameSize := ns;
    RETURN res
  END Space;

  PROCEDURE Directory(path, buffer, filler: SYSTEM.ADDRESS; offset: SYSTEM.INT64): SYSTEM.INT32;
    VAR name: ARRAY 1024 OF CHAR; res: INTEGER;
  BEGIN
    res := Name(path, name); IF res # 0 THEN RETURN res END;
    outputBuffer := buffer; outputFiller := filler;
    res := directory(name, offset); outputBuffer := 0; outputFiller := 0;
    RETURN res
  END Directory;

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
    action := getaction; space := getspace; flag := 0; IF writable THEN flag := 1 END;
    res := Run0(SYSTEM.ADR(mountpoint), flag, Stat, Read, Write, Directory, Action, Space);
    stat := NIL; read := NIL; write := NIL; directory := NIL; action := NIL; space := NIL;
    RETURN res
  END Run;
END FuseABI.
