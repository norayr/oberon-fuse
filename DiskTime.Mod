MODULE DiskTime;
  (* Gregorian calendars and Oberon clock fields; no host record casts. *)
  IMPORT DiskTypes, DiskBytes;

  PROCEDURE Leap(year: LONGINT): BOOLEAN;
  BEGIN RETURN (year MOD 4 = 0) & ((year MOD 100 # 0) OR (year MOD 400 = 0)) END Leap;

  PROCEDURE Days(year, month: LONGINT): LONGINT;
  BEGIN
    CASE SHORT(month) OF
      2: IF Leap(year) THEN RETURN 29 ELSE RETURN 28 END |
      4, 6, 9, 11: RETURN 30
    ELSE RETURN 31 END
  END Days;

  PROCEDURE Before(year: LONGINT): LONGINT;
  BEGIN DEC(year); RETURN year*365+year DIV 4-year DIV 100+year DIV 400 END Before;

  PROCEDURE Unix*(year, month, day, hour, minute, second: LONGINT; VAR value: LONGINT): BOOLEAN;
    VAR days, m: LONGINT;
  BEGIN
    value := 0;
    IF (year < 1900) OR (year > 9999) OR (month < 1) OR (month > 12) OR
       (day < 1) OR (day > Days(year, month)) OR (hour < 0) OR (hour > 23) OR
       (minute < 0) OR (minute > 59) OR (second < 0) OR (second > 59) THEN RETURN FALSE END;
    days := Before(year)-Before(1970)+day-1;
    FOR m := 1 TO month-1 DO INC(days, Days(year, m)) END;
    value := days*86400+hour*3600+minute*60+second;
    RETURN TRUE
  END Unix;

  PROCEDURE Fields(value: LONGINT; VAR year, month, day, hour, minute, second: LONGINT): BOOLEAN;
    VAR days, rest, base: LONGINT;
  BEGIN
    IF (value < -2208988800) OR (value > 253402300799) THEN RETURN FALSE END;
    days := value DIV 86400; rest := value MOD 86400;
    year := 1970+days DIV 366;
    WHILE Before(year)-Before(1970) > days DO DEC(year) END;
    WHILE Before(year+1)-Before(1970) <= days DO INC(year) END;
    base := days-(Before(year)-Before(1970)); month := 1;
    WHILE base >= Days(year, month) DO DEC(base, Days(year, month)); INC(month) END;
    day := base+1; hour := rest DIV 3600; minute := rest DIV 60 MOD 60; second := rest MOD 60;
    RETURN TRUE
  END Fields;

  PROCEDURE Decode*(kind: INTEGER; date, time: LONGINT; offset: INTEGER; VAR value: LONGINT): BOOLEAN;
    VAR year, month, day, hour, minute, second: LONGINT; valid: BOOLEAN;
  BEGIN
    value := 0;
    IF kind = DiskTypes.Project THEN
      year := 2000+date DIV 67108864; month := date DIV 4194304 MOD 16;
      day := date DIV 131072 MOD 32; time := date MOD 131072;
      IF year > 2063 THEN RETURN FALSE END
    ELSE
      year := date DIV 512; month := date DIV 32 MOD 16; day := date MOD 32;
      IF (kind = DiskTypes.Ceres) & (year < 70) THEN INC(year, 2000) ELSE INC(year, 1900) END
    END;
    hour := time DIV 4096; minute := time DIV 64 MOD 64; second := time MOD 64;
    valid := Unix(year, month, day, hour, minute, second, value);
    IF valid THEN DEC(value, LONG(offset)*60) END;
    RETURN valid
  END Decode;

  PROCEDURE Encode*(kind: INTEGER; value: LONGINT; offset: INTEGER; VAR date, time: LONGINT): BOOLEAN;
    VAR year, month, day, hour, minute, second: LONGINT;
  BEGIN
    date := 0; time := 0;
    IF (value < -2208988800-86400) OR (value > 253402300799+86400) THEN RETURN FALSE END;
    IF ~Fields(value+LONG(offset)*60, year, month, day, hour, minute, second) THEN RETURN FALSE END;
    time := hour*4096+minute*64+second;
    IF kind = DiskTypes.Project THEN
      IF (year < 2000) OR (year > 2063) THEN RETURN FALSE END;
      date := ((year-2000)*512+month*32+day)*131072+time; time := 0
    ELSIF kind = DiskTypes.Ceres THEN
      IF (year < 1970) OR (year > 2069) THEN RETURN FALSE END;
      date := (year MOD 100)*512+month*32+day
    ELSE date := (year-1900)*512+month*32+day END;
    RETURN TRUE
  END Encode;

  PROCEDURE Load*(VAR v: DiskTypes.Volume; e: DiskTypes.Entry; VAR b: DiskTypes.Buffer);
    VAR at: INTEGER;
  BEGIN
    at := v.nameBytes+12;
    IF v.shortLengths THEN at := v.nameBytes+8 END;
    e.date := DiskBytes.U32(b, at); e.time := 0;
    IF v.kind # DiskTypes.Project THEN e.time := DiskBytes.U32(b, at+4) END;
    e.timeValid := Decode(v.kind, e.date, e.time, v.utcOffset, e.modified)
  END Load;

  PROCEDURE Store*(VAR v: DiskTypes.Volume; e: DiskTypes.Entry; VAR b: DiskTypes.Buffer);
    VAR at: INTEGER;
  BEGIN
    at := v.nameBytes+12;
    IF v.shortLengths THEN at := v.nameBytes+8 END;
    DiskBytes.Put32(b, at, e.date);
    IF v.kind # DiskTypes.Project THEN DiskBytes.Put32(b, at+4, e.time) END
  END Store;
END DiskTime.
