MODULE CacheIOProbe;
  IMPORT Modules, Out, BlockIO;
  VAR image, alias: BlockIO.Image; path, mode: ARRAY 1024 OF CHAR; b: ARRAY 4096 OF CHAR;
    capacity, count, bs, i, res: INTEGER; hits, misses, evictions: LONGINT;
BEGIN
  ASSERT(Modules.ArgCount = 3); Modules.GetArg(1, path); Modules.GetArg(2, mode);
  ASSERT(BlockIO.OpenUpdate(path, image) = 0); ASSERT(BlockIO.ConfigureCache(image, 1) = 0);
  IF mode = "failed-read" THEN
    ASSERT(BlockIO.ReadBlock(image, 0, b, 1024) = -5);
    ASSERT(BlockIO.ReadBlock(image, 0, b, 1024) = -5);
    BlockIO.CacheInfo(image, capacity, count, bs, hits, misses, evictions);
    ASSERT((count = 0) & (hits = 0) & (misses = 2))
  ELSE
    ASSERT(BlockIO.ReadBlock(image, 0, b, 1024) = 0); ASSERT(b[0] = "A");
    ASSERT(BlockIO.ReadBlock(image, 1024, b, 1024) = 0); ASSERT(b[0] = "B");
    ASSERT(BlockIO.ReadBlock(image, 0, b, 1024) = 0);
    BlockIO.CacheInfo(image, capacity, count, bs, hits, misses, evictions);
    ASSERT((capacity = 1024) & (count = 2) & (hits = 1) & (misses = 2));
    ASSERT(BlockIO.ConfigureCache(image, -1) = -22);
    alias := image; FOR i := 0 TO 1023 DO b[i] := "Z" END;
    res := BlockIO.Write(alias, 1023, b, 1024);
    IF mode = "partial" THEN ASSERT(res = -5) ELSE ASSERT((mode = "normal") & (res = 0)) END;
    BlockIO.CacheInfo(image, capacity, count, bs, hits, misses, evictions); ASSERT(count = 0);
    ASSERT(BlockIO.ReadBlock(image, 0, b, 1024) = 0);
    FOR i := 0 TO 1022 DO ASSERT(b[i] = "A") END; ASSERT(b[1023] = "Z");
    ASSERT(BlockIO.ReadBlock(image, 1024, b, 1024) = 0);
    FOR i := 0 TO 510 DO ASSERT(b[i] = "Z") END;
    IF mode = "partial" THEN FOR i := 511 TO 1023 DO ASSERT(b[i] = "B") END
    ELSE FOR i := 511 TO 1022 DO ASSERT(b[i] = "Z") END; ASSERT(b[1023] = "B") END;
    ASSERT(BlockIO.ReadBlock(image, -1, b, 1024) = -5);
    ASSERT(BlockIO.ReadBlock(image, 3073, b, 1024) = -5);
    ASSERT(BlockIO.Resize(alias, 2048) = 0);
    BlockIO.CacheInfo(image, capacity, count, bs, hits, misses, evictions); ASSERT(count = 0);
    ASSERT(BlockIO.ConfigureCache(alias, 0) = 0);
    BlockIO.CacheInfo(image, capacity, count, bs, hits, misses, evictions); ASSERT(capacity = 0)
  END;
  ASSERT(BlockIO.Close(image) = 0);
  ASSERT(BlockIO.ReadBlock(image, 0, b, 1024) = -5);
  Out.String("read cache host I/O and shared-image invalidation: OK"); Out.Ln
END CacheIOProbe.
