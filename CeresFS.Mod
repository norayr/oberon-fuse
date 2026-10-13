MODULE CeresFS;
  IMPORT DiskTypes;

  PROCEDURE Configure*(VAR v: DiskTypes.Volume);
  BEGIN
    v.kind := DiskTypes.Ceres; v.blockSize := 1024; v.headerSize := 352;
    v.nameBytes := 32; v.dirOffset := 64; v.dirCapacity := 24;
    v.directOffset := 96; v.directCount := 64; v.indexOffset := 48;
    v.shortCount := TRUE; v.shortLengths := TRUE; v.doubleIndirect := FALSE
  END Configure;
END CeresFS.
