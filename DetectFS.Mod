MODULE DetectFS;
  IMPORT BlockIO, DiskTypes, DiskBytes, Formats;

  PROCEDURE Boot(VAR v: DiskTypes.Volume; start, limit: LONGINT): BOOLEAN;
    VAR b: DiskTypes.Buffer; root, size, id: LONGINT; kind, offset: INTEGER;
  BEGIN
    IF (start < 0) OR (start > limit) OR (limit-start < 512) THEN RETURN FALSE END;
    IF BlockIO.Read(v.image, start, b, 512) # 0 THEN RETURN FALSE END;
    IF (b[510] # 55X) OR (b[511] # 0AAX) THEN RETURN FALSE END;
    kind := 0; root := 0;
    (* Aos boot sectors can retain the OBERON OEM string. The footer wins. *)
    id := DiskBytes.U32(b, 504);
    IF (id = 559107905) OR (id = 1380270671) THEN
      IF b[509] # 0CX THEN RETURN FALSE END;
      IF b[508] = 1X THEN kind := DiskTypes.Aos1
      ELSIF b[508] = 2X THEN kind := DiskTypes.Aos2 ELSE RETURN FALSE END;
      offset := 496;
      IF id = 1380270671 THEN
        IF kind # DiskTypes.Aos1 THEN RETURN FALSE END;
        offset := 480
      END;
      root := start+DiskBytes.U32(b, offset)*512;
      size := DiskBytes.U32(b, offset+4)*4096;
      IF (size <= 0) OR (size > MAX(LONGINT)-root) THEN RETURN FALSE END;
      IF root+size < limit THEN limit := root+size END
    ELSIF (b[3] = "O") & (b[4] = "B") & (b[5] = "E") & (b[6] = "R") &
       (b[7] = "O") & (b[8] = "N") THEN
      kind := DiskTypes.Native; root := start+DiskBytes.U16(b, 14)*512;
      size := DiskBytes.U16(b, 19); IF size = 0 THEN size := DiskBytes.U32(b, 32) END;
      IF (size > 0) & (start+size*512 < limit) THEN limit := start+size*512 END
    END;
    IF (kind = 0) OR (root < start+512) OR (root >= limit) THEN RETURN FALSE END;
    IF ~Formats.Configure(kind, v) THEN RETURN FALSE END;
    v.root := root; v.limit := limit;
    RETURN TRUE
  END Boot;

  PROCEDURE CD(VAR v: DiskTypes.Volume): BOOLEAN;
    VAR b: DiskTypes.Buffer; name: DiskTypes.Name; catalog, image, sum: LONGINT; i: INTEGER;
  BEGIN
    IF BlockIO.Read(v.image, 17*2048, b, 2048) # 0 THEN RETURN FALSE END;
    IF (b[0] # 0X) OR (b[1] # "C") OR (b[2] # "D") OR (b[3] # "0") OR
       (b[4] # "0") OR (b[5] # "1") OR (b[6] # 1X) THEN RETURN FALSE END;
    IF ~DiskBytes.Name(b, 7, 32, name) OR (name # "EL TORITO SPECIFICATION") THEN RETURN FALSE END;
    catalog := DiskBytes.U32(b, 71)*2048;
    IF BlockIO.Read(v.image, catalog, b, 2048) # 0 THEN RETURN FALSE END;
    sum := 0; FOR i := 0 TO 15 DO sum := sum+DiskBytes.U16(b, i*2) END;
    IF (sum MOD 65536 # 0) OR (b[0] # 1X) OR (b[1] # 0X) OR (b[30] # 55X) OR
       (b[31] # 0AAX) OR (b[32] # 88X) OR (ORD(b[33]) > 4) THEN RETURN FALSE END;
    image := DiskBytes.U32(b, 40)*2048;
    RETURN Boot(v, image, v.image.size)
  END CD;

  PROCEDURE Locate*(VAR v: DiskTypes.Volume; kind: INTEGER; root: LONGINT): INTEGER;
    VAR b: DiskTypes.Buffer; i, found, detected: INTEGER; start, limit, savedRoot, savedLimit: LONGINT;
  BEGIN
    v.limit := v.image.size;
    IF root >= 0 THEN
      IF (kind = 0) OR ~Formats.Configure(kind, v) THEN RETURN -22 END;
      v.root := root
    ELSE
      detected := 0;
      IF Boot(v, 0, v.image.size) OR CD(v) THEN detected := v.kind
      ELSE
        IF BlockIO.Read(v.image, 0, b, 512) # 0 THEN RETURN -5 END;
        found := 0; savedRoot := 0; savedLimit := 0;
        IF (b[510] = 55X) & (b[511] = 0AAX) THEN
          FOR i := 0 TO 3 DO
            IF (b[446+i*16+4] = 0FFX) OR (b[446+i*16+4] = 4CX) OR
               (b[446+i*16+4] = 4FX) OR (b[446+i*16+4] = 50X) THEN
              start := DiskBytes.U32(b, 446+i*16+8)*512;
              limit := start+DiskBytes.U32(b, 446+i*16+12)*512;
              IF limit > v.image.size THEN limit := v.image.size END;
              IF Boot(v, start, limit) THEN
                detected := v.kind; savedRoot := v.root; savedLimit := v.limit; INC(found)
              ELSE
                IF BlockIO.Read(v.image, start+1024, b, 4) = 0 THEN
                  IF DiskTypes.IsDirectory(b) THEN
                    detected := DiskTypes.Project; savedRoot := start+1024; savedLimit := limit; INC(found)
                  END
                END
              END;
              (* Boot probing must not overwrite the partition table. *)
              IF BlockIO.Read(v.image, 0, b, 512) # 0 THEN RETURN -5 END
            END
          END
        END;
        IF found > 1 THEN RETURN -22 END;
        IF found = 1 THEN v.root := savedRoot; v.limit := savedLimit
        ELSE
          IF kind = 0 THEN kind := DiskTypes.Project END;
          IF ~Formats.Configure(kind, v) THEN RETURN -22 END;
          IF (kind = DiskTypes.Project) OR (kind = DiskTypes.Ceres) THEN v.root := 1024 ELSE v.root := 0 END;
          detected := kind
        END
      END;
      IF (kind # 0) & (kind # detected) THEN RETURN -22 END;
      IF ~Formats.Configure(detected, v) THEN RETURN -22 END
    END;
    IF (v.root < 0) OR (v.root > v.limit) OR (v.blockSize > v.limit-v.root) THEN RETURN -5 END;
    RETURN 0
  END Locate;
END DetectFS.
