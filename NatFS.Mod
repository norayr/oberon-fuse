MODULE NatFS;
  IMPORT DiskTypes;

  PROCEDURE Configure*(VAR v: DiskTypes.Volume);
  BEGIN
    v.kind := DiskTypes.Native; v.blockSize := 2048; v.headerSize := 352;
    v.nameBytes := 32; v.dirOffset := 48; v.dirCapacity := 50;
    v.directOffset := 96; v.directCount := 64; v.indexOffset := 48;
    v.shortCount := TRUE; v.shortLengths := TRUE; v.doubleIndirect := FALSE
  END Configure;
END NatFS.
