MODULE FSCheck;
  (* Check every reachable allocation; keep checking after per-file failures. *)
  IMPORT DiskTypes, DiskBytes, OberonBTree, Diagnostics, AllocationMap;
  CONST MaxWork = 2097152;

  PROCEDURE Bad(VAR v: DiskTypes.Volume; e: DiskTypes.Entry; code: INTEGER; key, number: LONGINT);
  BEGIN
    IF e # NIL THEN
      e.usable := FALSE;
      IF e.dataIssue = 0 THEN e.dataIssue := code END;
      Diagnostics.Add(v, code, e.name, key, number, 0)
    ELSE Diagnostics.Add(v, code, "directory", key, number, 0) END
  END Bad;

  PROCEDURE Budget(VAR v: DiskTypes.Volume; e: DiskTypes.Entry; key, number: LONGINT): BOOLEAN;
  BEGIN
    IF ~v.checkComplete THEN RETURN FALSE END;
    IF v.checkedReferences >= MaxWork THEN
      v.checkComplete := FALSE; Bad(v, e, Diagnostics.AllocationLimit, key, number);
      RETURN FALSE
    END;
    INC(v.checkedReferences); RETURN TRUE
  END Budget;

  PROCEDURE Claim(VAR v: DiskTypes.Volume; VAR used: AllocationMap.Map;
                  e: DiskTypes.Entry; key, number: LONGINT);
    VAR other: DiskTypes.Entry; res: INTEGER;
  BEGIN
    IF ~Budget(v, e, key, number) THEN RETURN END;
    IF key = (v.limit-v.root) DIV v.blockSize*29 THEN v.lastClaimed := TRUE END;
    res := AllocationMap.Claim(used, key, e, other);
    IF res = 1 THEN
      Bad(v, e, Diagnostics.Overlap, key, number);
      IF (other # NIL) & (other # e) THEN Bad(v, other, Diagnostics.Overlap, key, -1) END
    ELSIF res # 0 THEN
      v.checkComplete := FALSE; Bad(v, e, Diagnostics.AllocationLimit, key, number)
    END
  END Claim;

  PROCEDURE Data(VAR v: DiskTypes.Volume; VAR used: AllocationMap.Map;
                 e: DiskTypes.Entry; key, number: LONGINT);
    VAR b: DiskTypes.Buffer;
  BEGIN
    IF ~Budget(v, e, key, number) THEN RETURN END;
    IF OberonBTree.GetBlock(v, key, b) # 0 THEN Bad(v, e, Diagnostics.BlockRead, key, number)
    ELSE Claim(v, used, e, key, number) END
  END Data;

  PROCEDURE File(VAR v: DiskTypes.Volume; VAR used: AllocationMap.Map; e: DiskTypes.Entry);
    VAR super, table: DiskTypes.Buffer; n, indexes, index, slots, slot, key: LONGINT;
  BEGIN
    n := 1;
    WHILE (n < e.blocks) & (n < v.directCount) & v.checkComplete DO
      Data(v, used, e, e.direct[SHORT(n)], n); INC(n)
    END;
    IF (e.blocks <= v.directCount) OR ~v.checkComplete THEN RETURN END;
    indexes := (e.blocks-v.directCount+v.blockSize DIV 4-1) DIV (v.blockSize DIV 4);
    IF v.doubleIndirect THEN
      IF ~Budget(v, e, e.extension, -1) THEN RETURN END;
      IF OberonBTree.GetBlock(v, e.extension, super) # 0 THEN
        Bad(v, e, Diagnostics.BlockRead, e.extension, -1); RETURN
      END;
      Claim(v, used, e, e.extension, -1)
    END;
    index := 0; n := v.directCount;
    WHILE (index < indexes) & v.checkComplete DO
      IF v.doubleIndirect THEN key := DiskBytes.U32(super, SHORT(index)*4)
      ELSE key := e.index[SHORT(index)] END;
      slots := e.blocks-n;
      IF slots > v.blockSize DIV 4 THEN slots := v.blockSize DIV 4 END;
      IF ~Budget(v, e, key, n) THEN RETURN END;
      IF OberonBTree.GetBlock(v, key, table) # 0 THEN Bad(v, e, Diagnostics.BlockRead, key, n)
      ELSE
        Claim(v, used, e, key, n);
        slot := 0;
        WHILE (slot < slots) & v.checkComplete DO
          Data(v, used, e, DiskBytes.U32(table, SHORT(slot)*4), n+slot); INC(slot)
        END
      END;
      INC(n, slots); INC(index)
    END
  END File;

  PROCEDURE Check*(VAR v: DiskTypes.Volume): INTEGER;
    VAR used: AllocationMap.Map; b: DiskTypes.Buffer;
      p: DiskTypes.Page; e: DiskTypes.Entry;
  BEGIN
    IF ~v.treeValid THEN RETURN -5 END;
    Diagnostics.Clear(v); v.checkComplete := TRUE; v.lastClaimed := FALSE; v.usableCount := 0;
    v.checkedReferences := 0;
    e := v.first;
    WHILE e # NIL DO
      e.dataIssue := 0; e.usable := e.headerIssue = 0;
      IF e.headerIssue # 0 THEN
        Diagnostics.Add(v, e.headerIssue, e.name, e.key, e.aleng, e.bleng)
      END;
      e := e.next
    END;
    AllocationMap.Init(used); p := v.pages;
    WHILE (p # NIL) & v.checkComplete DO Claim(v, used, NIL, p.key, -1); p := p.next END;
    (* Reserve every known header, even invalid ones, before checking file data. *)
    e := v.first;
    WHILE (e # NIL) & v.checkComplete DO
      IF Budget(v, e, e.key, 0) THEN
        IF OberonBTree.GetBlock(v, e.key, b) = 0 THEN Claim(v, used, e, e.key, 0)
        ELSIF e.headerIssue = 0 THEN Bad(v, e, Diagnostics.HeaderRead, e.key, 0) END
      END;
      e := e.next
    END;
    e := v.first;
    WHILE (e # NIL) & v.checkComplete DO
      COPY(e.name, v.error);
      IF e.headerIssue = 0 THEN File(v, used, e) END;
      e := e.next
    END;
    e := v.first;
    WHILE e # NIL DO
      IF e.usable THEN INC(v.usableCount) END;
      e := e.next
    END;
    IF ~v.checkComplete THEN v.error := "allocation checker resource limit"; RETURN -7 END;
    IF v.issueCount # 0 THEN v.error := "filesystem consistency errors"; RETURN -5 END;
    RETURN 0
  END Check;
END FSCheck.
