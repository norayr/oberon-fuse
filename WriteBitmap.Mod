MODULE WriteBitmap;
  (* A compact allocation map for a checked, exclusively opened volume. *)
  TYPE Map* = RECORD bits: POINTER TO ARRAY OF SET; total*, free*: LONGINT; cursor: LONGINT END;

  PROCEDURE Init*(VAR map: Map; blocks: LONGINT): INTEGER;
    VAR i, words: INTEGER;
  BEGIN
    IF (blocks < 1) OR (blocks > 2147483647 DIV 29) THEN RETURN -27 END;
    words := SHORT((blocks+31) DIV 32); NEW(map.bits, words);
    FOR i := 0 TO words-1 DO map.bits[i] := {} END;
    map.total := blocks; map.free := blocks; map.cursor := 0; RETURN 0
  END Init;

  PROCEDURE Use*(VAR map: Map; key: LONGINT): BOOLEAN;
    VAR n: LONGINT; word, bit: INTEGER;
  BEGIN
    IF (key <= 0) OR (key MOD 29 # 0) THEN RETURN FALSE END;
    n := key DIV 29-1; IF n >= map.total THEN RETURN FALSE END;
    word := SHORT(n DIV 32); bit := SHORT(n MOD 32);
    IF bit IN map.bits[word] THEN RETURN FALSE END;
    INCL(map.bits[word], bit); DEC(map.free); RETURN TRUE
  END Use;

  PROCEDURE Free*(VAR map: Map; key: LONGINT);
    VAR n: LONGINT; word, bit: INTEGER;
  BEGIN
    IF (key <= 0) OR (key MOD 29 # 0) THEN RETURN END;
    n := key DIV 29-1; IF n >= map.total THEN RETURN END;
    word := SHORT(n DIV 32); bit := SHORT(n MOD 32);
    IF bit IN map.bits[word] THEN
      EXCL(map.bits[word], bit); INC(map.free);
      IF n < map.cursor THEN map.cursor := n END
    END
  END Free;

  PROCEDURE Allocate*(VAR map: Map): LONGINT;
    VAR n, visited: LONGINT; word, bit: INTEGER;
  BEGIN
    IF map.free <= 0 THEN RETURN 0 END;
    n := map.cursor; visited := 0;
    WHILE visited < map.total DO
      word := SHORT(n DIV 32); bit := SHORT(n MOD 32);
      IF ~(bit IN map.bits[word]) THEN
        INCL(map.bits[word], bit); DEC(map.free); map.cursor := (n+1) MOD map.total;
        RETURN (n+1)*29
      END;
      n := (n+1) MOD map.total; INC(visited)
    END;
    RETURN 0
  END Allocate;
END WriteBitmap.
