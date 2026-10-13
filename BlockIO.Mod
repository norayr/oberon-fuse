MODULE BlockIO;
  IMPORT Host, ReadCache;

  TYPE Image* = RECORD
    fd: LONGINT;
    size*: LONGINT;
    writable: BOOLEAN;
    cache: ReadCache.Cache
  END;

  PROCEDURE OpenImage(path: ARRAY OF CHAR; writable, device: BOOLEAN; VAR image: Image): INTEGER;
    VAR res, ignored: INTEGER;
  BEGIN
    image.writable := writable; image.size := 0; image.cache := NIL;
    IF device THEN image.fd := Host.OpenDevice(path, writable)
    ELSIF writable THEN image.fd := Host.OpenUpdate(path) ELSE image.fd := Host.Open(path) END;
    IF image.fd < 0 THEN RETURN SHORT(image.fd) END;
    image.size := Host.Size(image.fd);
    IF image.size < 0 THEN
      res := SHORT(image.size); ignored := Host.Close(image.fd, FALSE); image.fd := -1;
      RETURN res
    END;
    RETURN 0
  END OpenImage;

  PROCEDURE Open*(path: ARRAY OF CHAR; VAR image: Image): INTEGER;
  BEGIN RETURN OpenImage(path, FALSE, FALSE, image) END Open;

  PROCEDURE OpenUpdate*(path: ARRAY OF CHAR; VAR image: Image): INTEGER;
  BEGIN RETURN OpenImage(path, TRUE, FALSE, image) END OpenUpdate;

  PROCEDURE OpenDevice*(path: ARRAY OF CHAR; writable: BOOLEAN; VAR image: Image): INTEGER;
  BEGIN RETURN OpenImage(path, writable, TRUE, image) END OpenDevice;

  PROCEDURE Scratch*(VAR image: Image): INTEGER;
  BEGIN
    image.fd := Host.Scratch(); image.writable := TRUE; image.size := 0; image.cache := NIL;
    IF image.fd < 0 THEN RETURN SHORT(image.fd) END;
    RETURN 0
  END Scratch;

  PROCEDURE ConfigureCache*(VAR image: Image; mib: INTEGER): INTEGER;
  BEGIN RETURN ReadCache.Configure(image.cache, mib) END ConfigureCache;

  PROCEDURE CacheInfo*(VAR image: Image; VAR capacity, count, blockSize: INTEGER;
                       VAR hits, misses, evictions: LONGINT);
  BEGIN ReadCache.Info(image.cache, capacity, count, blockSize, hits, misses, evictions) END CacheInfo;

  PROCEDURE Resize*(VAR image: Image; size: LONGINT): INTEGER;
    VAR res: INTEGER;
  BEGIN
    IF ~image.writable THEN RETURN -30 END;
    ReadCache.Clear(image.cache);
    res := Host.Resize(image.fd, size); IF res = 0 THEN image.size := size END;
    RETURN res
  END Resize;

  PROCEDURE Create*(path: ARRAY OF CHAR; size: LONGINT; VAR image: Image): INTEGER;
  BEGIN
    image.size := size; image.writable := TRUE; image.cache := NIL;
    image.fd := Host.Create(path, size);
    IF image.fd < 0 THEN RETURN SHORT(image.fd) END;
    RETURN 0
  END Create;

  PROCEDURE Read*(VAR image: Image; offset: LONGINT; VAR data: ARRAY OF CHAR; count: INTEGER): INTEGER;
  BEGIN
    IF (offset < 0) OR (offset > image.size) OR
       (count < 0) OR (count > LEN(data)) OR (count > image.size-offset) THEN RETURN -5 END;
    RETURN Host.Read(image.fd, offset, data, count)
  END Read;

  PROCEDURE ReadBlock*(VAR image: Image; offset: LONGINT; VAR data: ARRAY OF CHAR; count: INTEGER): INTEGER;
    VAR res: INTEGER;
  BEGIN
    IF (image.fd < 0) OR (offset < 0) OR (offset > image.size) OR
       (count < 0) OR (count > LEN(data)) OR (count > image.size-offset) THEN RETURN -5 END;
    IF ReadCache.Get(image.cache, offset, count, data) THEN RETURN 0 END;
    res := Host.Read(image.fd, offset, data, count);
    IF res = 0 THEN ReadCache.Put(image.cache, offset, count, data) END;
    RETURN res
  END ReadBlock;

  PROCEDURE Write*(VAR image: Image; offset: LONGINT; VAR data: ARRAY OF CHAR; count: INTEGER): INTEGER;
  BEGIN
    IF ~image.writable THEN RETURN -30 END;
    IF (offset < 0) OR (offset > image.size) OR
        (count < 0) OR (count > LEN(data)) OR (count > image.size-offset) THEN RETURN -22 END;
    (* Invalidate before the syscall: an error can follow a partial write. *)
    ReadCache.Invalidate(image.cache, offset, count);
    RETURN Host.Write(image.fd, offset, data, count)
  END Write;

  PROCEDURE Sync*(VAR image: Image): INTEGER;
  BEGIN
    IF ~image.writable THEN RETURN 0 END;
    RETURN Host.Sync(image.fd)
  END Sync;

  PROCEDURE Close*(VAR image: Image): INTEGER;
    VAR res: INTEGER;
  BEGIN
    res := ReadCache.Configure(image.cache, 0);
    res := Host.Close(image.fd, image.writable); image.fd := -1;
    RETURN res
  END Close;
END BlockIO.
