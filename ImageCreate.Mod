MODULE ImageCreate;
  (* Empty filesystems, either new files or explicitly selected working images. *)
  IMPORT Host, BlockIO, DiskTypes, DiskBytes, Formats, FileSystem, FSCheck;

  PROCEDURE Boot(VAR v: DiskTypes.Volume; start, size: LONGINT): INTEGER;
    VAR b: DiskTypes.Buffer; i: INTEGER; sectors: LONGINT;
  BEGIN
    FOR i := 0 TO 511 DO b[i] := 0X END;
    b[0] := 0EBX; b[1] := 0FEX; b[2] := 90X;
    b[510] := 55X; b[511] := 0AAX;
    sectors := size DIV 512;
    IF v.kind = DiskTypes.Native THEN
      b[3] := "O"; b[4] := "B"; b[5] := "E"; b[6] := "R"; b[7] := "O"; b[8] := "N";
      DiskBytes.Put16(b, 11, 512); b[13] := 4X;
      DiskBytes.Put16(b, 14, (v.root-start) DIV 512);
      IF sectors < 65536 THEN DiskBytes.Put16(b, 19, sectors) END;
      DiskBytes.Put32(b, 32, sectors);
      DiskBytes.Put16(b, 24, 18); DiskBytes.Put16(b, 26, 2)
    ELSE
      DiskBytes.Put32(b, 496, (v.root-start) DIV 512);
      DiskBytes.Put32(b, 500, (start+size-v.root) DIV 4096);
      DiskBytes.Put32(b, 504, 559107905);
      IF v.kind = DiskTypes.Aos1 THEN b[508] := 1X ELSE b[508] := 2X END;
      b[509] := 0CX
    END;
    RETURN BlockIO.Write(v.image, start, b, 512)
  END Boot;

  PROCEDURE Layout(container: ARRAY OF CHAR; kind: INTEGER; size: LONGINT;
                   VAR v: DiskTypes.Volume; VAR start: LONGINT): INTEGER;
    VAR blocks: LONGINT;
  BEGIN
    IF ~Formats.Configure(kind, v) THEN RETURN -22 END;
    start := 0;
    IF container = "hdd" THEN
      IF kind = DiskTypes.Ceres THEN RETURN -95 END;
      start := 1048576
    ELSIF container = "floppy" THEN
      IF (kind # DiskTypes.Native) OR (size # 1474560) THEN RETURN -95 END
    ELSIF container # "raw" THEN RETURN -22 END;
    IF container = "raw" THEN
      IF (kind = DiskTypes.Project) OR (kind = DiskTypes.Ceres) THEN v.root := 1024 ELSE v.root := 0 END
    ELSIF kind = DiskTypes.Project THEN v.root := start+1024
    ELSE v.root := start+32768 END;
    IF (size MOD 512 # 0) OR (size < v.root+4*v.blockSize) THEN RETURN -22 END;
    blocks := (size-v.root) DIV v.blockSize;
    IF (blocks > 2147483647 DIV 29) OR (size DIV 512 > LONG(65536)*65536-1) THEN RETURN -22 END;
    RETURN 0
  END Layout;

  PROCEDURE Write(VAR v: DiskTypes.Volume; container: ARRAY OF CHAR; start: LONGINT): INTEGER;
    VAR b: DiskTypes.Buffer; i, res: INTEGER;
  BEGIN
    res := 0;
    FOR i := 0 TO 4095 DO b[i] := 0X END;
    IF container = "hdd" THEN
      (* Inactive partition, aligned to 1 MiB. Historical partition IDs. *)
      b[447] := 0FEX; b[448] := 0FFX; b[449] := 0FFX;
      IF v.kind = DiskTypes.Project THEN b[450] := 0FFX
      ELSIF v.kind = DiskTypes.Native THEN b[450] := 4FX ELSE b[450] := 4CX END;
      b[451] := 0FEX; b[452] := 0FFX; b[453] := 0FFX;
      DiskBytes.Put32(b, 454, start DIV 512);
      DiskBytes.Put32(b, 458, (v.image.size-start) DIV 512);
      b[510] := 55X; b[511] := 0AAX;
      res := BlockIO.Write(v.image, 0, b, 512)
    END;
    IF (res = 0) & (container # "raw") & (v.kind # DiskTypes.Project) THEN
      res := Boot(v, start, v.image.size-start)
    END;
    IF res = 0 THEN
      FOR i := 0 TO 4095 DO b[i] := 0X END;
      DiskTypes.MarkDirectory(b);
      res := BlockIO.Write(v.image, v.root, b, v.blockSize)
    END;
    IF res = 0 THEN res := FileSystem.Scan(v, v.kind, v.root, FALSE) END;
    IF res = 0 THEN res := FSCheck.Check(v) END;
    RETURN res
  END Write;

  PROCEDURE Clear(VAR image: BlockIO.Image): INTEGER;
    VAR b: ARRAY 65536 OF CHAR; offset: LONGINT; i, n, res: INTEGER;
  BEGIN
    FOR i := 0 TO LEN(b)-1 DO b[i] := 0X END;
    offset := 0;
    WHILE offset < image.size DO
      n := LEN(b); IF n > image.size-offset THEN n := SHORT(image.size-offset) END;
      res := BlockIO.Write(image, offset, b, n); IF res # 0 THEN RETURN res END;
      INC(offset, n)
    END;
    RETURN 0
  END Clear;

  PROCEDURE FormatExisting*(path, container: ARRAY OF CHAR; kind: INTEGER): INTEGER;
    VAR v: DiskTypes.Volume; start: LONGINT; res, closed: INTEGER;
  BEGIN
    res := BlockIO.OpenUpdate(path, v.image); IF res # 0 THEN RETURN res END;
    (* Validate the complete layout before overwriting any existing bytes. *)
    res := Layout(container, kind, v.image.size, v, start);
    IF res = 0 THEN res := Clear(v.image) END;
    IF res = 0 THEN res := Write(v, container, start) END;
    closed := BlockIO.Close(v.image);
    IF res = 0 THEN res := closed END;
    RETURN res
  END FormatExisting;

  PROCEDURE FormatDevice*(path, container: ARRAY OF CHAR; kind: INTEGER): INTEGER;
    VAR v: DiskTypes.Volume; start: LONGINT; res, closed: INTEGER;
  BEGIN
    res := BlockIO.OpenDevice(path, TRUE, v.image); IF res # 0 THEN RETURN res END;
    res := Layout(container, kind, v.image.size, v, start);
    IF res = 0 THEN
      Host.Error("erasing the entire selected block device (including old partitions):"); Host.Error(path);
      res := Clear(v.image)
    END;
    IF res = 0 THEN res := Write(v, container, start) END;
    closed := BlockIO.Close(v.image); IF res = 0 THEN res := closed END;
    RETURN res
  END FormatDevice;

  PROCEDURE Create*(path, container: ARRAY OF CHAR; kind: INTEGER; size: LONGINT): INTEGER;
    VAR v: DiskTypes.Volume; start: LONGINT; res, closed: INTEGER;
  BEGIN
    res := Layout(container, kind, size, v, start); IF res # 0 THEN RETURN res END;
    res := BlockIO.Create(path, size, v.image); IF res # 0 THEN RETURN res END;
    res := Write(v, container, start);
    closed := BlockIO.Close(v.image);
    IF res = 0 THEN res := closed END;
    RETURN res
  END Create;
END ImageCreate.
