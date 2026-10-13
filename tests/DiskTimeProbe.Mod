MODULE DiskTimeProbe;
  IMPORT Out, DiskTypes, DiskTime;
  VAR kind, offset, i: INTEGER; value, decoded, date, time: LONGINT;
    cases: ARRAY 8 OF LONGINT;
BEGIN
  ASSERT(DiskTime.Unix(1970, 1, 1, 0, 0, 0, value) & (value = 0));
  ASSERT(DiskTime.Unix(1900, 1, 1, 0, 0, 0, value) & (value = -2208988800));
  ASSERT(~DiskTime.Unix(1900, 2, 29, 0, 0, 0, value));
  ASSERT(~DiskTime.Unix(2100, 2, 29, 0, 0, 0, value));
  ASSERT(DiskTime.Unix(2000, 2, 29, 0, 0, 0, value));
  ASSERT(~DiskTime.Unix(2024, 4, 31, 0, 0, 0, value));
  ASSERT(~DiskTime.Unix(2024, 0, 1, 0, 0, 0, value));
  ASSERT(~DiskTime.Unix(2024, 1, 1, 24, 0, 0, value));
  cases[0] := 946771200; cases[1] := 951827696; cases[2] := 2147483647;
  cases[3] := 1709251199; cases[4] := 2966272496; cases[5] := 1672531200;
  cases[6] := 1000000000; cases[7] := 1609459200;
  FOR kind := DiskTypes.Project TO DiskTypes.Aos2 DO
    FOR offset := -720 TO 720 BY 120 DO
      FOR i := 0 TO LEN(cases)-1 DO
        ASSERT(DiskTime.Encode(kind, cases[i], offset, date, time));
        ASSERT(DiskTime.Decode(kind, date, time, offset, decoded) & (decoded = cases[i]))
      END
    END;
    ASSERT(~DiskTime.Decode(kind, 0, 0, 0, decoded) & (decoded = 0));
    ASSERT(~DiskTime.Decode(kind, 4294967295, 4294967295, 0, decoded));
    ASSERT(~DiskTime.Encode(kind, MAX(LONGINT), 0, date, time));
    ASSERT(~DiskTime.Encode(kind, MIN(LONGINT), 0, date, time))
  END;
  ASSERT(DiskTime.Unix(1999, 12, 31, 23, 59, 59, value));
  ASSERT(~DiskTime.Encode(DiskTypes.Project, value, 0, date, time));
  ASSERT(DiskTime.Encode(DiskTypes.Ceres, value, 0, date, time));
  ASSERT(DiskTime.Decode(DiskTypes.Ceres, date, time, 0, decoded) & (decoded = value));
  ASSERT(DiskTime.Unix(1970, 1, 1, 0, 0, 0, value));
  ASSERT(DiskTime.Encode(DiskTypes.Ceres, value, 0, date, time));
  ASSERT(DiskTime.Decode(DiskTypes.Ceres, date, time, 0, decoded) & (decoded = value));
  ASSERT(~DiskTime.Decode(DiskTypes.Native, 124*512+2*32+30, 0, 0, decoded));
  ASSERT(~DiskTime.Decode(DiskTypes.Native, 124*512+1*32+1, 24*4096, 0, decoded));
  Out.String("Oberon clocks, Gregorian validation and UTC offsets: OK"); Out.Ln
END DiskTimeProbe.
