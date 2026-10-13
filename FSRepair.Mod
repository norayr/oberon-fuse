MODULE FSRepair;
  (* Quarantine, never guess. Explicit in-place repair is for disposable copies. *)
  IMPORT DiskTypes, DiskBytes, BlockIO, FileSystem, FSCheck, BTreeRebuild,
    FSReports, ReportWriter, OberonBTree;

  PROCEDURE Copy(VAR source, output: BlockIO.Image): INTEGER;
    VAR b: ARRAY 65536 OF CHAR; offset: LONGINT; n, res: INTEGER;
  BEGIN
    offset := 0;
    WHILE offset < source.size DO
      n := LEN(b); IF n > source.size-offset THEN n := SHORT(source.size-offset) END;
      res := BlockIO.Read(source, offset, b, n); IF res # 0 THEN RETURN res END;
      res := BlockIO.Write(output, offset, b, n); IF res # 0 THEN RETURN res END;
      INC(offset, n)
    END;
    RETURN 0
  END Copy;

  PROCEDURE ReportPath*(output: ARRAY OF CHAR; VAR path: ARRAY OF CHAR): BOOLEAN;
    VAR suffix: ARRAY 12 OF CHAR; i, j: INTEGER;
  BEGIN
    suffix := ".repair.txt";
    i := 0;
    WHILE (i < LEN(output)) & (output[i] # 0X) DO
      IF i >= LEN(path)-LEN(suffix) THEN RETURN FALSE END;
      path[i] := output[i]; INC(i)
    END;
    IF i = LEN(output) THEN RETURN FALSE END;
    j := 0;
    REPEAT path[i+j] := suffix[j]; INC(j) UNTIL suffix[j-1] = 0X;
    RETURN TRUE
  END ReportPath;

  PROCEDURE InvalidateMap(VAR v: DiskTypes.Volume): INTEGER;
    VAR b: DiskTypes.Buffer; key, offset: LONGINT; res: INTEGER;
  BEGIN
    IF (v.kind = DiskTypes.Project) OR (v.kind = DiskTypes.Ceres) OR v.lastClaimed THEN RETURN 0 END;
    key := (v.limit-v.root) DIV v.blockSize*29;
    res := OberonBTree.GetBlock(v, key, b); IF res # 0 THEN RETURN res END;
    (* Invalidate only a recognized allocation-cache marker in an unclaimed block. *)
    IF (b[0] = 7FX) & (b[1] = 97X) & (b[2] = 2FX) & (b[3] = 9CX) THEN
      DiskBytes.Put32(b, 0, 0);
      IF ~OberonBTree.Offset(v, key, offset) THEN RETURN -5 END;
      RETURN BlockIO.Write(v.image, offset, b, 4)
    END;
    RETURN 0
  END InvalidateMap;

  PROCEDURE Apply(sourcePath, outputPath: ARRAY OF CHAR; kind: INTEGER; root: LONGINT;
                  inPlace: BOOLEAN; VAR work: DiskTypes.Volume): INTEGER;
    VAR plan: DiskTypes.Volume; report: ReportWriter.Writer;
      reportPath: ARRAY 2048 OF CHAR; count: LONGINT;
      res, closed, marked, kept: INTEGER;
  BEGIN
    IF ~work.treeValid OR ~work.checkComplete THEN RETURN -5 END;
    IF (work.usableCount # work.count) & ~BTreeRebuild.CanBuild(work) THEN RETURN -28 END;
    IF ~ReportPath(outputPath, reportPath) THEN RETURN -36 END;
    plan := work; kept := plan.usableCount;
    ReportWriter.Count(report); FSReports.Manifest(plan, sourcePath, outputPath, inPlace, report);
    count := report.position;
    res := ReportWriter.Create(report, reportPath, count); IF res # 0 THEN RETURN res END;
    FSReports.Manifest(plan, sourcePath, outputPath, inPlace, report); res := report.error;
    (* Persist the pending plan before any directory bytes are changed. *)
    IF res = 0 THEN res := BlockIO.Sync(report.image) END;
    IF (res = 0) & (kept # plan.count) THEN
      res := BTreeRebuild.Rebuild(work);
      IF res = 0 THEN res := InvalidateMap(plan) END
    END;
    IF res = 0 THEN
      res := FileSystem.Scan(work, kind, root, FALSE);
      IF res = 0 THEN res := FSCheck.Check(work) END;
      IF (res = 0) & (work.count # kept) THEN res := -5 END
    END;
    IF res = 0 THEN res := BlockIO.Sync(work.image) END;
    marked := FSReports.SetStatus(report, res = 0); IF res = 0 THEN res := marked END;
    closed := ReportWriter.Close(report); IF res = 0 THEN res := closed END;
    RETURN res
  END Apply;

  PROCEDURE InPlace*(path: ARRAY OF CHAR; kind: INTEGER; root: LONGINT;
                     VAR work: DiskTypes.Volume): INTEGER;
  BEGIN RETURN Apply(path, path, kind, root, TRUE, work) END InPlace;

  PROCEDURE Repair*(sourcePath, outputPath: ARRAY OF CHAR; kind: INTEGER; root: LONGINT;
                    VAR source: DiskTypes.Volume): INTEGER;
    VAR work: DiskTypes.Volume; res, checked, closed: INTEGER;
  BEGIN
    IF ~source.treeValid OR ~source.checkComplete THEN RETURN -5 END;
    IF (source.usableCount # source.count) & ~BTreeRebuild.CanBuild(source) THEN RETURN -28 END;
    res := BlockIO.Create(outputPath, source.image.size, work.image); IF res # 0 THEN RETURN res END;
    res := Copy(source.image, work.image);
    IF res = 0 THEN res := FileSystem.Scan(work, kind, root, TRUE) END;
    IF res = 0 THEN
      checked := FSCheck.Check(work);
      IF ~work.checkComplete THEN res := checked END
    END;
    (* Recheck the copied snapshot rather than trusting stale source records. *)
    IF res = 0 THEN res := Apply(sourcePath, outputPath, kind, root, FALSE, work) END;
    closed := BlockIO.Close(work.image); IF res = 0 THEN res := closed END;
    RETURN res
  END Repair;
END FSRepair.
