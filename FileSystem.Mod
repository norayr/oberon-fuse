MODULE FileSystem;
  IMPORT BlockIO, DiskTypes, DetectFS, OberonBTree, FSCheck, Diagnostics;

  PROCEDURE Scan*(VAR v: DiskTypes.Volume; kind: INTEGER; root: LONGINT; tolerant: BOOLEAN): INTEGER;
    VAR res: INTEGER;
  BEGIN
    v.salvage := FALSE; v.treeValid := FALSE; v.checkComplete := FALSE; v.utcOffset := 0;
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
    RETURN OberonBTree.Read(v, e, offset, data, count)
  END Read;

  PROCEDURE Close*(VAR v: DiskTypes.Volume): INTEGER;
  BEGIN
    v.first := NIL; v.last := NIL; v.pages := NIL;
    RETURN BlockIO.Close(v.image)
  END Close;
END FileSystem.
