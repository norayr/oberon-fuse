MODULE AosFS;
  IMPORT DiskTypes;

  PROCEDURE Configure*(version: INTEGER; VAR v: DiskTypes.Volume);
  BEGIN
    ASSERT((version = 1) OR (version = 2));
    IF version = 1 THEN
      v.kind := DiskTypes.Aos1; v.nameBytes := 32; v.headerSize := 568; v.dirCapacity := 102
    ELSE
      v.kind := DiskTypes.Aos2; v.nameBytes := 128; v.headerSize := 664; v.dirCapacity := 30
    END;
    v.blockSize := 4096; v.dirOffset := 16;
    v.directOffset := v.nameBytes+20; v.directCount := 128;
    v.indexOffset := v.headerSize-4;
    v.shortCount := FALSE; v.shortLengths := FALSE; v.doubleIndirect := TRUE
  END Configure;
END AosFS.
