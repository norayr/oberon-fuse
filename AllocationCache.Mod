MODULE AllocationCache;
  IMPORT DiskTypes, DiskBytes, BlockIO, OberonBTree;

  PROCEDURE Invalidate*(VAR v: DiskTypes.Volume): INTEGER;
    VAR b: DiskTypes.Buffer; key, offset: LONGINT; res: INTEGER;
  BEGIN
    IF (v.kind = DiskTypes.Project) OR (v.kind = DiskTypes.Ceres) OR v.lastClaimed THEN RETURN 0 END;
    key := (v.limit-v.root) DIV v.blockSize*29;
    res := OberonBTree.GetBlock(v, key, b); IF res # 0 THEN RETURN res END;
    IF (b[0] = 7FX) & (b[1] = 97X) & (b[2] = 2FX) & (b[3] = 9CX) THEN
      DiskBytes.Put32(b, 0, 0);
      IF ~OberonBTree.Offset(v, key, offset) THEN RETURN -5 END;
      RETURN BlockIO.Write(v.image, offset, b, 4)
    END;
    RETURN 0
  END Invalidate;
END AllocationCache.
