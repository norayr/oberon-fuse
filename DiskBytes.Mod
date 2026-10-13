MODULE DiskBytes;
  (* Disk numbers are unsigned; LONGINT holds every unsigned 32-bit value. *)
  PROCEDURE U16*(VAR b: ARRAY OF CHAR; offset: INTEGER): LONGINT;
  BEGIN RETURN LONG(ORD(b[offset])) + LONG(ORD(b[offset+1]))*256 END U16;

  PROCEDURE U32*(VAR b: ARRAY OF CHAR; offset: INTEGER): LONGINT;
  BEGIN RETURN U16(b, offset) + U16(b, offset+2)*65536 END U32;

  PROCEDURE Put16*(VAR b: ARRAY OF CHAR; offset: INTEGER; value: LONGINT);
  BEGIN b[offset] := CHR(value MOD 256); b[offset+1] := CHR(value DIV 256 MOD 256) END Put16;

  PROCEDURE Put32*(VAR b: ARRAY OF CHAR; offset: INTEGER; value: LONGINT);
  BEGIN Put16(b, offset, value MOD 65536); Put16(b, offset+2, value DIV 65536) END Put32;

  PROCEDURE Name*(VAR b: ARRAY OF CHAR; offset, width: INTEGER; VAR name: ARRAY OF CHAR): BOOLEAN;
    VAR i: INTEGER; ch: CHAR;
  BEGIN
    IF width > LEN(name) THEN RETURN FALSE END;
    i := 0;
    WHILE i < width DO
      ch := b[offset+i]; name[i] := ch;
      IF ch = 0X THEN RETURN i > 0 END;
      IF (ch < " ") OR (ch = "/") THEN RETURN FALSE END;
      INC(i)
    END;
    RETURN FALSE
  END Name;

  PROCEDURE Number*(text: ARRAY OF CHAR; VAR value: LONGINT): BOOLEAN;
    VAR i, digit: INTEGER;
  BEGIN
    i := 0; value := 0;
    WHILE (i < LEN(text)) & (text[i] # 0X) DO
      digit := ORD(text[i])-ORD("0");
      IF (digit < 0) OR (digit > 9) OR (value > (MAX(LONGINT)-digit) DIV 10) THEN RETURN FALSE END;
      value := value*10+digit; INC(i)
    END;
    RETURN (i > 0) & (i < LEN(text))
  END Number;
END DiskBytes.
