MODULE FuseABI;
  (* All libfuse addresses and callback marshalling stay in this module. *)
  IMPORT SYSTEM, Host, DiskTypes;
  TYPE
    StatProc* = PROCEDURE(name: ARRAY OF CHAR; VAR size: LONGINT): INTEGER;
    ReadProc* = PROCEDURE(name: ARRAY OF CHAR; offset: LONGINT; VAR data: ARRAY OF CHAR; count: INTEGER): INTEGER;
    DirectoryProc* = PROCEDURE(name: ARRAY OF CHAR; offset: LONGINT): INTEGER;
    RawStat = PROCEDURE(path: SYSTEM.ADDRESS; VAR size: SYSTEM.INT64): SYSTEM.INT32;
    RawRead = PROCEDURE(path, data, size: SYSTEM.ADDRESS; offset: SYSTEM.INT64): SYSTEM.INT32;
    RawDirectory = PROCEDURE(path, buffer, filler: SYSTEM.ADDRESS; offset: SYSTEM.INT64): SYSTEM.INT32;
  VAR
    stat: StatProc; read: ReadProc; directory: DirectoryProc;
    outputBuffer, outputFiller: SYSTEM.ADDRESS;

  PROCEDURE -Include '#include "FuseBridge.h"';
  PROCEDURE -Run0(mountpoint: SYSTEM.ADDRESS; stat: RawStat; read: RawRead; directory: RawDirectory): SYSTEM.INT32
    'OberonFuse_Run((const char *)mountpoint, stat, read, directory)';
  PROCEDURE -Add0(buffer, filler, name: SYSTEM.ADDRESS; cookie: SYSTEM.INT64): SYSTEM.INT32
    'OberonFuse_Add(buffer, filler, (const char *)name, cookie)';

  PROCEDURE Stat(path: SYSTEM.ADDRESS; VAR size: SYSTEM.INT64): SYSTEM.INT32;
    VAR name: ARRAY 1024 OF CHAR; res: INTEGER; n: LONGINT;
  BEGIN
    res := Host.CopyString(path, name); IF res # 0 THEN RETURN res END;
    n := 0; res := stat(name, n); size := n;
    RETURN res
  END Stat;

  PROCEDURE Read(path, data, size: SYSTEM.ADDRESS; offset: SYSTEM.INT64): SYSTEM.INT32;
    VAR name: ARRAY 1024 OF CHAR; b: DiskTypes.Buffer; res, count: INTEGER; done: LONGINT;
  BEGIN
    IF (offset < 0) OR (size < 0) OR (size > 2147483647) THEN RETURN -22 END;
    res := Host.CopyString(path, name); IF res # 0 THEN RETURN res END;
    done := 0;
    WHILE done < size DO
      count := LEN(b); IF count > size-done THEN count := SHORT(size-done) END;
      IF offset > MAX(LONGINT)-done THEN RETURN -22 END;
      res := read(name, offset+done, b, count);
      IF res < 0 THEN IF done > 0 THEN RETURN SHORT(done) ELSE RETURN res END END;
      IF res = 0 THEN RETURN SHORT(done) END;
      IF res > count THEN RETURN -5 END;
      SYSTEM.MOVE(SYSTEM.ADR(b), data+done, res); INC(done, res)
    END;
    RETURN SHORT(done)
  END Read;

  PROCEDURE Directory(path, buffer, filler: SYSTEM.ADDRESS; offset: SYSTEM.INT64): SYSTEM.INT32;
    VAR name: ARRAY 1024 OF CHAR; res: INTEGER;
  BEGIN
    res := Host.CopyString(path, name); IF res # 0 THEN RETURN res END;
    outputBuffer := buffer; outputFiller := filler;
    res := directory(name, offset);
    outputBuffer := 0; outputFiller := 0;
    RETURN res
  END Directory;

  PROCEDURE Add*(name: ARRAY OF CHAR; cookie: LONGINT): BOOLEAN;
  BEGIN
    IF outputFiller = 0 THEN RETURN FALSE END;
    RETURN Add0(outputBuffer, outputFiller, SYSTEM.ADR(name), cookie) # 0
  END Add;

  PROCEDURE Run*(mountpoint: ARRAY OF CHAR; getstat: StatProc; getread: ReadProc; getdirectory: DirectoryProc): INTEGER;
    VAR res: INTEGER;
  BEGIN
    stat := getstat; read := getread; directory := getdirectory;
    res := Run0(SYSTEM.ADR(mountpoint), Stat, Read, Directory);
    stat := NIL; read := NIL; directory := NIL;
    RETURN res
  END Run;
END FuseABI.
