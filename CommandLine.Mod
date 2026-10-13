MODULE CommandLine;
  IMPORT Modules, Formats, DiskBytes;

  PROCEDURE Profile*(first: INTEGER; VAR kind: INTEGER; VAR root: LONGINT): BOOLEAN;
    VAR text: ARRAY 1024 OF CHAR;
  BEGIN
    kind := 0; root := -1;
    IF Modules.ArgCount > first+2 THEN RETURN FALSE END;
    IF Modules.ArgCount > first THEN
      Modules.GetArg(first, text); kind := Formats.Kind(text);
      IF kind < 0 THEN RETURN FALSE END
    END;
    IF Modules.ArgCount > first+1 THEN
      Modules.GetArg(first+1, text);
      IF (kind = 0) OR ~DiskBytes.Number(text, root) THEN RETURN FALSE END
    END;
    RETURN TRUE
  END Profile;

  PROCEDURE Options*(first: INTEGER; VAR kind: INTEGER; VAR root: LONGINT;
                     VAR salvage: BOOLEAN): BOOLEAN;
    VAR text: ARRAY 1024 OF CHAR;
  BEGIN
    salvage := FALSE;
    IF Modules.ArgCount > first THEN
      Modules.GetArg(first, text);
      IF text = "--salvage" THEN salvage := TRUE; INC(first) END
    END;
    RETURN Profile(first, kind, root)
  END Options;
END CommandLine.
