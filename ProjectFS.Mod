MODULE ProjectFS;
  IMPORT DiskTypes;

  PROCEDURE Configure*(VAR v: DiskTypes.Volume);
  BEGIN
    v.kind := DiskTypes.Project; v.blockSize := 1024; v.headerSize := 352;
    v.nameBytes := 32; v.dirOffset := 64; v.dirCapacity := 24;
    v.directOffset := 96; v.directCount := 64; v.indexOffset := 48;
    v.shortCount := FALSE; v.shortLengths := FALSE; v.doubleIndirect := FALSE
  END Configure;
END ProjectFS.
