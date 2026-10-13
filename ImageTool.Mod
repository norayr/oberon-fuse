MODULE ImageTool;
  IMPORT Modules, Out, Host, DiskBytes, DiskTypes, Formats, CommandLine,
    FileSystem, ImageCreate, FSCheck, FSReports, FSRepair, ReportWriter;

  PROCEDURE Usage;
  BEGIN
    Host.Error("usage: oberon-image info|list|check IMAGE [FORMAT [ROOT-OFFSET]]");
    Host.Error("       oberon-image cat IMAGE NAME [FORMAT [ROOT-OFFSET]]");
    Host.Error("       oberon-image read IMAGE NAME OFFSET COUNT [FORMAT [ROOT-OFFSET]]");
    Host.Error("       oberon-image create FORMAT hdd|floppy|raw OUTPUT [SIZE-MiB]");
    Host.Error("       oberon-image mkfs FORMAT OUTPUT SIZE-MiB");
    Host.Error("       oberon-image mkfs FORMAT IMAGE --in-place [raw|hdd|floppy]");
    Host.Error("       oberon-image repair-plan IMAGE [FORMAT [ROOT-OFFSET]]");
    Host.Error("       oberon-image repair IMAGE NEW-IMAGE --drop-invalid [FORMAT [ROOT-OFFSET]]");
    Host.Error("       oberon-image repair IMAGE --in-place --drop-invalid [FORMAT [ROOT-OFFSET]]");
    Host.Error("--in-place modifies an existing regular file: use only an unmounted working copy");
    Host.Error("inspection also accepts --salvage before FORMAT; check scans all files in a valid tree");
    Host.Error("formats: project, natfs, ceres, aos1, aos2; inspection defaults to auto");
    Host.Exit(2)
  END Usage;

  PROCEDURE Run;
    VAR command, path, name, container, text, output: ARRAY 1024 OF CHAR;
      reportPath: ARRAY 2048 OF CHAR; w: ReportWriter.Writer;
      v: DiskTypes.Volume; e: DiskTypes.Entry; b: DiskTypes.Buffer;
      kind, first, res, closed, n, printed: INTEGER; size, root, pos, remaining: LONGINT;
      salvage, inPlace: BOOLEAN;
  BEGIN
    IF Modules.ArgCount < 3 THEN Usage END;
    Modules.GetArg(1, command);
    IF (command = "create") OR (command = "mkfs") THEN
      inPlace := FALSE;
      IF command = "create" THEN
        IF (Modules.ArgCount < 5) OR (Modules.ArgCount > 6) THEN Usage END;
        Modules.GetArg(2, text); kind := Formats.Kind(text);
        Modules.GetArg(3, container); Modules.GetArg(4, path);
        IF container = "floppy" THEN size := 1474560 ELSE size := 64*1048576 END;
        IF Modules.ArgCount = 6 THEN
          Modules.GetArg(5, text);
          IF ~DiskBytes.Number(text, size) OR (size > MAX(LONGINT) DIV 1048576) THEN Usage END;
          size := size*1048576
        END
      ELSE
        IF (Modules.ArgCount < 5) OR (Modules.ArgCount > 6) THEN Usage END;
        Modules.GetArg(2, text); kind := Formats.Kind(text); container := "raw";
        Modules.GetArg(3, path); Modules.GetArg(4, text);
        IF text = "--in-place" THEN
          inPlace := TRUE;
          IF Modules.ArgCount = 6 THEN Modules.GetArg(5, container) END
        ELSE
          IF Modules.ArgCount # 5 THEN Usage END;
          IF ~DiskBytes.Number(text, size) OR (size > MAX(LONGINT) DIV 1048576) THEN Usage END;
          size := size*1048576
        END
      END;
      IF kind <= 0 THEN Usage END;
      IF inPlace THEN res := ImageCreate.FormatExisting(path, container, kind)
      ELSE res := ImageCreate.Create(path, container, kind, size) END;
      IF res # 0 THEN
        IF inPlace THEN Host.Report("formatting existing working image", res)
        ELSE Host.Report("creating image", res) END;
        Host.Exit(1)
      END;
      RETURN
    END;
    IF (command # "info") & (command # "list") & (command # "cat") &
       (command # "read") & (command # "check") &
       (command # "repair-plan") & (command # "repair") THEN Usage END;
    Modules.GetArg(2, path); first := 3; pos := 0; remaining := 0; inPlace := FALSE;
    IF (command = "cat") OR (command = "read") THEN
      IF Modules.ArgCount < 4 THEN Usage END;
      Modules.GetArg(3, name); first := 4
    END;
    IF command = "read" THEN
      IF Modules.ArgCount < 6 THEN Usage END;
      Modules.GetArg(4, text); IF ~DiskBytes.Number(text, pos) THEN Usage END;
      Modules.GetArg(5, text); IF ~DiskBytes.Number(text, remaining) THEN Usage END;
      first := 6
    END;
    IF command = "repair" THEN
      IF Modules.ArgCount < 5 THEN Usage END;
      Modules.GetArg(3, output); Modules.GetArg(4, text);
      IF text # "--drop-invalid" THEN Usage END;
      inPlace := output = "--in-place";
      IF inPlace THEN COPY(path, output) END;
      first := 5
    END;
    IF ~CommandLine.Options(first, kind, root, salvage) THEN Usage END;
    IF salvage & ((command = "check") OR (command = "repair-plan") OR (command = "repair")) THEN Usage END;
    IF inPlace THEN res := FileSystem.OpenUpdate(path, kind, root, v)
    ELSIF (command = "check") OR (command = "repair-plan") OR (command = "repair") THEN
      res := FileSystem.OpenReport(path, kind, root, v)
    ELSIF salvage THEN res := FileSystem.OpenSalvage(path, kind, root, v)
    ELSE res := FileSystem.Open(path, kind, root, v) END;
    IF res # 0 THEN
      IF v.issueCount > 0 THEN printed := FSReports.Print(v) END;
      Host.Report(v.error, res); Host.Exit(1)
    END;
    IF command = "info" THEN
      Formats.Name(v.kind, text); Out.String("format: "); Out.String(text); Out.Ln;
      Out.String("block size: "); Out.Int(v.blockSize, 0); Out.Ln;
      Out.String("root offset: "); Out.Int(v.root, 0); Out.Ln;
      Out.String("files: "); Out.Int(v.count, 0); Out.Ln;
      IF salvage THEN
        Out.String("usable files: "); Out.Int(v.usableCount, 0); Out.Ln;
        Out.String("issues: "); Out.Int(v.issueCount, 0); Out.Ln
      END
    ELSIF command = "list" THEN
      e := v.first;
      WHILE e # NIL DO
        IF ~salvage OR e.usable THEN Out.Int(e.size, 0); Out.Char(9X); Out.String(e.name); Out.Ln END;
        e := e.next
      END
    ELSIF command = "check" THEN
      res := FSCheck.Check(v);
      IF res = 0 THEN Out.String("OK: directory, headers, block addresses and allocation overlaps"); Out.Ln
      ELSE printed := FSReports.Print(v) END
    ELSIF (command = "repair-plan") OR (command = "repair") THEN
      res := FSCheck.Check(v);
      IF ~v.checkComplete THEN
        printed := FSReports.Print(v)
      ELSIF command = "repair-plan" THEN
        ReportWriter.Console(w); FSReports.RepairPlan(v, w); res := w.error
      ELSE
        IF inPlace THEN res := FSRepair.InPlace(path, kind, root, v)
        ELSE res := FSRepair.Repair(path, output, kind, root, v) END;
        IF res = 0 THEN
          IF inPlace THEN Out.String("In-place repair verified: ")
          ELSE Out.String("Repaired copy verified: ") END;
          Out.String(output); Out.Ln;
          IF FSRepair.ReportPath(output, reportPath) THEN
            Out.String("Repair report: "); Out.String(reportPath); Out.Ln
          END
        ELSE
          IF inPlace THEN v.error := "repairing working image in place (existing report, unsafe plan, or I/O failure)"
          ELSE v.error := "repairing new copy (existing output/report, unsafe plan, or I/O failure)" END
        END
      END
    ELSE
      e := FileSystem.Find(v, name);
      IF e = NIL THEN v.error := "file not found"; res := -2
      ELSIF (e.headerIssue # 0) OR (salvage & ~e.usable) THEN COPY(e.name, v.error); res := -5
      ELSE
        IF command = "cat" THEN remaining := e.size END;
        IF pos >= e.size THEN remaining := 0
        ELSIF remaining > e.size-pos THEN remaining := e.size-pos END;
        WHILE (remaining > 0) & (res = 0) DO
          n := LEN(b); IF remaining < n THEN n := SHORT(remaining) END;
          n := FileSystem.Read(v, e, pos, b, n);
          IF n <= 0 THEN res := -5
          ELSE res := Host.Output(b, n); INC(pos, n); DEC(remaining, n) END
        END
      END
    END;
    closed := FileSystem.Close(v); IF res = 0 THEN res := closed END;
    IF res # 0 THEN Host.Report(v.error, res); Host.Exit(1) END
  END Run;
BEGIN Run
END ImageTool.
