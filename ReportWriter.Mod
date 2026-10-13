MODULE ReportWriter;
  (* The same bounded text writer can measure, print, or write a new report. *)
  IMPORT BlockIO, Host;
  CONST Measure = 0; Stdout = 1; File = 2;
  TYPE Writer* = RECORD
    image*: BlockIO.Image;
    position*: LONGINT;
    error*: INTEGER;
    mode: INTEGER
  END;

  PROCEDURE Count*(VAR w: Writer);
  BEGIN w.mode := Measure; w.position := 0; w.error := 0 END Count;

  PROCEDURE Console*(VAR w: Writer);
  BEGIN w.mode := Stdout; w.position := 0; w.error := 0 END Console;

  PROCEDURE Create*(VAR w: Writer; path: ARRAY OF CHAR; size: LONGINT): INTEGER;
  BEGIN
    w.mode := File; w.position := 0;
    w.error := BlockIO.Create(path, size, w.image);
    RETURN w.error
  END Create;

  PROCEDURE Text*(VAR w: Writer; text: ARRAY OF CHAR);
    VAR b: ARRAY 4096 OF CHAR; i, n: INTEGER;
  BEGIN
    IF w.error # 0 THEN RETURN END;
    i := 0;
    WHILE (i < LEN(text)) & (text[i] # 0X) DO
      n := 0;
      WHILE (i < LEN(text)) & (text[i] # 0X) & (n < LEN(b)) DO
        b[n] := text[i]; INC(i); INC(n)
      END;
      IF w.mode = Stdout THEN w.error := Host.Output(b, n)
      ELSIF w.mode = File THEN w.error := BlockIO.Write(w.image, w.position, b, n) END;
      IF w.error # 0 THEN RETURN END;
      INC(w.position, n)
    END
  END Text;

  PROCEDURE Number*(VAR w: Writer; value: LONGINT);
    VAR text: ARRAY 32 OF CHAR; i, n, digit: INTEGER; negative: BOOLEAN;
  BEGIN
    (* Keep the working value negative, so MIN(LONGINT) is representable. *)
    negative := value < 0; IF value > 0 THEN value := -value END;
    i := LEN(text)-1; text[i] := 0X;
    REPEAT
      digit := SHORT(value MOD 10);
      IF digit = 0 THEN value := value DIV 10
      ELSE digit := 10-digit; value := value DIV 10+1 END;
      DEC(i); text[i] := CHR(ORD("0")+digit)
    UNTIL value = 0;
    IF negative THEN DEC(i); text[i] := "-" END;
    n := 0;
    WHILE i < LEN(text) DO text[n] := text[i]; INC(i); INC(n) END;
    Text(w, text)
  END Number;

  PROCEDURE Line*(VAR w: Writer);
    VAR text: ARRAY 2 OF CHAR;
  BEGIN text[0] := 0AX; text[1] := 0X; Text(w, text) END Line;

  PROCEDURE Char*(VAR w: Writer; ch: CHAR);
    VAR text: ARRAY 2 OF CHAR;
  BEGIN text[0] := ch; text[1] := 0X; Text(w, text) END Char;

  PROCEDURE Close*(VAR w: Writer): INTEGER;
    VAR res: INTEGER;
  BEGIN
    IF w.mode = File THEN
      res := BlockIO.Close(w.image); IF w.error = 0 THEN w.error := res END
    END;
    RETURN w.error
  END Close;
END ReportWriter.
