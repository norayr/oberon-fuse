MODULE BTreeRebuild;
  (* Rebuild from verified entries, reusing only known directory pages. *)
  IMPORT DiskTypes, DiskBytes, BlockIO, OberonBTree;
  TYPE Bounds = ARRAY 33 OF LONGINT;

  PROCEDURE Limits(VAR v: DiskTypes.Volume; count: INTEGER;
                   VAR minimum, maximum: Bounds): INTEGER;
    VAR height, half: INTEGER;
  BEGIN
    half := v.dirCapacity DIV 2; minimum[0] := half; maximum[0] := v.dirCapacity;
    height := 0;
    WHILE maximum[height] < count DO
      IF height = LEN(minimum)-1 THEN RETURN -1 END;
      minimum[height+1] := (half+1)*minimum[height]+half;
      maximum[height+1] := (v.dirCapacity+1)*maximum[height]+v.dirCapacity;
      INC(height)
    END;
    RETURN height
  END Limits;

  PROCEDURE Entries(VAR v: DiskTypes.Volume; count: LONGINT; height: INTEGER;
                    root: BOOLEAN; VAR minimum, maximum: Bounds): INTEGER;
    VAR k: INTEGER;
  BEGIN
    IF height = 0 THEN
      IF count > v.dirCapacity THEN RETURN -1 END;
      IF ~root & (count < v.dirCapacity DIV 2) THEN RETURN -1 END;
      RETURN SHORT(count)
    END;
    IF root THEN k := 1 ELSE k := v.dirCapacity DIV 2 END;
    WHILE k <= v.dirCapacity DO
      IF (count-k >= (k+1)*minimum[height-1]) &
         (count-k <= (k+1)*maximum[height-1]) THEN RETURN k END;
      INC(k)
    END;
    RETURN -1
  END Entries;

  PROCEDURE Needed(VAR v: DiskTypes.Volume; count: LONGINT; height: INTEGER;
                   root: BOOLEAN; VAR minimum, maximum: Bounds): INTEGER;
    VAR k, i, total, n: INTEGER; base, rest, childCount: LONGINT;
  BEGIN
    k := Entries(v, count, height, root, minimum, maximum);
    IF k < 0 THEN RETURN -1 END;
    total := 1;
    IF height > 0 THEN
      base := (count-k) DIV (k+1); rest := (count-k) MOD (k+1);
      FOR i := 0 TO k DO
        childCount := base; IF i < rest THEN INC(childCount) END;
        n := Needed(v, childCount, height-1, FALSE, minimum, maximum);
        IF n < 0 THEN RETURN -1 END;
        INC(total, n)
      END
    END;
    RETURN total
  END Needed;

  PROCEDURE CanBuild*(VAR v: DiskTypes.Volume): BOOLEAN;
    VAR minimum, maximum: Bounds; p: DiskTypes.Page; height, available, needed: INTEGER;
  BEGIN
    IF ~v.treeValid OR ~v.checkComplete THEN RETURN FALSE END;
    height := Limits(v, v.usableCount, minimum, maximum); IF height < 0 THEN RETURN FALSE END;
    needed := Needed(v, v.usableCount, height, TRUE, minimum, maximum);
    available := 0; p := v.pages;
    WHILE p # NIL DO INC(available); p := p.next END;
    RETURN (needed > 0) & (needed <= available)
  END CanBuild;

  PROCEDURE NextUsable(VAR e: DiskTypes.Entry);
  BEGIN WHILE (e # NIL) & ~e.usable DO e := e.next END END NextUsable;

  PROCEDURE Build(VAR v: DiskTypes.Volume; count: LONGINT; height: INTEGER; root: BOOLEAN;
                  VAR minimum, maximum: Bounds; VAR e: DiskTypes.Entry;
                  VAR pool: DiskTypes.Page; VAR key: LONGINT): INTEGER;
    VAR b: DiskTypes.Buffer; child, childCount, base, rest, offset: LONGINT;
      k, i, j, slot, res: INTEGER;
  BEGIN
    IF root THEN key := 29
    ELSE
      WHILE (pool # NIL) & (pool.key = 29) DO pool := pool.next END;
      IF pool = NIL THEN RETURN -28 END;
      key := pool.key; pool := pool.next
    END;
    k := Entries(v, count, height, root, minimum, maximum); IF k < 0 THEN RETURN -5 END;
    FOR i := 0 TO LEN(b)-1 DO b[i] := 0X END;
    DiskTypes.MarkDirectory(b);
    IF v.shortCount THEN DiskBytes.Put16(b, 4, k) ELSE DiskBytes.Put32(b, 4, k) END;
    base := 0; rest := 0;
    IF height > 0 THEN base := (count-k) DIV (k+1); rest := (count-k) MOD (k+1) END;
    FOR i := 0 TO k DO
      child := 0;
      IF height > 0 THEN
        childCount := base; IF i < rest THEN INC(childCount) END;
        res := Build(v, childCount, height-1, FALSE, minimum, maximum, e, pool, child);
        IF res # 0 THEN RETURN res END
      END;
      IF i = 0 THEN DiskBytes.Put32(b, 8, child)
      ELSE DiskBytes.Put32(b, v.dirOffset+(i-1)*(v.nameBytes+8)+v.nameBytes+4, child) END;
      IF i < k THEN
        NextUsable(e); IF e = NIL THEN RETURN -5 END;
        slot := v.dirOffset+i*(v.nameBytes+8); j := 0;
        WHILE (j < v.nameBytes) & (e.name[j] # 0X) DO b[slot+j] := e.name[j]; INC(j) END;
        IF j = v.nameBytes THEN RETURN -5 END;
        DiskBytes.Put32(b, slot+v.nameBytes, e.key); e := e.next
      END
    END;
    IF ~OberonBTree.Offset(v, key, offset) THEN RETURN -5 END;
    RETURN BlockIO.Write(v.image, offset, b, v.blockSize)
  END Build;

  PROCEDURE Rebuild*(VAR v: DiskTypes.Volume): INTEGER;
    VAR minimum, maximum: Bounds; pool: DiskTypes.Page; e: DiskTypes.Entry;
      height, res: INTEGER; key: LONGINT;
  BEGIN
    IF ~CanBuild(v) THEN RETURN -28 END;
    height := Limits(v, v.usableCount, minimum, maximum);
    pool := v.pages; e := v.first;
    res := Build(v, v.usableCount, height, TRUE, minimum, maximum, e, pool, key);
    IF res = 0 THEN NextUsable(e); IF e # NIL THEN RETURN -5 END END;
    RETURN res
  END Rebuild;
END BTreeRebuild.
