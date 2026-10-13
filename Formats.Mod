MODULE Formats;
  IMPORT DiskTypes, ProjectFS, NatFS, CeresFS, AosFS;

  PROCEDURE Kind*(name: ARRAY OF CHAR): INTEGER;
  BEGIN
    IF name = "auto" THEN RETURN 0
    ELSIF name = "project" THEN RETURN DiskTypes.Project
    ELSIF name = "natfs" THEN RETURN DiskTypes.Native
    ELSIF name = "ceres" THEN RETURN DiskTypes.Ceres
    ELSIF name = "aos1" THEN RETURN DiskTypes.Aos1
    ELSIF name = "aos2" THEN RETURN DiskTypes.Aos2
    ELSE RETURN -1 END
  END Kind;

  PROCEDURE Name*(kind: INTEGER; VAR name: ARRAY OF CHAR);
  BEGIN
    CASE kind OF
      DiskTypes.Project: COPY("project", name) |
      DiskTypes.Native: COPY("natfs", name) |
      DiskTypes.Ceres: COPY("ceres", name) |
      DiskTypes.Aos1: COPY("aos1", name) |
      DiskTypes.Aos2: COPY("aos2", name)
    ELSE COPY("unknown", name) END
  END Name;

  PROCEDURE Configure*(kind: INTEGER; VAR v: DiskTypes.Volume): BOOLEAN;
  BEGIN
    CASE kind OF
      DiskTypes.Project: ProjectFS.Configure(v) |
      DiskTypes.Native: NatFS.Configure(v) |
      DiskTypes.Ceres: CeresFS.Configure(v) |
      DiskTypes.Aos1: AosFS.Configure(1, v) |
      DiskTypes.Aos2: AosFS.Configure(2, v)
    ELSE RETURN FALSE END;
    RETURN TRUE
  END Configure;
END Formats.
