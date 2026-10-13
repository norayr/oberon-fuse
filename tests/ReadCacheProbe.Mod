MODULE ReadCacheProbe;
  IMPORT Out, ReadCache;
  VAR c, other: ReadCache.Cache; b, result: ARRAY 4096 OF CHAR;
    ages: ARRAY 1536 OF INTEGER;
    pass, bs, capacity, count, actual, geometry, step, key, i, oldest: INTEGER;
    hits, misses, evictions, seed, offset: LONGINT;
BEGIN
  ASSERT(ReadCache.Configure(c, -1) = -22);
  ASSERT(ReadCache.Configure(c, ReadCache.MaxMiB+1) = -22);
  ASSERT(ReadCache.Configure(c, 0) = 0);
  ASSERT(~ReadCache.Get(c, 0, 1024, result));
  ASSERT(ReadCache.Configure(other, 1) = 0);
  bs := 1024;
  FOR pass := 0 TO 2 DO
    ASSERT(ReadCache.Configure(c, 1) = 0); capacity := 1048576 DIV bs; count := 0;
    FOR i := 0 TO LEN(ages)-1 DO ages[i] := -1 END;
    seed := 1;
    FOR step := 1 TO 6000 DO
      seed := seed*48271 MOD 2147483647; key := SHORT(seed MOD LEN(ages));
      (* Colliding buckets and offsets beyond 4 GiB exercise full-width keys. *)
      offset := 4294967296+LONG(key)*(2*capacity+1)*bs;
      IF step MOD 13 = 0 THEN
        ReadCache.Invalidate(c, offset+bs DIV 2, bs);
        IF ages[key] >= 0 THEN ages[key] := -1; DEC(count) END
      ELSIF ages[key] >= 0 THEN
        ASSERT(ReadCache.Get(c, offset, bs, result));
        FOR i := 0 TO bs-1 DO ASSERT(result[i] = CHR(key MOD 251)) END;
        ages[key] := step
      ELSE
        ASSERT(~ReadCache.Get(c, offset, bs, result));
        IF count = capacity THEN
          oldest := -1;
          FOR i := 0 TO LEN(ages)-1 DO
            IF (ages[i] >= 0) & ((oldest < 0) OR (ages[i] < ages[oldest])) THEN oldest := i END
          END;
          ASSERT(oldest >= 0); ages[oldest] := -1; DEC(count)
        END;
        FOR i := 0 TO bs-1 DO b[i] := CHR(key MOD 251) END;
        ReadCache.Put(c, offset, bs, b); ages[key] := step; INC(count)
      END;
      ReadCache.Info(c, actual, geometry, i, hits, misses, evictions);
      ASSERT((actual = capacity) & (geometry = count) & (i = bs))
    END;
    ASSERT((hits > 0) & (misses > 0) & (evictions > 0));
    ASSERT(ReadCache.Configure(c, 1) = 0);
    FOR i := 0 TO bs-1 DO b[i] := "A" END;
    ReadCache.Put(c, 512, bs, b);
    FOR i := 0 TO bs-1 DO b[i] := "B" END;
    ReadCache.Put(other, 512, bs, b);
    ASSERT(ReadCache.Get(c, 512, bs, result) & (result[0] = "A"));
    ASSERT(ReadCache.Get(other, 512, bs, result) & (result[0] = "B"));
    ReadCache.Invalidate(c, 0, 512);
    ASSERT(ReadCache.Get(c, 512, bs, result));
    ReadCache.Invalidate(c, 0, 513);
    ASSERT(~ReadCache.Get(c, 512, bs, result));
    ReadCache.Put(c, 512, bs, b);
    ASSERT(~ReadCache.Get(c, 0, bs, result)); (* changed alignment *)
    ReadCache.Info(c, actual, count, geometry, hits, misses, evictions); ASSERT(count = 0);
    ReadCache.Put(c, 0, bs, b); ReadCache.Clear(c);
    ASSERT(~ReadCache.Get(c, 0, bs, result));
    ASSERT(ReadCache.Configure(c, 0) = 0);
    ASSERT(~ReadCache.Get(c, 0, bs, result));
    ReadCache.Info(c, actual, count, geometry, hits, misses, evictions);
    ASSERT((actual = 0) & (count = 0) & (geometry = 0)); bs := bs*2
  END;
  Out.String("bounded read cache: LRU, collisions, invalidation, isolation and 64-bit offsets: OK"); Out.Ln
END ReadCacheProbe.
