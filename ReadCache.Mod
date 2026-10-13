MODULE ReadCache;
  (* Per-image, bounded read-through LRU. No dirty blocks or delayed writes. *)
  CONST MaxMiB* = 256; Empty = -1;
  TYPE
    Slot = RECORD offset: LONGINT; previous, next, hashNext: INTEGER END;
    Cache* = POINTER TO CacheDesc;
    CacheDesc = RECORD
      budget, blockSize, alignment, capacity, count, allocated: INTEGER;
      newest, oldest, free: INTEGER;
      hits, misses, evictions: LONGINT;
      slots: POINTER TO ARRAY OF Slot;
      buckets: POINTER TO ARRAY OF INTEGER;
      data: POINTER TO ARRAY OF CHAR
    END;

  PROCEDURE Clear*(c: Cache);
    VAR i: INTEGER;
  BEGIN
    IF c = NIL THEN RETURN END;
    IF c.buckets # NIL THEN FOR i := 0 TO SHORT(LEN(c.buckets^))-1 DO c.buckets[i] := Empty END END;
    c.count := 0; c.allocated := 0; c.newest := Empty; c.oldest := Empty; c.free := Empty
  END Clear;

  PROCEDURE Configure*(VAR c: Cache; mib: INTEGER): INTEGER;
  BEGIN
    IF (mib < 0) OR (mib > MaxMiB) THEN RETURN -22 END;
    IF (c = NIL) & (mib = 0) THEN RETURN 0 END;
    IF c = NIL THEN NEW(c) END;
    (* Retain object identity: volume plans can share the same open image. *)
    c.budget := mib*1048576; c.blockSize := 0; c.capacity := 0;
    c.slots := NIL; c.buckets := NIL; c.data := NIL;
    c.hits := 0; c.misses := 0; c.evictions := 0; Clear(c);
    RETURN 0
  END Configure;

  PROCEDURE Prepare(c: Cache; offset: LONGINT; blockSize: INTEGER): BOOLEAN;
  BEGIN
    IF (c = NIL) OR (c.budget = 0) OR (offset < 0) THEN RETURN FALSE END;
    IF (blockSize # 1024) & (blockSize # 2048) & (blockSize # 4096) THEN RETURN FALSE END;
    IF c.blockSize # blockSize THEN
      c.blockSize := blockSize; c.capacity := c.budget DIV blockSize;
      NEW(c.slots, c.capacity); NEW(c.buckets, c.capacity*2+1);
      NEW(c.data, c.capacity*blockSize); Clear(c); c.alignment := SHORT(offset MOD blockSize)
    ELSIF c.alignment # offset MOD blockSize THEN
      Clear(c); c.alignment := SHORT(offset MOD blockSize)
    END;
    RETURN TRUE
  END Prepare;

  PROCEDURE Bucket(c: Cache; offset: LONGINT): INTEGER;
  BEGIN RETURN SHORT(offset DIV c.blockSize MOD LEN(c.buckets^)) END Bucket;

  PROCEDURE Find(c: Cache; offset: LONGINT): INTEGER;
    VAR slot: INTEGER;
  BEGIN
    slot := c.buckets[Bucket(c, offset)];
    WHILE (slot # Empty) & (c.slots[slot].offset # offset) DO slot := c.slots[slot].hashNext END;
    RETURN slot
  END Find;

  PROCEDURE Detach(c: Cache; slot: INTEGER);
    VAR previous, next: INTEGER;
  BEGIN
    previous := c.slots[slot].previous; next := c.slots[slot].next;
    IF previous = Empty THEN c.newest := next ELSE c.slots[previous].next := next END;
    IF next = Empty THEN c.oldest := previous ELSE c.slots[next].previous := previous END
  END Detach;

  PROCEDURE Recent(c: Cache; slot: INTEGER);
  BEGIN
    c.slots[slot].previous := Empty; c.slots[slot].next := c.newest;
    IF c.newest = Empty THEN c.oldest := slot ELSE c.slots[c.newest].previous := slot END;
    c.newest := slot
  END Recent;

  PROCEDURE Remove(c: Cache; slot: INTEGER);
    VAR bucket, previous, current: INTEGER;
  BEGIN
    bucket := Bucket(c, c.slots[slot].offset); previous := Empty; current := c.buckets[bucket];
    WHILE current # slot DO previous := current; current := c.slots[current].hashNext END;
    IF previous = Empty THEN c.buckets[bucket] := c.slots[slot].hashNext
    ELSE c.slots[previous].hashNext := c.slots[slot].hashNext END;
    Detach(c, slot); c.slots[slot].hashNext := c.free; c.free := slot; DEC(c.count)
  END Remove;

  PROCEDURE Get*(c: Cache; offset: LONGINT; blockSize: INTEGER; VAR data: ARRAY OF CHAR): BOOLEAN;
    VAR slot, base, i: INTEGER;
  BEGIN
    IF (LEN(data) < blockSize) OR ~Prepare(c, offset, blockSize) THEN RETURN FALSE END;
    slot := Find(c, offset);
    IF slot = Empty THEN IF c.misses < MAX(LONGINT) THEN INC(c.misses) END; RETURN FALSE END;
    IF c.hits < MAX(LONGINT) THEN INC(c.hits) END;
    IF slot # c.newest THEN Detach(c, slot); Recent(c, slot) END;
    base := slot*blockSize; FOR i := 0 TO blockSize-1 DO data[i] := c.data[base+i] END;
    RETURN TRUE
  END Get;

  PROCEDURE Put*(c: Cache; offset: LONGINT; blockSize: INTEGER; VAR data: ARRAY OF CHAR);
    VAR slot, bucket, base, i: INTEGER;
  BEGIN
    IF (LEN(data) < blockSize) OR ~Prepare(c, offset, blockSize) THEN RETURN END;
    slot := Find(c, offset);
    IF slot # Empty THEN Detach(c, slot)
    ELSE
      IF (c.free = Empty) & (c.allocated = c.capacity) THEN
        Remove(c, c.oldest); IF c.evictions < MAX(LONGINT) THEN INC(c.evictions) END
      END;
      IF c.free # Empty THEN slot := c.free; c.free := c.slots[slot].hashNext
      ELSE slot := c.allocated; INC(c.allocated) END;
      bucket := Bucket(c, offset); c.slots[slot].offset := offset;
      c.slots[slot].hashNext := c.buckets[bucket]; c.buckets[bucket] := slot; INC(c.count)
    END;
    Recent(c, slot); base := slot*blockSize;
    FOR i := 0 TO blockSize-1 DO c.data[base+i] := data[i] END
  END Put;

  PROCEDURE Invalidate*(c: Cache; offset: LONGINT; count: INTEGER);
    VAR first, last: LONGINT; slot: INTEGER;
  BEGIN
    IF (c = NIL) OR (c.blockSize = 0) OR (count <= 0) THEN RETURN END;
    IF (offset < 0) OR (offset > MAX(LONGINT)-count) THEN Clear(c); RETURN END;
    first := offset-((offset MOD c.blockSize-c.alignment) MOD c.blockSize);
    last := offset+count-1;
    WHILE first <= last DO
      IF first >= 0 THEN slot := Find(c, first); IF slot # Empty THEN Remove(c, slot) END END;
      IF last-first < c.blockSize THEN RETURN END;
      INC(first, c.blockSize)
    END
  END Invalidate;

  PROCEDURE Info*(c: Cache; VAR capacity, count, blockSize: INTEGER; VAR hits, misses, evictions: LONGINT);
  BEGIN
    capacity := 0; count := 0; blockSize := 0; hits := 0; misses := 0; evictions := 0;
    IF c # NIL THEN
      capacity := c.capacity; count := c.count; blockSize := c.blockSize;
      hits := c.hits; misses := c.misses; evictions := c.evictions
    END
  END Info;
END ReadCache.
