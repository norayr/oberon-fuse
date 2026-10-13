MODULE Diagnostics;
  (* Bounded, structured diagnostics. No printing or image writes. *)
  IMPORT DiskTypes;
  CONST
    MaxIssues* = 10000;
    HeaderRead* = 1; HeaderMagic* = 2; HeaderName* = 3;
    LengthRange* = 4; LengthShort* = 5; FirstBlock* = 6;
    BlockRead* = 7; Overlap* = 8; AllocationLimit* = 9;
    TreeRead* = 10; TreeMagic* = 11; TreeCount* = 12;
    TreeOccupancy* = 13; TreeCycle* = 14; TreeOrder* = 15;
    TreeDepth* = 16; TreeChildren* = 17; TreeName* = 18; FileLimit* = 19;

  PROCEDURE Clear*(VAR v: DiskTypes.Volume);
  BEGIN
    v.issues := NIL; v.lastIssue := NIL; v.issueCount := 0; v.storedIssues := 0
  END Clear;

  PROCEDURE Add*(VAR v: DiskTypes.Volume; code: INTEGER; name: ARRAY OF CHAR;
                 key, value1, value2: LONGINT);
    VAR p: DiskTypes.Issue;
  BEGIN
    INC(v.issueCount);
    IF v.storedIssues >= MaxIssues THEN RETURN END;
    NEW(p); p.next := NIL; p.code := code; COPY(name, p.name);
    p.key := key; p.value1 := value1; p.value2 := value2;
    IF v.issues = NIL THEN v.issues := p ELSE v.lastIssue.next := p END;
    v.lastIssue := p; INC(v.storedIssues)
  END Add;

  PROCEDURE Message*(code: INTEGER; VAR text: ARRAY OF CHAR);
  BEGIN
    CASE code OF
      HeaderRead: COPY("unreadable or invalid header address", text) |
      HeaderMagic: COPY("invalid file-header marker", text) |
      HeaderName: COPY("header name does not match directory", text) |
      LengthRange: COPY("file length exceeds format limits", text) |
      LengthShort: COPY("file length is shorter than its header", text) |
      FirstBlock: COPY("first direct address does not match header", text) |
      BlockRead: COPY("unreadable, missing or invalid block address", text) |
      Overlap: COPY("allocation overlaps another reference", text) |
      AllocationLimit: COPY("allocation checker resource limit", text) |
      TreeRead: COPY("unreadable directory page", text) |
      TreeMagic: COPY("invalid directory marker", text) |
      TreeCount: COPY("directory entry count exceeds capacity", text) |
      TreeOccupancy: COPY("underfull directory page", text) |
      TreeCycle: COPY("directory cycle or shared page", text) |
      TreeOrder: COPY("directory names are not strictly ordered", text) |
      TreeDepth: COPY("directory depth limit or unbalanced leaves", text) |
      TreeChildren: COPY("inconsistent directory child pointers", text) |
      TreeName: COPY("invalid directory filename", text) |
      FileLimit: COPY("directory file-count limit", text)
    ELSE COPY("unknown filesystem issue", text) END
  END Message;
END Diagnostics.
