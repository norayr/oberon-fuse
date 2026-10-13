MODULE Host;
  (* The only OS-facing module. Addresses never escape into disk decoders. *)
  IMPORT SYSTEM;

  PROCEDURE -Include '#include "HostBridge.h"';
  PROCEDURE -Open0(path: SYSTEM.ADDRESS): SYSTEM.INT32 'OberonHost_Open((const char *)path)';
  PROCEDURE -Update0(path: SYSTEM.ADDRESS): SYSTEM.INT32 'OberonHost_OpenUpdate((const char *)path)';
  PROCEDURE -Create0(path: SYSTEM.ADDRESS; size: SYSTEM.INT64): SYSTEM.INT32 'OberonHost_Create((const char *)path, size)';
  PROCEDURE -Size0(fd: SYSTEM.INT32): SYSTEM.INT64 'OberonHost_Size(fd)';
  PROCEDURE -Read0(fd: SYSTEM.INT32; offset: SYSTEM.INT64; data: SYSTEM.ADDRESS; count: SYSTEM.INT32): SYSTEM.INT32 'OberonHost_Read(fd, offset, (void *)data, count)';
  PROCEDURE -Write0(fd: SYSTEM.INT32; offset: SYSTEM.INT64; data: SYSTEM.ADDRESS; count: SYSTEM.INT32): SYSTEM.INT32 'OberonHost_Write(fd, offset, (const void *)data, count)';
  PROCEDURE -Close0(fd, sync: SYSTEM.INT32): SYSTEM.INT32 'OberonHost_Close(fd, sync)';
  PROCEDURE -Sync0(fd: SYSTEM.INT32): SYSTEM.INT32 'OberonHost_Sync(fd)';
  PROCEDURE -Output0(data: SYSTEM.ADDRESS; count: SYSTEM.INT32): SYSTEM.INT32 'OberonHost_Output((const void *)data, count)';
  PROCEDURE -Copy0(source, dest: SYSTEM.ADDRESS; capacity: SYSTEM.INT32): SYSTEM.INT32 'OberonHost_CopyString(source, (char *)dest, capacity)';
  PROCEDURE -Error0(message: SYSTEM.ADDRESS) 'OberonHost_Error((const char *)message)';
  PROCEDURE -Report0(message: SYSTEM.ADDRESS; error: SYSTEM.INT32) 'OberonHost_Report((const char *)message, error)';
  PROCEDURE -Exit0(status: SYSTEM.INT32) 'OberonHost_Exit(status)';

  PROCEDURE Open*(path: ARRAY OF CHAR): LONGINT;
  BEGIN RETURN Open0(SYSTEM.ADR(path)) END Open;

  PROCEDURE OpenUpdate*(path: ARRAY OF CHAR): LONGINT;
  BEGIN RETURN Update0(SYSTEM.ADR(path)) END OpenUpdate;

  PROCEDURE Create*(path: ARRAY OF CHAR; size: LONGINT): LONGINT;
  BEGIN RETURN Create0(SYSTEM.ADR(path), size) END Create;

  PROCEDURE Size*(fd: LONGINT): LONGINT;
  BEGIN RETURN Size0(SHORT(fd)) END Size;

  PROCEDURE Read*(fd, offset: LONGINT; VAR data: ARRAY OF CHAR; count: INTEGER): INTEGER;
  BEGIN
    IF (offset < 0) OR (count < 0) OR (count > LEN(data)) THEN RETURN -22 END;
    RETURN SHORT(Read0(SHORT(fd), offset, SYSTEM.ADR(data), count))
  END Read;

  PROCEDURE Write*(fd, offset: LONGINT; VAR data: ARRAY OF CHAR; count: INTEGER): INTEGER;
  BEGIN
    IF (offset < 0) OR (count < 0) OR (count > LEN(data)) THEN RETURN -22 END;
    RETURN SHORT(Write0(SHORT(fd), offset, SYSTEM.ADR(data), count))
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
  BEGIN
    IF (count < 0) OR (count > LEN(data)) THEN RETURN -22 END;
    RETURN SHORT(Output0(SYSTEM.ADR(data), count))
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
