MODULE AllocationMap;
  (* Track owners as well as addresses, so both sides of an overlap are unsafe. *)
  IMPORT DiskTypes;
  CONST Buckets = 4096; MaxItems = 1048576;
  TYPE
    Item = POINTER TO RECORD next: Item; key: LONGINT; owner: DiskTypes.Entry END;
    Map* = RECORD bucket: POINTER TO ARRAY Buckets OF Item; count: INTEGER END;

  PROCEDURE Init*(VAR map: Map);
    VAR i: INTEGER;
  BEGIN
    NEW(map.bucket); map.count := 0;
    FOR i := 0 TO Buckets-1 DO map.bucket[i] := NIL END
  END Init;

  PROCEDURE Claim*(VAR map: Map; key: LONGINT; owner: DiskTypes.Entry;
                   VAR other: DiskTypes.Entry): INTEGER;
    VAR i: INTEGER; p: Item;
  BEGIN
    other := NIL;
    IF key <= 0 THEN RETURN -5 END;
    i := SHORT(key DIV 29 MOD Buckets); p := map.bucket[i];
    WHILE p # NIL DO
      IF p.key = key THEN other := p.owner; RETURN 1 END;
      p := p.next
    END;
    IF map.count >= MaxItems THEN RETURN -7 END;
    NEW(p); p.key := key; p.owner := owner;
    p.next := map.bucket[i]; map.bucket[i] := p; INC(map.count);
    RETURN 0
  END Claim;
END AllocationMap.
