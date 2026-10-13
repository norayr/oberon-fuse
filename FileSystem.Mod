MODULE FileSystem;
  IMPORT BlockIO, DiskTypes, DiskTime, DetectFS, OberonBTree, FSCheck, Diagnostics, FSWrite;

  PROCEDURE Scan*(VAR v: DiskTypes.Volume; kind: INTEGER; root: LONGINT; tolerant: BOOLEAN): INTEGER;
    VAR res: INTEGER;
  BEGIN
    v.salvage := FALSE; v.treeValid := FALSE; v.checkComplete := FALSE; v.utcOffset := 0;
    v.writable := FALSE; v.failed := FALSE;
    v.first := NIL; v.last := NIL; v.pages := NIL; v.count := 0; v.usableCount := 0;
    Diagnostics.Clear(v);
    v.error := "locating filesystem (try an explicit format and root offset)";
    res := DetectFS.Locate(v, kind, root);
    IF res = 0 THEN v.error := "reading directory or file header"; res := OberonBTree.Load(v, tolerant) END;
    RETURN res
  END Scan;

  PROCEDURE OpenReport*(path: ARRAY OF CHAR; kind: INTEGER; root: LONGINT; VAR v: DiskTypes.Volume): INTEGER;
    VAR res, ignored: INTEGER;
  BEGIN
    v.error := "opening image"; Diagnostics.Clear(v);
    res := BlockIO.Open(path, v.image); IF res # 0 THEN RETURN res END;
    res := Scan(v, kind, root, TRUE);
    IF res # 0 THEN ignored := BlockIO.Close(v.image) END;
    RETURN res
  END OpenReport;

  PROCEDURE OpenDeviceReport*(path: ARRAY OF CHAR; kind: INTEGER; root: LONGINT; VAR v: DiskTypes.Volume): INTEGER;
    VAR res, ignored: INTEGER;
  BEGIN
    v.error := "opening block device for inspection"; Diagnostics.Clear(v);
    res := BlockIO.OpenDevice(path, FALSE, v.image); IF res # 0 THEN RETURN res END;
    res := Scan(v, kind, root, TRUE);
    IF res # 0 THEN ignored := BlockIO.Close(v.image) END;
    RETURN res
  END OpenDeviceReport;

  PROCEDURE OpenUpdate*(path: ARRAY OF CHAR; kind: INTEGER; root: LONGINT; VAR v: DiskTypes.Volume): INTEGER;
    VAR res, ignored: INTEGER;
  BEGIN
    v.error := "opening working image for exclusive update"; Diagnostics.Clear(v);
    res := BlockIO.OpenUpdate(path, v.image); IF res # 0 THEN RETURN res END;
    res := Scan(v, kind, root, TRUE);
    IF res # 0 THEN ignored := BlockIO.Close(v.image) END;
    RETURN res
  END OpenUpdate;

  PROCEDURE OpenSalvage*(path: ARRAY OF CHAR; kind: INTEGER; root: LONGINT; VAR v: DiskTypes.Volume): INTEGER;
    VAR res, ignored: INTEGER;
  BEGIN
    res := OpenReport(path, kind, root, v); IF res # 0 THEN RETURN res END;
    res := FSCheck.Check(v);
    IF ~v.checkComplete THEN ignored := BlockIO.Close(v.image); RETURN res END;
    v.salvage := TRUE;
    RETURN 0
  END OpenSalvage;

  PROCEDURE Open*(path: ARRAY OF CHAR; kind: INTEGER; root: LONGINT; VAR v: DiskTypes.Volume): INTEGER;
    VAR res, ignored: INTEGER;
  BEGIN
    v.error := "opening image";
    Diagnostics.Clear(v);
    res := BlockIO.Open(path, v.image); IF res # 0 THEN RETURN res END;
    res := Scan(v, kind, root, FALSE);
    IF res # 0 THEN ignored := BlockIO.Close(v.image) END;
    RETURN res
  END Open;

  PROCEDURE OpenCachedMount*(path: ARRAY OF CHAR; kind: INTEGER; root: LONGINT;
                            device, writable, salvage: BOOLEAN; offset, cacheMiB: INTEGER;
                            VAR v: DiskTypes.Volume): INTEGER;
    VAR res, ignored: INTEGER; e: DiskTypes.Entry;
  BEGIN
    v.error := "opening volume"; Diagnostics.Clear(v);
    IF (offset < -1440) OR (offset > 1440) OR (writable & salvage) THEN RETURN -22 END;
    IF device THEN res := BlockIO.OpenDevice(path, writable, v.image)
    ELSIF writable THEN res := BlockIO.OpenUpdate(path, v.image)
    ELSE res := BlockIO.Open(path, v.image) END;
    IF res # 0 THEN RETURN res END;
    res := BlockIO.ConfigureCache(v.image, cacheMiB);
    IF res # 0 THEN ignored := BlockIO.Close(v.image); RETURN res END;
    res := Scan(v, kind, root, salvage);
    v.utcOffset := offset; e := v.first;
    WHILE e # NIL DO
      e.timeValid := DiskTime.Decode(v.kind, e.date, e.time, offset, e.modified);
      e.diskModified := e.modified; e := e.next
    END;
    IF (res = 0) & writable THEN v.error := "checking writable volume"; res := FSWrite.Init(v)
    ELSIF (res = 0) & salvage THEN
      res := FSCheck.Check(v); IF v.checkComplete THEN v.salvage := TRUE; res := 0 END
    END;
    IF res # 0 THEN ignored := BlockIO.Close(v.image) END;
    RETURN res
  END OpenCachedMount;

  PROCEDURE OpenMount*(path: ARRAY OF CHAR; kind: INTEGER; root: LONGINT;
                       device, writable, salvage: BOOLEAN; offset: INTEGER;
                       VAR v: DiskTypes.Volume): INTEGER;
  BEGIN RETURN OpenCachedMount(path, kind, root, device, writable, salvage, offset, 0, v) END OpenMount;

  PROCEDURE Find*(VAR v: DiskTypes.Volume; name: ARRAY OF CHAR): DiskTypes.Entry;
    VAR e: DiskTypes.Entry;
  BEGIN
    e := v.first;
    WHILE (e # NIL) & (e.name # name) DO e := e.next END;
    RETURN e
  END Find;

  PROCEDURE FindPath*(VAR v: DiskTypes.Volume; path: ARRAY OF CHAR): DiskTypes.Entry;
    VAR name: DiskTypes.Name; i: INTEGER;
  BEGIN
    IF (LEN(path) < 2) OR (path[0] # "/") THEN RETURN NIL END;
    i := 1;
    WHILE (i < LEN(path)) & (i <= LEN(name)) DO
      IF path[i] = 0X THEN name[i-1] := 0X; RETURN Find(v, name) END;
      IF (i = LEN(name)) OR (path[i] = "/") THEN RETURN NIL END;
      name[i-1] := path[i]; INC(i)
    END;
    RETURN NIL
  END FindPath;

  PROCEDURE Read*(VAR v: DiskTypes.Volume; e: DiskTypes.Entry; offset: LONGINT;
                  VAR data: ARRAY OF CHAR; count: INTEGER): INTEGER;
  BEGIN
    IF e = NIL THEN RETURN -2 END;
    IF (e.headerIssue # 0) OR (v.salvage & ~e.usable) THEN RETURN -5 END;
    COPY(e.name, v.error);
    RETURN FSWrite.Read(v, e, offset, data, count)
  END Read;

  PROCEDURE Close*(VAR v: DiskTypes.Volume): INTEGER;
    VAR e: DiskTypes.Entry; res, closed: INTEGER;
  BEGIN
    res := 0;
    IF v.writable THEN res := FSWrite.Sync(v) END;
    e := v.first;
    WHILE e # NIL DO closed := FSWrite.DiscardStage(v, e); IF res = 0 THEN res := closed END; e := e.next END;
    v.first := NIL; v.last := NIL; v.pages := NIL;
    closed := BlockIO.Close(v.image); IF res = 0 THEN res := closed END;
    RETURN res
  END Close;
END FileSystem.
