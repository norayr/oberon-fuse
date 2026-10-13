MODULE FuseProbe;
  IMPORT SYSTEM, Out;

  TYPE ReadProc = PROCEDURE(path, buffer, size: SYSTEM.ADDRESS;
                            offset: SYSTEM.INT64): SYSTEM.INT32;

  PROCEDURE -AInclude '#include "FuseProbeBridge.h"';
  PROCEDURE -Run(read: ReadProc): SYSTEM.INT32 'OberonFuseProbe_Run(read)';
  PROCEDURE -InvalidArgument(): SYSTEM.INT32 '-EINVAL';

  PROCEDURE Read(path, buffer, size: SYSTEM.ADDRESS;
                 offset: SYSTEM.INT64): SYSTEM.INT32;
    VAR text: ARRAY 12 OF CHAR;
  BEGIN
    IF offset # 0 THEN RETURN 0 END;
    IF size < 11 THEN RETURN InvalidArgument() END;
    text := "VOC-FUSE OK";
    SYSTEM.MOVE(SYSTEM.ADR(text), buffer, 11);
    RETURN 11
  END Read;

BEGIN
  ASSERT(Run(Read) = 0);
  Out.String("VOC/libfuse3 linkage and read callback: OK (no mount)"); Out.Ln
END FuseProbe.
