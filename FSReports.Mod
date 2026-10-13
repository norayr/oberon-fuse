MODULE FSReports;
  IMPORT DiskTypes, Diagnostics, OberonBTree, ReportWriter, Formats, BlockIO;

  PROCEDURE Issues*(VAR v: DiskTypes.Volume; VAR w: ReportWriter.Writer);
    VAR p: DiskTypes.Issue; text: ARRAY 160 OF CHAR; offset: LONGINT;
  BEGIN
    p := v.issues;
    WHILE p # NIL DO
      Diagnostics.Message(p.code, text);
      ReportWriter.Text(w, "ERROR"); ReportWriter.Char(w, 9X);
      ReportWriter.Text(w, p.name); ReportWriter.Char(w, 9X);
      ReportWriter.Text(w, text); ReportWriter.Text(w, " [address="); ReportWriter.Number(w, p.key);
      IF OberonBTree.Offset(v, p.key, offset) THEN
        ReportWriter.Text(w, ", offset="); ReportWriter.Number(w, offset)
      END;
      IF (p.code = Diagnostics.LengthShort) OR (p.code = Diagnostics.LengthRange) THEN
        ReportWriter.Text(w, ", aleng="); ReportWriter.Number(w, p.value1);
        ReportWriter.Text(w, ", bleng="); ReportWriter.Number(w, p.value2)
      ELSE ReportWriter.Text(w, ", position="); ReportWriter.Number(w, p.value1) END;
      ReportWriter.Text(w, "]"); ReportWriter.Line(w); p := p.next
    END;
    IF v.issueCount > v.storedIssues THEN
      ReportWriter.Text(w, "Additional issues omitted from report: ");
      ReportWriter.Number(w, v.issueCount-v.storedIssues); ReportWriter.Line(w)
    END;
    ReportWriter.Text(w, "issues: "); ReportWriter.Number(w, v.issueCount); ReportWriter.Line(w);
    IF v.checkComplete THEN
      ReportWriter.Text(w, "usable files: "); ReportWriter.Number(w, v.usableCount);
      ReportWriter.Text(w, " of "); ReportWriter.Number(w, v.count); ReportWriter.Line(w)
    END
  END Issues;

  PROCEDURE Print*(VAR v: DiskTypes.Volume): INTEGER;
    VAR w: ReportWriter.Writer;
  BEGIN ReportWriter.Console(w); Issues(v, w); RETURN w.error END Print;

  PROCEDURE RepairPlan*(VAR v: DiskTypes.Volume; VAR w: ReportWriter.Writer);
    VAR e: DiskTypes.Entry; offset: LONGINT;
  BEGIN
    Issues(v, w);
    ReportWriter.Text(w, "Policy: remove unusable directory entries; do not infer lengths or rewrite file data.");
    ReportWriter.Line(w);
    e := v.first;
    WHILE e # NIL DO
      IF ~e.usable THEN
        ReportWriter.Text(w, "DROP"); ReportWriter.Char(w, 9X); ReportWriter.Text(w, e.name);
        ReportWriter.Text(w, " [header address="); ReportWriter.Number(w, e.key);
        IF OberonBTree.Offset(v, e.key, offset) THEN
          ReportWriter.Text(w, ", offset="); ReportWriter.Number(w, offset)
        END;
        ReportWriter.Text(w, "]"); ReportWriter.Line(w)
      END;
      e := e.next
    END;
    ReportWriter.Text(w, "keep: "); ReportWriter.Number(w, v.usableCount);
    ReportWriter.Text(w, "; drop: "); ReportWriter.Number(w, v.count-v.usableCount); ReportWriter.Line(w)
  END RepairPlan;

  PROCEDURE Manifest*(VAR v: DiskTypes.Volume; source, output: ARRAY OF CHAR;
                      inPlace: BOOLEAN; VAR w: ReportWriter.Writer);
    VAR format: ARRAY 16 OF CHAR;
  BEGIN
    (* The eight-byte status at offset 8 is updated only after verification. *)
    ReportWriter.Text(w, "status: pending "); ReportWriter.Line(w);
    IF inPlace THEN ReportWriter.Text(w, "mode: in-place")
    ELSE ReportWriter.Text(w, "mode: new-copy") END;
    ReportWriter.Line(w);
    ReportWriter.Text(w, "source: "); ReportWriter.Text(w, source); ReportWriter.Line(w);
    ReportWriter.Text(w, "output: "); ReportWriter.Text(w, output); ReportWriter.Line(w);
    Formats.Name(v.kind, format);
    ReportWriter.Text(w, "format: "); ReportWriter.Text(w, format); ReportWriter.Line(w);
    ReportWriter.Text(w, "root offset: "); ReportWriter.Number(w, v.root); ReportWriter.Line(w);
    IF inPlace THEN
      ReportWriter.Text(w, "This working image is modified in place. Keep a separate original for recovery.")
    ELSE
      ReportWriter.Text(w, "Original image is read-only. Excluded entries and available data remain in the original.")
    END;
    ReportWriter.Line(w);
    ReportWriter.Text(w, "Unreachable blocks in the repaired image may be reused by later filesystem writes.");
    ReportWriter.Line(w);
    RepairPlan(v, w)
  END Manifest;

  PROCEDURE SetStatus*(VAR w: ReportWriter.Writer; success: BOOLEAN): INTEGER;
    VAR text: ARRAY 9 OF CHAR;
  BEGIN
    IF success THEN text := "complete" ELSE text := "failed  " END;
    RETURN BlockIO.Write(w.image, 8, text, 8)
  END SetStatus;
END FSReports.
