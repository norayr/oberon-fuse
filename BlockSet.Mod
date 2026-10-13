MODULE BlockSet;
  (* A bounded set used for cycle and allocation-overlap checks. *)
  CONST Buckets = 4096; MaxItems = 1048576;
  TYPE
    Item = POINTER TO RECORD next: Item; key: LONGINT END;
    Set* = RECORD bucket: POINTER TO ARRAY Buckets OF Item; count: INTEGER END;

  PROCEDURE Init*(VAR set: Set);
    VAR i: INTEGER;
  BEGIN
    NEW(set.bucket);
    FOR i := 0 TO Buckets-1 DO set.bucket[i] := NIL END;
    set.count := 0
  END Init;

  PROCEDURE Add*(VAR set: Set; key: LONGINT): BOOLEAN;
    VAR i: INTEGER; p: Item;
  BEGIN
    IF (key < 0) OR (set.count >= MaxItems) THEN RETURN FALSE END;
    i := SHORT(key DIV 29 MOD Buckets); p := set.bucket[i];
    WHILE p # NIL DO
      IF p.key = key THEN RETURN FALSE END;
      p := p.next
    END;
    NEW(p); p.key := key; p.next := set.bucket[i]; set.bucket[i] := p;
    INC(set.count); RETURN TRUE
  END Add;
END BlockSet.
