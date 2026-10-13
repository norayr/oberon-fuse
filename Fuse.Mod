MODULE Fuse;
  IMPORT Modules, Host, DiskTypes, FileSystem, FSWrite, CommandLine, FuseABI;
  TYPE Handle = POINTER TO HandleDesc;
    HandleDesc = RECORD next: Handle; id: LONGINT; entry: DiskTypes.Entry; writing, append: BOOLEAN END;
  VAR volume: DiskTypes.Volume; handles: Handle; nextHandle: LONGINT;

  PROCEDURE FindHandle(id: LONGINT): Handle;
    VAR h: Handle;
  BEGIN h := handles; WHILE (h # NIL) & (h.id # id) DO h := h.next END; RETURN h END FindHandle;

  PROCEDURE Entry(name: ARRAY OF CHAR; id: LONGINT): DiskTypes.Entry;
    VAR h: Handle; e: DiskTypes.Entry;
  BEGIN
    IF id # 0 THEN h := FindHandle(id); IF h = NIL THEN RETURN NIL END; RETURN h.entry END;
    e := FileSystem.FindPath(volume, name);
    IF (e # NIL) & ((e.headerIssue # 0) OR (volume.salvage & ~e.usable)) THEN RETURN NIL END;
    RETURN e
  END Entry;

  PROCEDURE Stat(name: ARRAY OF CHAR; id: LONGINT; VAR size, modified: LONGINT): INTEGER;
    VAR e: DiskTypes.Entry;
  BEGIN
    size := 0; modified := 0; IF volume.failed THEN RETURN -5 END;
    IF (id = 0) & (name = "/") THEN RETURN 1 END;
    e := Entry(name, id); IF e = NIL THEN RETURN -2 END;
    size := e.size; IF e.timeValid THEN modified := e.modified END;
    IF e.deleted THEN RETURN 2 ELSE RETURN 0 END
  END Stat;

  PROCEDURE Read(name: ARRAY OF CHAR; id, offset: LONGINT; VAR data: ARRAY OF CHAR; count: INTEGER): INTEGER;
    VAR e: DiskTypes.Entry;
  BEGIN
    IF (id = 0) & (name = "/") THEN RETURN -21 END;
    e := Entry(name, id); IF e = NIL THEN RETURN -2 END;
    RETURN FileSystem.Read(volume, e, offset, data, count)
  END Read;

  PROCEDURE Write(name: ARRAY OF CHAR; id, offset: LONGINT; VAR data: ARRAY OF CHAR; count: INTEGER): INTEGER;
    VAR h: Handle;
  BEGIN
    h := FindHandle(id); IF (h = NIL) OR ~h.writing THEN RETURN -9 END;
    IF h.append THEN offset := h.entry.size END;
    RETURN FSWrite.Write(volume, h.entry, offset, data, count)
  END Write;

  PROCEDURE NewName(path: ARRAY OF CHAR; VAR name: DiskTypes.Name): INTEGER;
    VAR i: INTEGER;
  BEGIN
    IF path = "/" THEN RETURN -21 END;
    IF path[0] # "/" THEN RETURN -22 END;
    i := 1;
    WHILE (i < LEN(path)) & (path[i] # 0X) DO
      IF path[i] = "/" THEN RETURN -20 END;
      IF path[i] < " " THEN RETURN -22 END;
      IF i >= volume.nameBytes THEN RETURN -36 END;
      name[i-1] := path[i]; INC(i)
    END;
    IF (i = LEN(path)) OR (i = 1) THEN RETURN -22 END;
    name[i-1] := 0X;
    IF (name = ".") OR (name = "..") THEN RETURN -22 END;
    RETURN 0
  END NewName;

  PROCEDURE Action(path, other: ARRAY OF CHAR; operation: INTEGER; VAR id: LONGINT; argument: LONGINT): INTEGER;
    VAR e, target: DiskTypes.Entry; h, before: Handle; name: DiskTypes.Name; res: INTEGER;
  BEGIN
    IF volume.failed & (operation # FuseABI.Release) THEN RETURN -5 END;
    IF operation = FuseABI.Release THEN
      before := NIL; h := handles;
      WHILE (h # NIL) & (h.id # id) DO before := h; h := h.next END;
      IF h = NIL THEN RETURN -9 END;
      res := FSWrite.Close(volume, h.entry);
      IF before = NIL THEN handles := h.next ELSE before.next := h.next END;
      id := 0; RETURN res
    END;
    IF operation = FuseABI.Sync THEN
      IF ~volume.writable THEN RETURN 0 END; RETURN FSWrite.Sync(volume)
    END;
    IF (path = "/") & (operation = FuseABI.Time) THEN RETURN -95 END;
    IF (operation = FuseABI.Open) OR (operation = FuseABI.Create) THEN
      IF (argument MOD 2 # 0) OR (argument DIV 2 MOD 2 # 0) OR (operation = FuseABI.Create) THEN
        IF ~volume.writable THEN RETURN -30 END
      END;
      IF nextHandle = MAX(LONGINT) THEN RETURN -24 END;
      IF operation = FuseABI.Create THEN
        res := NewName(path, name); IF res # 0 THEN RETURN res END;
        IF FileSystem.Find(volume, name) # NIL THEN RETURN -17 END;
        res := FSWrite.New(volume, name, e); IF res # 0 THEN RETURN res END
      ELSE
        IF path = "/" THEN RETURN -21 END;
        e := Entry(path, 0); IF e = NIL THEN RETURN -2 END
      END;
      IF argument DIV 2 MOD 2 # 0 THEN res := FSWrite.Resize(volume, e, 0); IF res # 0 THEN RETURN res END END;
      INC(nextHandle); NEW(h); h.id := nextHandle; h.entry := e; h.writing := argument MOD 2 # 0;
      h.append := argument DIV 4 MOD 2 # 0; h.next := handles; handles := h; INC(e.opens); id := h.id;
      RETURN 0
    END;
    e := Entry(path, id); IF e = NIL THEN RETURN -2 END;
    IF operation = FuseABI.Flush THEN
      IF ~volume.writable THEN RETURN 0 END;
      res := FSWrite.Flush(volume, e);
      IF res # 0 THEN Host.Report("flushing file (not saved)", res) END;
      RETURN res
    END;
    IF ~volume.writable THEN RETURN -30 END;
    CASE operation OF
      FuseABI.Truncate:
        IF id # 0 THEN h := FindHandle(id); IF ~h.writing THEN RETURN -9 END END;
        res := FSWrite.Resize(volume, e, argument);
        IF res = 0 THEN res := FSWrite.Flush(volume, e) END |
      FuseABI.Time:
        res := FSWrite.Time(volume, e, argument);
        IF res = 0 THEN res := FSWrite.Flush(volume, e) END |
      FuseABI.Unlink: res := FSWrite.Delete(volume, e) |
      FuseABI.Rename:
        res := NewName(other, name); IF res # 0 THEN RETURN res END;
        target := FileSystem.Find(volume, name); res := FSWrite.Rename(volume, e, name, target)
    ELSE res := -38 END;
    RETURN res
  END Action;

  PROCEDURE Space(VAR blocks, free: LONGINT; VAR blockSize, nameSize: INTEGER): INTEGER;
  BEGIN
    blocks := (volume.limit-volume.root) DIV volume.blockSize; free := 0;
    blockSize := volume.blockSize; nameSize := volume.nameBytes-1;
    IF volume.failed THEN RETURN -5 END;
    IF volume.writable THEN free := volume.allocation.free END;
    RETURN 0
  END Space;

  PROCEDURE Directory(name: ARRAY OF CHAR; offset: LONGINT): INTEGER;
    VAR e: DiskTypes.Entry; cookie, size, modified: LONGINT; res: INTEGER;
  BEGIN
    IF volume.failed THEN RETURN -5 END;
    IF (name # "/") & (name # "") THEN res := Stat(name, 0, size, modified); IF res < 0 THEN RETURN res ELSE RETURN -20 END END;
    IF offset < 0 THEN RETURN -22 END;
    IF (offset < 1) & ~FuseABI.Add(".", 1) THEN RETURN 0 END;
    IF (offset < 2) & ~FuseABI.Add("..", 2) THEN RETURN 0 END;
    cookie := 3; e := volume.first;
    WHILE e # NIL DO
      IF (~volume.salvage OR e.usable) & (offset < cookie) & ~FuseABI.Add(e.name, cookie) THEN RETURN 0 END;
      INC(cookie); e := e.next
    END;
    RETURN 0
  END Directory;

  PROCEDURE Run;
    VAR path, mountpoint: ARRAY 1024 OF CHAR; kind, res, closed, offset, cacheMiB: INTEGER;
      root: LONGINT; salvage, writable, device: BOOLEAN; h: Handle;
  BEGIN
    IF (Modules.ArgCount < 3) OR ~CommandLine.MountOptions(3, kind, root, salvage, writable, device, offset, cacheMiB) THEN
      Host.Error("usage: oberon-fuse IMAGE MOUNTPOINT [--rw|--salvage] [--device] [--cache-mib 0..256] [--utc-offset MINUTES] [FORMAT [ROOT-OFFSET]]"); Host.Exit(2)
    END;
    Modules.GetArg(1, path); Modules.GetArg(2, mountpoint);
    res := FileSystem.OpenCachedMount(path, kind, root, device, writable, salvage, offset, cacheMiB, volume);
    IF res # 0 THEN Host.Report(volume.error, res); Host.Exit(1) END;
    IF salvage & (volume.issueCount > 0) THEN Host.Error("salvage mount: unusable files excluded; run oberon-image check for details") END;
    IF writable THEN Host.Error("writable mount: use a working copy; unmount before removal; no power-loss atomicity") END;
    res := FuseABI.Run(mountpoint, writable, Stat, Read, Write, Directory, Action, Space);
    h := handles;
    WHILE h # NIL DO closed := FSWrite.Close(volume, h.entry); IF res = 0 THEN res := closed END; h := h.next END;
    handles := NIL; closed := FileSystem.Close(volume);
    IF closed # 0 THEN Host.Report("closing volume", closed) END;
    IF (res # 0) OR (closed # 0) THEN Host.Exit(1) END
  END Run;
BEGIN Run
END Fuse.
