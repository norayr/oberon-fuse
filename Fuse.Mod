MODULE Fuse;
  IMPORT Modules, Host, DiskTypes, FileSystem, CommandLine, FuseABI;
  VAR volume: DiskTypes.Volume;

  PROCEDURE Stat(name: ARRAY OF CHAR; VAR size: LONGINT): INTEGER;
    VAR e: DiskTypes.Entry;
  BEGIN
    size := 0;
    IF name = "/" THEN RETURN 1 END;
    IF name[0] # "/" THEN RETURN -2 END;
    e := FileSystem.FindPath(volume, name);
    IF e = NIL THEN RETURN -2 END;
    IF (e.headerIssue # 0) OR (volume.salvage & ~e.usable) THEN RETURN -2 END;
    size := e.size; RETURN 0
  END Stat;

  PROCEDURE Read(name: ARRAY OF CHAR; offset: LONGINT; VAR data: ARRAY OF CHAR; count: INTEGER): INTEGER;
    VAR e: DiskTypes.Entry;
  BEGIN
    IF name = "/" THEN RETURN -21 END;
    IF name[0] # "/" THEN RETURN -2 END;
    e := FileSystem.FindPath(volume, name);
    IF e = NIL THEN RETURN -2 END;
    RETURN FileSystem.Read(volume, e, offset, data, count)
  END Read;

  PROCEDURE Directory(name: ARRAY OF CHAR; offset: LONGINT): INTEGER;
    VAR e: DiskTypes.Entry; cookie, size: LONGINT; res: INTEGER;
  BEGIN
    IF name # "/" THEN
      res := Stat(name, size); IF res < 0 THEN RETURN res ELSE RETURN -20 END
    END;
    IF offset < 0 THEN RETURN -22 END;
    IF (offset < 1) & ~FuseABI.Add(".", 1) THEN RETURN 0 END;
    IF (offset < 2) & ~FuseABI.Add("..", 2) THEN RETURN 0 END;
    cookie := 3; e := volume.first;
    WHILE e # NIL DO
      IF (~volume.salvage OR e.usable) & (offset < cookie) &
         ~FuseABI.Add(e.name, cookie) THEN RETURN 0 END;
      INC(cookie); e := e.next
    END;
    RETURN 0
  END Directory;

  PROCEDURE Run;
    VAR path, mountpoint: ARRAY 1024 OF CHAR; kind, res, closed: INTEGER;
      root: LONGINT; salvage: BOOLEAN;
  BEGIN
    IF (Modules.ArgCount < 3) OR ~CommandLine.Options(3, kind, root, salvage) THEN
      Host.Error("usage: oberon-fuse IMAGE MOUNTPOINT [--salvage] [FORMAT [ROOT-OFFSET]]"); Host.Exit(2)
    END;
    Modules.GetArg(1, path); Modules.GetArg(2, mountpoint);
    IF salvage THEN res := FileSystem.OpenSalvage(path, kind, root, volume)
    ELSE res := FileSystem.Open(path, kind, root, volume) END;
    IF res # 0 THEN Host.Report(volume.error, res); Host.Exit(1) END;
    IF salvage & (volume.issueCount > 0) THEN
      Host.Error("salvage mount: unusable files excluded; run oberon-image check for details")
    END;
    res := FuseABI.Run(mountpoint, Stat, Read, Directory);
    closed := FileSystem.Close(volume);
    IF (res # 0) OR (closed # 0) THEN Host.Exit(1) END
  END Run;
BEGIN Run
END Fuse.
