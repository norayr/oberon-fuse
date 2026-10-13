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

  PROCEDURE InspectOptions*(first: INTEGER; VAR kind: INTEGER; VAR root: LONGINT;
                           VAR salvage, device: BOOLEAN): BOOLEAN;
    VAR text: ARRAY 1024 OF CHAR;
  BEGIN
    salvage := FALSE; device := FALSE;
    WHILE Modules.ArgCount > first DO
      Modules.GetArg(first, text);
      IF text = "--salvage" THEN IF salvage THEN RETURN FALSE END; salvage := TRUE
      ELSIF text = "--device" THEN IF device THEN RETURN FALSE END; device := TRUE
      ELSE RETURN Profile(first, kind, root) END;
      INC(first)
    END;
    RETURN Profile(first, kind, root)
  END InspectOptions;

  PROCEDURE MountOptions*(first: INTEGER; VAR kind: INTEGER; VAR root: LONGINT;
                         VAR salvage, writable, device: BOOLEAN; VAR offset: INTEGER): BOOLEAN;
    VAR text: ARRAY 1024 OF CHAR; number: LONGINT; sign, i: INTEGER;
      seen: SET;
  BEGIN
    salvage := FALSE; writable := FALSE; device := FALSE; offset := 0; seen := {};
    WHILE Modules.ArgCount > first DO
      Modules.GetArg(first, text);
      IF text = "--salvage" THEN i := 0; salvage := TRUE
      ELSIF text = "--rw" THEN i := 1; writable := TRUE
      ELSIF text = "--device" THEN i := 2; device := TRUE
      ELSIF text = "--utc-offset" THEN
        i := 3; INC(first); IF Modules.ArgCount <= first THEN RETURN FALSE END;
        Modules.GetArg(first, text); sign := 1;
        IF (text[0] = "-") OR (text[0] = "+") THEN
          IF text[0] = "-" THEN sign := -1 END;
          number := 1; WHILE text[SHORT(number)] # 0X DO text[SHORT(number)-1] := text[SHORT(number)]; INC(number) END;
          text[SHORT(number)-1] := 0X
        END;
        IF ~DiskBytes.Number(text, number) OR (number > 1440) THEN RETURN FALSE END;
        offset := sign*SHORT(number)
      ELSE
        IF (text[0] = "-") OR (salvage & writable) THEN RETURN FALSE END;
        RETURN Profile(first, kind, root)
      END;
      IF i IN seen THEN RETURN FALSE END;
      INCL(seen, i); INC(first)
    END;
    IF salvage & writable THEN RETURN FALSE END;
    RETURN Profile(first, kind, root)
  END MountOptions;
END CommandLine.
