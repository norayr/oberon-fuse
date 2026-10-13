MODULE FSWrite;
  (* Checked copy-on-write files and directory children; fixed root published last.
     No claim of power-loss atomicity: a torn fixed-root write still needs recovery. *)
  IMPORT Host, BlockIO, DiskBytes, DiskTypes, DiskTime, WriteBitmap,
    OberonBTree, FSCheck, BTreeRebuild, AllocationCache;
  CONST MaxFiles = 100000;

  PROCEDURE ValidName(VAR v: DiskTypes.Volume; name: ARRAY OF CHAR): BOOLEAN;
    VAR i: INTEGER;
  BEGIN
    IF (name = "") OR (name = ".") OR (name = "..") THEN RETURN FALSE END;
    i := 0;
    WHILE (i < LEN(name)) & (name[i] # 0X) DO
      IF (i >= v.nameBytes-1) OR (name[i] < " ") OR (name[i] = "/") THEN RETURN FALSE END;
      INC(i)
    END;
    RETURN i < LEN(name)
  END ValidName;

  PROCEDURE Key(VAR v: DiskTypes.Volume; key: LONGINT; release: BOOLEAN): INTEGER;
  BEGIN
    IF release THEN WriteBitmap.Free(v.allocation, key)
    ELSIF ~WriteBitmap.Use(v.allocation, key) THEN RETURN -5 END;
    RETURN 0
  END Key;

  PROCEDURE Allocations(VAR v: DiskTypes.Volume; e: DiskTypes.Entry; release: BOOLEAN): INTEGER;
    VAR super, table: DiskTypes.Buffer; n, indexes, index, slot, slots, key: LONGINT; res: INTEGER;
  BEGIN
    res := Key(v, e.key, release); IF res # 0 THEN RETURN res END;
    n := 1;
    WHILE (n < e.blocks) & (n < v.directCount) DO
      res := Key(v, e.direct[SHORT(n)], release); IF res # 0 THEN RETURN res END; INC(n)
    END;
    IF e.blocks <= v.directCount THEN RETURN 0 END;
    indexes := (e.blocks-v.directCount+v.blockSize DIV 4-1) DIV (v.blockSize DIV 4);
    IF v.doubleIndirect THEN
      res := OberonBTree.GetBlock(v, e.extension, super); IF res # 0 THEN RETURN res END;
      res := Key(v, e.extension, release); IF res # 0 THEN RETURN res END
    END;
    n := v.directCount;
    FOR index := 0 TO indexes-1 DO
      IF v.doubleIndirect THEN key := DiskBytes.U32(super, SHORT(index)*4)
      ELSE key := e.index[SHORT(index)] END;
      res := OberonBTree.GetBlock(v, key, table); IF res # 0 THEN RETURN res END;
      res := Key(v, key, release); IF res # 0 THEN RETURN res END;
      slots := e.blocks-n; IF slots > v.blockSize DIV 4 THEN slots := v.blockSize DIV 4 END;
      FOR slot := 0 TO slots-1 DO
        res := Key(v, DiskBytes.U32(table, SHORT(slot)*4), release); IF res # 0 THEN RETURN res END
      END;
      INC(n, slots)
    END;
    RETURN 0
  END Allocations;

  PROCEDURE Init*(VAR v: DiskTypes.Volume): INTEGER;
    VAR p: DiskTypes.Page; e: DiskTypes.Entry; res: INTEGER;
  BEGIN
    res := FSCheck.Check(v); IF res # 0 THEN RETURN res END;
    res := WriteBitmap.Init(v.allocation, (v.limit-v.root) DIV v.blockSize); IF res # 0 THEN RETURN res END;
    p := v.pages;
    WHILE p # NIL DO res := Key(v, p.key, FALSE); IF res # 0 THEN RETURN res END; p := p.next END;
    e := v.first;
    WHILE e # NIL DO
      res := Allocations(v, e, FALSE); IF res # 0 THEN RETURN res END;
      e.diskSize := e.size; e.diskModified := e.modified; e := e.next
    END;
    res := AllocationCache.Invalidate(v);
    IF res = 0 THEN res := BlockIO.Sync(v.image) END;
    IF res = 0 THEN v.writable := TRUE; v.failed := FALSE END;
    RETURN res
  END Init;

  PROCEDURE Maximum*(VAR v: DiskTypes.Volume): LONGINT;
    VAR blocks: LONGINT;
  BEGIN
    IF v.doubleIndirect THEN blocks := v.directCount+LONG(v.blockSize DIV 4)*(v.blockSize DIV 4)
    ELSE blocks := v.directCount+12*(v.blockSize DIV 4) END;
    RETURN blocks*v.blockSize-v.headerSize
  END Maximum;

  PROCEDURE Writable(VAR v: DiskTypes.Volume): INTEGER;
  BEGIN IF v.failed THEN RETURN -5 ELSIF ~v.writable THEN RETURN -30 ELSE RETURN 0 END END Writable;

  PROCEDURE Stage(VAR v: DiskTypes.Volume; e: DiskTypes.Entry): INTEGER;
    VAR b: DiskTypes.Buffer; offset: LONGINT; n, res, ignored: INTEGER;
  BEGIN
    IF e.staged THEN RETURN 0 END;
    res := BlockIO.Scratch(e.stage); IF res # 0 THEN RETURN res END;
    res := BlockIO.Resize(e.stage, e.size); offset := 0;
    WHILE (res = 0) & (offset < e.size) DO
      n := v.blockSize; IF n > e.size-offset THEN n := SHORT(e.size-offset) END;
      res := OberonBTree.Read(v, e, offset, b, n);
      IF res = n THEN res := BlockIO.Write(e.stage, offset, b, n)
      ELSIF res >= 0 THEN res := -5 END;
      INC(offset, n)
    END;
    IF res # 0 THEN ignored := BlockIO.Close(e.stage) ELSE e.staged := TRUE END;
    RETURN res
  END Stage;

  PROCEDURE Read*(VAR v: DiskTypes.Volume; e: DiskTypes.Entry; pos: LONGINT;
                  VAR data: ARRAY OF CHAR; count: INTEGER): INTEGER;
    VAR res: INTEGER;
  BEGIN
    IF v.failed THEN RETURN -5 END;
    IF ~e.staged THEN RETURN OberonBTree.Read(v, e, pos, data, count) END;
    IF (pos < 0) OR (count < 0) OR (count > LEN(data)) THEN RETURN -22 END;
    IF pos >= e.size THEN RETURN 0 END;
    IF count > e.size-pos THEN count := SHORT(e.size-pos) END;
    res := BlockIO.Read(e.stage, pos, data, count); IF res # 0 THEN RETURN res END;
    RETURN count
  END Read;

  PROCEDURE Touch(VAR v: DiskTypes.Volume; e: DiskTypes.Entry; value: LONGINT): INTEGER;
    VAR date, time: LONGINT;
  BEGIN
    IF ~DiskTime.Encode(v.kind, value, v.utcOffset, date, time) THEN RETURN -75 END;
    e.modified := value; e.timeValid := TRUE; e.dirty := TRUE; RETURN 0
  END Touch;

  PROCEDURE Write*(VAR v: DiskTypes.Volume; e: DiskTypes.Entry; pos: LONGINT;
                   VAR data: ARRAY OF CHAR; count: INTEGER): INTEGER;
    VAR res: INTEGER; size, now, date, time: LONGINT;
  BEGIN
    res := Writable(v); IF res # 0 THEN RETURN res END;
    IF (pos < 0) OR (count < 0) OR (count > LEN(data)) THEN RETURN -22 END;
    IF (pos > Maximum(v)) OR (count > Maximum(v)-pos) THEN RETURN -27 END;
    IF count = 0 THEN RETURN 0 END;
    now := Host.Now(); IF ~DiskTime.Encode(v.kind, now, v.utcOffset, date, time) THEN RETURN -75 END;
    res := Stage(v, e); IF res # 0 THEN RETURN res END;
    size := pos+count;
    IF size > e.size THEN res := BlockIO.Resize(e.stage, size); IF res # 0 THEN RETURN res END END;
    res := BlockIO.Write(e.stage, pos, data, count); IF res # 0 THEN RETURN res END;
    IF size > e.size THEN e.size := size END;
    res := Touch(v, e, now); IF res # 0 THEN RETURN res END;
    RETURN count
  END Write;

  PROCEDURE Resize*(VAR v: DiskTypes.Volume; e: DiskTypes.Entry; size: LONGINT): INTEGER;
    VAR res: INTEGER; now, date, time: LONGINT;
  BEGIN
    res := Writable(v); IF res # 0 THEN RETURN res END;
    IF size < 0 THEN RETURN -22 ELSIF size > Maximum(v) THEN RETURN -27 END;
    now := Host.Now(); IF ~DiskTime.Encode(v.kind, now, v.utcOffset, date, time) THEN RETURN -75 END;
    res := Stage(v, e); IF res = 0 THEN res := BlockIO.Resize(e.stage, size) END;
    IF res = 0 THEN e.size := size; res := Touch(v, e, now) END;
    RETURN res
  END Resize;

  PROCEDURE Time*(VAR v: DiskTypes.Volume; e: DiskTypes.Entry; value: LONGINT): INTEGER;
    VAR res: INTEGER; date, time: LONGINT;
  BEGIN
    res := Writable(v); IF res # 0 THEN RETURN res END;
    IF ~DiskTime.Encode(v.kind, value, v.utcOffset, date, time) THEN RETURN -75 END;
    res := Stage(v, e); IF res = 0 THEN res := Touch(v, e, value) END;
    RETURN res
  END Time;

  PROCEDURE Acquire(VAR v: DiskTypes.Volume; VAR acquired: DiskTypes.Page): LONGINT;
    VAR p: DiskTypes.Page; key: LONGINT;
  BEGIN
    key := WriteBitmap.Allocate(v.allocation); IF key = 0 THEN RETURN 0 END;
    NEW(p); p.key := key; p.next := acquired; acquired := p; RETURN key
  END Acquire;

  PROCEDURE Rollback(VAR v: DiskTypes.Volume; acquired: DiskTypes.Page);
  BEGIN WHILE acquired # NIL DO WriteBitmap.Free(v.allocation, acquired.key); acquired := acquired.next END END Rollback;

  PROCEDURE Put(VAR v: DiskTypes.Volume; key: LONGINT; VAR b: DiskTypes.Buffer): INTEGER;
    VAR offset: LONGINT;
  BEGIN
    IF ~OberonBTree.Offset(v, key, offset) THEN RETURN -5 END;
    RETURN BlockIO.Write(v.image, offset, b, v.blockSize)
  END Put;

  PROCEDURE Zero(VAR b: DiskTypes.Buffer);
    VAR i: INTEGER;
  BEGIN FOR i := 0 TO LEN(b)-1 DO b[i] := 0X END END Zero;

  PROCEDURE File(VAR v: DiskTypes.Volume; e: DiskTypes.Entry; VAR acquired: DiskTypes.Page): INTEGER;
    VAR keys, tables: POINTER TO ARRAY OF LONGINT; b, data, header: DiskTypes.Buffer;
      n, total, indexes, index, slot, offset, count, required: LONGINT; i, start, res: INTEGER;
  BEGIN
    Zero(header);
    IF e.key # 0 THEN res := OberonBTree.GetBlock(v, e.key, header); IF res # 0 THEN RETURN res END END;
    total := v.headerSize+e.size; e.blocks := (total+v.blockSize-1) DIV v.blockSize;
    e.aleng := e.blocks-1; e.bleng := total-e.aleng*v.blockSize;
    IF e.timeValid & ~DiskTime.Encode(v.kind, e.modified, v.utcOffset, e.date, e.time) THEN RETURN -75 END;
    NEW(keys, SHORT(e.blocks)); indexes := 0;
    IF e.blocks > v.directCount THEN indexes := (e.blocks-v.directCount+v.blockSize DIV 4-1) DIV (v.blockSize DIV 4) END;
    required := e.blocks+indexes;
    IF v.doubleIndirect & (indexes > 0) THEN INC(required) END;
    IF required > v.allocation.free THEN RETURN -28 END;
    FOR n := 0 TO e.blocks-1 DO keys[SHORT(n)] := Acquire(v, acquired); IF keys[SHORT(n)] = 0 THEN RETURN -28 END END;
    FOR i := 0 TO LEN(e.direct)-1 DO e.direct[i] := 0 END;
    FOR i := 0 TO LEN(e.index)-1 DO e.index[i] := 0 END;
    e.extension := 0; e.key := keys[0];
    FOR n := 0 TO e.blocks-1 DO
      IF n < v.directCount THEN e.direct[SHORT(n)] := keys[SHORT(n)] END
    END;
    IF indexes > 0 THEN NEW(tables, SHORT(indexes)) END;
    FOR index := 0 TO indexes-1 DO
      tables[SHORT(index)] := Acquire(v, acquired); IF tables[SHORT(index)] = 0 THEN RETURN -28 END;
      IF ~v.doubleIndirect THEN e.index[SHORT(index)] := tables[SHORT(index)] END;
      Zero(b); slot := 0; n := v.directCount+index*(v.blockSize DIV 4);
      WHILE (slot < v.blockSize DIV 4) & (n+slot < e.blocks) DO
        DiskBytes.Put32(b, SHORT(slot)*4, keys[SHORT(n+slot)]); INC(slot)
      END;
      res := Put(v, tables[SHORT(index)], b); IF res # 0 THEN RETURN res END
    END;
    IF v.doubleIndirect & (indexes > 0) THEN
      e.extension := Acquire(v, acquired); IF e.extension = 0 THEN RETURN -28 END;
      Zero(b); FOR index := 0 TO indexes-1 DO DiskBytes.Put32(b, SHORT(index)*4, tables[SHORT(index)]) END;
      res := Put(v, e.extension, b); IF res # 0 THEN RETURN res END
    END;
    offset := 0;
    FOR n := 0 TO e.blocks-1 DO
      Zero(b); start := 0;
      IF n = 0 THEN
        FOR i := 0 TO v.headerSize-1 DO b[i] := header[i] END;
        b[0] := 86X; b[1] := 1DX; b[2] := 0A7X; b[3] := 9BX;
        FOR i := 0 TO v.nameBytes-1 DO b[4+i] := 0X END;
        i := 0; WHILE e.name[i] # 0X DO b[4+i] := e.name[i]; INC(i) END;
        i := v.nameBytes+4;
        IF v.shortLengths THEN DiskBytes.Put16(b, i, e.aleng); DiskBytes.Put16(b, i+2, e.bleng)
        ELSE DiskBytes.Put32(b, i, e.aleng); DiskBytes.Put32(b, i+4, e.bleng) END;
        DiskTime.Store(v, e, b);
        FOR i := 0 TO v.directCount-1 DO DiskBytes.Put32(b, v.directOffset+i*4, e.direct[i]) END;
        IF v.doubleIndirect THEN DiskBytes.Put32(b, v.indexOffset, e.extension)
        ELSE FOR i := 0 TO 11 DO DiskBytes.Put32(b, v.indexOffset+i*4, e.index[i]) END END;
        start := v.headerSize
      END;
      count := v.blockSize-start; IF count > e.size-offset THEN count := e.size-offset END;
      res := BlockIO.Read(e.stage, offset, data, SHORT(count)); IF res # 0 THEN RETURN res END;
      FOR i := 0 TO SHORT(count)-1 DO b[start+i] := data[i] END;
      res := Put(v, keys[SHORT(n)], b); IF res # 0 THEN RETURN res END; INC(offset, count)
    END;
    e.diskSize := e.size; e.diskModified := e.modified; e.headerIssue := 0; e.dataIssue := 0; e.usable := TRUE;
    RETURN 0
  END File;

  PROCEDURE Insert(VAR v: DiskTypes.Volume; e: DiskTypes.Entry);
    VAR p, before: DiskTypes.Entry;
  BEGIN
    before := NIL; p := v.first;
    WHILE (p # NIL) & (p.name < e.name) DO before := p; p := p.next END;
    e.next := p;
    IF before = NIL THEN v.first := e ELSE before.next := e END;
    IF p = NIL THEN v.last := e END;
    INC(v.count)
  END Insert;

  PROCEDURE Remove(VAR v: DiskTypes.Volume; e: DiskTypes.Entry);
    VAR p, before: DiskTypes.Entry;
  BEGIN
    before := NIL; p := v.first;
    WHILE (p # NIL) & (p # e) DO before := p; p := p.next END;
    IF p = NIL THEN RETURN END;
    IF before = NIL THEN v.first := p.next ELSE before.next := p.next END;
    IF v.last = p THEN v.last := before END;
    p.next := NIL; DEC(v.count)
  END Remove;

  PROCEDURE DiscardStage*(VAR v: DiskTypes.Volume; e: DiskTypes.Entry): INTEGER;
    VAR res: INTEGER;
  BEGIN
    IF ~e.staged THEN RETURN 0 END;
    res := BlockIO.Close(e.stage); e.staged := FALSE;
    IF e.dirty THEN
      e.size := e.diskSize; e.modified := e.diskModified;
      e.timeValid := DiskTime.Decode(v.kind, e.date, e.time, v.utcOffset, e.modified)
    END;
    e.dirty := FALSE; RETURN res
  END DiscardStage;

  PROCEDURE Retire(VAR v: DiskTypes.Volume; e: DiskTypes.Entry): INTEGER;
    VAR res, closed: INTEGER;
  BEGIN
    e.deleted := TRUE;
    IF e.opens # 0 THEN RETURN 0 END;
    res := Allocations(v, e, TRUE); closed := DiscardStage(v, e); IF res = 0 THEN res := closed END;
    RETURN res
  END Retire;

  PROCEDURE Publish(VAR v: DiskTypes.Volume; e, fresh, replaced: DiskTypes.Entry;
                    VAR acquired: DiskTypes.Page): INTEGER;
    VAR plan: DiskTypes.Volume; source, clone, previous: DiskTypes.Entry;
      pool, p, oldPages: DiskTypes.Page; pages, i, res: INTEGER; key: LONGINT;
  BEGIN
    plan := v; plan.first := NIL; plan.last := NIL; plan.count := 0;
    source := v.first;
    WHILE source # NIL DO
      IF (source # e) & (source # replaced) THEN NEW(clone); clone^ := source^; Insert(plan, clone) END;
      source := source.next
    END;
    IF fresh # NIL THEN NEW(clone); clone^ := fresh^; Insert(plan, clone) END;
    plan.usableCount := plan.count; pages := BTreeRebuild.PageCount(plan, plan.count);
    IF (pages < 1) OR (pages-1 > v.allocation.free) THEN RETURN -28 END;
    NEW(pool); pool.key := 29; pool.next := NIL;
    FOR i := 1 TO pages-1 DO
      key := Acquire(v, acquired); IF key = 0 THEN RETURN -28 END;
      NEW(p); p.key := key; p.next := pool; pool := p
    END;
    plan.pages := pool; plan.treeValid := TRUE; plan.checkComplete := TRUE;
    (* Check the new allocation plan before publishing any new directory root. *)
    res := FSCheck.Check(plan); IF res # 0 THEN RETURN res END;
    res := BTreeRebuild.Rebuild(plan);
    IF res = 0 THEN res := BlockIO.Sync(v.image) END;
    IF res # 0 THEN v.failed := TRUE; RETURN res END;
    oldPages := v.pages; v.pages := pool;
    WHILE oldPages # NIL DO
      IF oldPages.key # 29 THEN WriteBitmap.Free(v.allocation, oldPages.key) END;
      oldPages := oldPages.next
    END;
    IF e # NIL THEN
      IF fresh # NIL THEN
        NEW(previous); previous^ := e^;
        Remove(v, e); e^ := fresh^; e.dirty := FALSE; e.deleted := FALSE; Insert(v, e);
        IF previous.key # 0 THEN res := Allocations(v, previous, TRUE) END
      ELSE Remove(v, e); res := Retire(v, e) END
    END;
    IF (res = 0) & (replaced # NIL) THEN Remove(v, replaced); res := Retire(v, replaced) END;
    v.usableCount := v.count; v.checkComplete := TRUE; v.treeValid := TRUE;
    IF res # 0 THEN v.failed := TRUE END;
    RETURN res
  END Publish;

  PROCEDURE Flush*(VAR v: DiskTypes.Volume; e: DiskTypes.Entry): INTEGER;
    VAR fresh: DiskTypes.Entry; acquired: DiskTypes.Page; res: INTEGER;
  BEGIN
    res := Writable(v); IF res # 0 THEN RETURN res END;
    IF ~e.dirty OR e.deleted THEN RETURN 0 END;
    acquired := NIL; NEW(fresh); fresh^ := e^;
    res := File(v, fresh, acquired);
    IF res = 0 THEN res := Publish(v, e, fresh, NIL, acquired) END;
    IF res # 0 THEN Rollback(v, acquired) END;
    RETURN res
  END Flush;

  PROCEDURE New*(VAR v: DiskTypes.Volume; name: ARRAY OF CHAR; VAR e: DiskTypes.Entry): INTEGER;
    VAR res, closed: INTEGER; existing: DiskTypes.Entry;
  BEGIN
    e := NIL; res := Writable(v); IF res # 0 THEN RETURN res END;
    IF ~ValidName(v, name) THEN RETURN -22 END;
    existing := v.first;
    WHILE existing # NIL DO IF existing.name = name THEN RETURN -17 END; existing := existing.next END;
    IF v.count >= MaxFiles THEN RETURN -27 END;
    NEW(e); COPY(name, e.name); e.usable := TRUE;
    res := BlockIO.Scratch(e.stage);
    IF res = 0 THEN e.staged := TRUE; res := Touch(v, e, Host.Now()) END;
    IF res = 0 THEN res := Flush(v, e) END;
    IF res # 0 THEN closed := DiscardStage(v, e); e := NIL END;
    RETURN res
  END New;

  PROCEDURE Delete*(VAR v: DiskTypes.Volume; e: DiskTypes.Entry): INTEGER;
    VAR acquired: DiskTypes.Page; res: INTEGER;
  BEGIN
    res := Writable(v); IF res # 0 THEN RETURN res END;
    acquired := NIL; res := Publish(v, e, NIL, NIL, acquired);
    IF res # 0 THEN Rollback(v, acquired) END;
    RETURN res
  END Delete;

  PROCEDURE Rename*(VAR v: DiskTypes.Volume; e: DiskTypes.Entry; name: ARRAY OF CHAR;
                    replaced: DiskTypes.Entry): INTEGER;
    VAR fresh: DiskTypes.Entry; acquired: DiskTypes.Page; res: INTEGER;
  BEGIN
    res := Writable(v); IF res # 0 THEN RETURN res END;
    IF e = replaced THEN RETURN 0 END;
    IF ~ValidName(v, name) THEN RETURN -22 END;
    res := Stage(v, e); IF res # 0 THEN RETURN res END;
    acquired := NIL; NEW(fresh); fresh^ := e^; COPY(name, fresh.name);
    res := File(v, fresh, acquired);
    IF res = 0 THEN res := Publish(v, e, fresh, replaced, acquired) END;
    IF res # 0 THEN Rollback(v, acquired) END;
    RETURN res
  END Rename;

  PROCEDURE Close*(VAR v: DiskTypes.Volume; e: DiskTypes.Entry): INTEGER;
    VAR res, closed: INTEGER;
  BEGIN
    res := 0;
    IF ~e.deleted & e.dirty THEN res := Flush(v, e) END;
    IF e.opens > 0 THEN DEC(e.opens) END;
    IF e.opens = 0 THEN
      IF e.deleted THEN closed := Allocations(v, e, TRUE) ELSE closed := 0 END;
      IF res = 0 THEN res := closed END;
      closed := DiscardStage(v, e); IF res = 0 THEN res := closed END
    END;
    RETURN res
  END Close;

  PROCEDURE Sync*(VAR v: DiskTypes.Volume): INTEGER;
    VAR e: DiskTypes.Entry; res: INTEGER;
  BEGIN
    res := Writable(v); IF res # 0 THEN RETURN res END;
    e := v.first;
    WHILE e # NIL DO res := Flush(v, e); IF res # 0 THEN RETURN res END; e := e.next END;
    RETURN BlockIO.Sync(v.image)
  END Sync;
END FSWrite.
