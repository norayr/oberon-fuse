MODULE DiskTypes;
  IMPORT BlockIO, WriteBitmap;
  CONST
    Project* = 1; Native* = 2; Ceres* = 3; Aos1* = 4; Aos2* = 5;
  TYPE
    Name* = ARRAY 128 OF CHAR;
    Buffer* = ARRAY 4096 OF CHAR;
    Page* = POINTER TO PageDesc;
    PageDesc* = RECORD next*: Page; key*: LONGINT END;
    Entry* = POINTER TO EntryDesc;
    EntryDesc* = RECORD
      next*: Entry;
      name*: Name;
      key*, size*, blocks*: LONGINT;
      aleng*, bleng*: LONGINT;
      date*, time*, modified*: LONGINT;
      timeValid*: BOOLEAN;
      diskSize*, diskModified*: LONGINT;
      stage*: BlockIO.Image;
      staged*, dirty*, deleted*: BOOLEAN;
      opens*: INTEGER;
      headerIssue*, dataIssue*: INTEGER;
      usable*: BOOLEAN;
      direct*: ARRAY 128 OF LONGINT;
      index*: ARRAY 12 OF LONGINT;
      extension*: LONGINT
    END;
    Issue* = POINTER TO IssueDesc;
    IssueDesc* = RECORD
      next*: Issue;
      code*: INTEGER;
      name*: Name;
      key*, value1*, value2*: LONGINT
    END;
    Volume* = RECORD
      image*: BlockIO.Image;
      kind*, blockSize*, headerSize*, nameBytes*: INTEGER;
      dirOffset*, dirCapacity*, directOffset*, directCount*, indexOffset*: INTEGER;
      shortCount*, shortLengths*, doubleIndirect*: BOOLEAN;
      root*, limit*: LONGINT;
      first*, last*: Entry;
      pages*: Page;
      count*: INTEGER;
      usableCount*, issueCount*, storedIssues*, checkedReferences*: INTEGER;
      issues*, lastIssue*: Issue;
      treeValid*, checkComplete*, lastClaimed*, salvage*: BOOLEAN;
      utcOffset*: INTEGER;
      writable*, failed*: BOOLEAN;
      allocation*: WriteBitmap.Map;
      error*: ARRAY 160 OF CHAR
    END;

  PROCEDURE Append*(VAR v: Volume; e: Entry);
  BEGIN
    e.next := NIL;
    IF v.first = NIL THEN v.first := e ELSE v.last.next := e END;
    v.last := e; INC(v.count)
  END Append;

  PROCEDURE IsDirectory*(VAR b: Buffer): BOOLEAN;
  BEGIN RETURN (b[0] = 8DX) & (b[1] = 0A3X) & (b[2] = 1EX) & (b[3] = 9BX) END IsDirectory;

  PROCEDURE IsHeader*(VAR b: Buffer): BOOLEAN;
  BEGIN RETURN (b[0] = 86X) & (b[1] = 1DX) & (b[2] = 0A7X) & (b[3] = 9BX) END IsHeader;

  PROCEDURE MarkDirectory*(VAR b: Buffer);
  BEGIN b[0] := 8DX; b[1] := 0A3X; b[2] := 1EX; b[3] := 9BX END MarkDirectory;
END DiskTypes.
