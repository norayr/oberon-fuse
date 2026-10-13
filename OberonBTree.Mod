MODULE OberonBTree;
  IMPORT BlockIO, DiskBytes, DiskTypes, BlockSet, Diagnostics, DiskTime;
  CONST MaxDepth = 32; MaxFiles = 100000;

  PROCEDURE Offset*(VAR v: DiskTypes.Volume; key: LONGINT; VAR offset: LONGINT): BOOLEAN;
  BEGIN
    IF (v.blockSize <= 0) OR (v.root < 0) OR (v.limit < v.root) THEN RETURN FALSE END;
    IF (key <= 0) OR (key MOD 29 # 0) THEN RETURN FALSE END;
    IF key DIV 29-1 > (v.limit-v.root) DIV v.blockSize THEN RETURN FALSE END;
    offset := v.root+(key DIV 29-1)*v.blockSize;
    RETURN (offset <= v.limit) & (v.blockSize <= v.limit-offset)
  END Offset;

  PROCEDURE GetBlock*(VAR v: DiskTypes.Volume; key: LONGINT; VAR b: DiskTypes.Buffer): INTEGER;
    VAR offset: LONGINT;
  BEGIN
    IF ~Offset(v, key, offset) THEN RETURN -5 END;
    RETURN BlockIO.Read(v.image, offset, b, v.blockSize)
  END GetBlock;

  PROCEDURE Header(VAR v: DiskTypes.Volume; e: DiskTypes.Entry): INTEGER;
    VAR b: DiskTypes.Buffer; name: DiskTypes.Name;
      a, z, maximum: LONGINT; i, res, offset: INTEGER;
  BEGIN
    COPY(e.name, v.error);
    e.aleng := 0; e.bleng := 0; e.size := 0; e.blocks := 0;
    res := GetBlock(v, e.key, b); IF res # 0 THEN RETURN Diagnostics.HeaderRead END;
    IF ~DiskTypes.IsHeader(b) THEN RETURN Diagnostics.HeaderMagic END;
    IF ~DiskBytes.Name(b, 4, v.nameBytes, name) OR (name # e.name) THEN RETURN Diagnostics.HeaderName END;
    DiskTime.Load(v, e, b);
    offset := v.nameBytes+4;
    IF v.shortLengths THEN a := DiskBytes.U16(b, offset); z := DiskBytes.U16(b, offset+2)
    ELSE a := DiskBytes.U32(b, offset); z := DiskBytes.U32(b, offset+4) END;
    IF v.doubleIndirect THEN maximum := v.directCount+LONG(v.blockSize DIV 4)*(v.blockSize DIV 4)
    ELSE maximum := v.directCount+12*(v.blockSize DIV 4) END;
    e.aleng := a; e.bleng := z;
    IF (a >= maximum) OR (z > v.blockSize) THEN RETURN Diagnostics.LengthRange END;
    e.size := a*v.blockSize+z-v.headerSize;
    IF e.size < 0 THEN e.size := 0; RETURN Diagnostics.LengthShort END;
    (* aleng names the final allocated block, even when bleng is zero. *)
    e.blocks := a+1;
    FOR i := 0 TO v.directCount-1 DO e.direct[i] := DiskBytes.U32(b, v.directOffset+i*4) END;
    IF e.direct[0] # e.key THEN RETURN Diagnostics.FirstBlock END;
    IF v.doubleIndirect THEN e.extension := DiskBytes.U32(b, v.indexOffset)
    ELSE FOR i := 0 TO 11 DO e.index[i] := DiskBytes.U32(b, v.indexOffset+i*4) END END;
    RETURN 0
  END Header;

  PROCEDURE TreeError(VAR v: DiskTypes.Volume; code: INTEGER; key, detail: LONGINT): INTEGER;
  BEGIN
    v.error := "directory structure";
    Diagnostics.Add(v, code, "directory", key, detail, 0);
    RETURN -5
  END TreeError;

  PROCEDURE Walk(VAR v: DiskTypes.Volume; key: LONGINT; depth: INTEGER;
                 VAR seen: BlockSet.Set; VAR leafDepth: INTEGER; tolerant: BOOLEAN): INTEGER;
    VAR b: DiskTypes.Buffer; e: DiskTypes.Entry; page: DiskTypes.Page;
      child, count: LONGINT; i, offset, res: INTEGER; branch: BOOLEAN;
  BEGIN
    v.error := "directory page (cycle, bounds, ordering, or entry count)";
    IF depth > MaxDepth THEN RETURN TreeError(v, Diagnostics.TreeDepth, key, depth) END;
    IF ~BlockSet.Add(seen, key) THEN RETURN TreeError(v, Diagnostics.TreeCycle, key, 0) END;
    res := GetBlock(v, key, b); IF res # 0 THEN RETURN TreeError(v, Diagnostics.TreeRead, key, 0) END;
    IF ~DiskTypes.IsDirectory(b) THEN RETURN TreeError(v, Diagnostics.TreeMagic, key, 0) END;
    IF v.shortCount THEN count := DiskBytes.U16(b, 4) ELSE count := DiskBytes.U32(b, 4) END;
    IF count > v.dirCapacity THEN RETURN TreeError(v, Diagnostics.TreeCount, key, count) END;
    IF (depth > 0) & (count < v.dirCapacity DIV 2) THEN RETURN TreeError(v, Diagnostics.TreeOccupancy, key, count) END;
    NEW(page); page.key := key; page.next := v.pages; v.pages := page;
    child := DiskBytes.U32(b, 8);
    branch := child # 0;
    IF branch & (count = 0) THEN RETURN TreeError(v, Diagnostics.TreeChildren, key, 0) END;
    IF ~branch THEN
      IF leafDepth < 0 THEN leafDepth := depth
      ELSIF leafDepth # depth THEN RETURN TreeError(v, Diagnostics.TreeDepth, key, depth) END
    END;
    IF child # 0 THEN
      res := Walk(v, child, depth+1, seen, leafDepth, tolerant); IF res # 0 THEN RETURN res END
    END;
    FOR i := 0 TO SHORT(count)-1 DO
      IF v.count >= MaxFiles THEN RETURN TreeError(v, Diagnostics.FileLimit, key, v.count) END;
      offset := v.dirOffset+i*(v.nameBytes+8);
      NEW(e);
      IF ~DiskBytes.Name(b, offset, v.nameBytes, e.name) OR
         (e.name = ".") OR (e.name = "..") THEN RETURN TreeError(v, Diagnostics.TreeName, key, i) END;
      IF (v.last # NIL) & (e.name <= v.last.name) THEN RETURN TreeError(v, Diagnostics.TreeOrder, key, i) END;
      e.key := DiskBytes.U32(b, offset+v.nameBytes);
      e.headerIssue := Header(v, e); e.dataIssue := 0; e.usable := e.headerIssue = 0;
      IF e.headerIssue # 0 THEN
        Diagnostics.Add(v, e.headerIssue, e.name, e.key, e.aleng, e.bleng);
        IF ~tolerant THEN RETURN -5 END
      END;
      DiskTypes.Append(v, e);
      child := DiskBytes.U32(b, offset+v.nameBytes+4);
      IF branch # (child # 0) THEN RETURN TreeError(v, Diagnostics.TreeChildren, key, i) END;
      IF child # 0 THEN
        res := Walk(v, child, depth+1, seen, leafDepth, tolerant); IF res # 0 THEN RETURN res END
      END
    END;
    RETURN 0
  END Walk;

  PROCEDURE Load*(VAR v: DiskTypes.Volume; tolerant: BOOLEAN): INTEGER;
    VAR seen: BlockSet.Set; leafDepth, res: INTEGER;
  BEGIN
    v.first := NIL; v.last := NIL; v.pages := NIL; v.count := 0;
    v.treeValid := FALSE; v.checkComplete := FALSE; v.usableCount := 0;
    Diagnostics.Clear(v);
    BlockSet.Init(seen);
    leafDepth := -1;
    res := Walk(v, 29, 0, seen, leafDepth, tolerant);
    v.treeValid := res = 0;
    RETURN res
  END Load;

  PROCEDURE DataKey*(VAR v: DiskTypes.Volume; e: DiskTypes.Entry; number: LONGINT; VAR key: LONGINT): INTEGER;
    VAR b: DiskTypes.Buffer; index, slot: LONGINT; res: INTEGER;
  BEGIN
    IF number < 0 THEN RETURN -22 END;
    IF number < v.directCount THEN key := e.direct[SHORT(number)]; RETURN 0 END;
    number := number-v.directCount;
    index := number DIV (v.blockSize DIV 4); slot := number MOD (v.blockSize DIV 4);
    IF v.doubleIndirect THEN
      IF index >= v.blockSize DIV 4 THEN RETURN -5 END;
      res := GetBlock(v, e.extension, b); IF res # 0 THEN RETURN res END;
      key := DiskBytes.U32(b, SHORT(index)*4)
    ELSE
      IF index >= 12 THEN RETURN -5 END;
      key := e.index[SHORT(index)]
    END;
    res := GetBlock(v, key, b); IF res # 0 THEN RETURN res END;
    key := DiskBytes.U32(b, SHORT(slot)*4);
    RETURN 0
  END DataKey;

  PROCEDURE Read*(VAR v: DiskTypes.Volume; e: DiskTypes.Entry; offset: LONGINT;
                  VAR dest: ARRAY OF CHAR; count: INTEGER): INTEGER;
    VAR b: DiskTypes.Buffer; pos, key: LONGINT; done, n, within, i, res: INTEGER;
  BEGIN
    IF (offset < 0) OR (count < 0) OR (count > LEN(dest)) THEN RETURN -22 END;
    IF offset >= e.size THEN RETURN 0 END;
    IF count > e.size-offset THEN count := SHORT(e.size-offset) END;
    done := 0;
    WHILE done < count DO
      pos := offset+done+v.headerSize;
      res := DataKey(v, e, pos DIV v.blockSize, key);
      IF res = 0 THEN res := GetBlock(v, key, b) END;
      IF res # 0 THEN RETURN res END;
      within := SHORT(pos MOD v.blockSize); n := v.blockSize-within;
      IF n > count-done THEN n := count-done END;
      FOR i := 0 TO n-1 DO dest[done+i] := b[within+i] END;
      INC(done, n)
    END;
    RETURN done
  END Read;
END OberonBTree.
