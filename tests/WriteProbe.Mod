MODULE WriteProbe;
  (* Exercise the writer without libfuse, including injected host I/O errors. *)
  IMPORT Modules, Host, DiskTypes, FileSystem, FSWrite, Formats, DiskBytes;
  VAR v: DiskTypes.Volume; e: DiskTypes.Entry; text, path, operation: ARRAY 1024 OF CHAR;
    kind, res, closed, n: INTEGER; root, count: LONGINT; b: DiskTypes.Buffer;
BEGIN
  ASSERT(Modules.ArgCount = 5);
  Modules.GetArg(1, path); Modules.GetArg(2, text); kind := Formats.Kind(text);
  Modules.GetArg(3, operation); Modules.GetArg(4, text); ASSERT(DiskBytes.Number(text, count));
  root := -1; res := FileSystem.OpenMount(path, kind, root, FALSE, TRUE, FALSE, 0, v);
  IF res = 0 THEN
    e := FileSystem.Find(v, "File");
    IF e = NIL THEN res := FSWrite.New(v, "File", e) END;
    IF res = 0 THEN
      IF operation = "resize" THEN res := FSWrite.Resize(v, e, count)
      ELSE
        ASSERT(operation = "write");
        FOR n := 0 TO LEN(b)-1 DO b[n] := CHR(n MOD 251) END;
        root := 0;
        WHILE (root < count) & (res = 0) DO
          n := LEN(b); IF n > count-root THEN n := SHORT(count-root) END;
          res := FSWrite.Write(v, e, root, b, n); IF res = n THEN res := 0 ELSIF res >= 0 THEN res := -5 END;
          INC(root, n)
        END
      END;
      IF res = 0 THEN res := FSWrite.Flush(v, e) END
    END;
    closed := FileSystem.Close(v); IF res = 0 THEN res := closed END
  END;
  IF res # 0 THEN Host.Report("writer probe", res); Host.Exit(1) END
END WriteProbe.
