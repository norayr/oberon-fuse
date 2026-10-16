VOC ?= voc
PKG_CONFIG ?= pkg-config
PYTHON ?= python3
CFLAGS ?= -O2 -g

VOC_BIN := $(realpath $(shell command -v "$(VOC)" 2>/dev/null))
VOC_PREFIX := $(abspath $(dir $(VOC_BIN))/..)
# Keep compiler symbols, C headers and runtime in the same OC size model.
VOC_HOME ?= $(firstword $(foreach dir,$(VOC_PREFIX)/share/voc $(VOC_PREFIX),$(if $(wildcard $(dir)/C/include/SYSTEM.h),$(dir))))
VOC_RUNTIME ?= $(firstword $(wildcard $(VOC_PREFIX)/lib/libvoc-OC.a $(VOC_PREFIX)/lib64/libvoc-OC.a $(VOC_PREFIX)/lib/*/libvoc-OC.a))

FUSE_CFLAGS = $(shell $(PKG_CONFIG) --cflags fuse3)
FUSE_LIBS = $(shell $(PKG_CONFIG) --libs fuse3)
PROJECT_CPPFLAGS = -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE -D_FILE_OFFSET_BITS=64 -Itests -I"$(VOC_HOME)/C/include"
PROJECT_CFLAGS = -std=c11 -Wall -Wextra
VOC_FLAGS = -OC -rsS
MODULES = Host ReadCache BlockIO DiskBytes WriteBitmap DiskTypes DiskTime ProjectFS NatFS CeresFS AosFS Formats BlockSet Diagnostics AllocationMap OberonBTree AllocationCache DetectFS FSCheck BTreeRebuild FSWrite FileSystem ReportWriter FSReports FSRepair ImageCreate CommandLine FuseABI
CORE_OBJECTS = $(addprefix build/,$(addsuffix .o,$(filter-out FuseABI,$(MODULES))))
MODULE_C = $(addprefix build/,$(addsuffix .c,$(MODULES)))
MODULE_H = $(addprefix build/,$(addsuffix .h,$(MODULES)))
MODULE_SYM = $(addprefix build/,$(addsuffix .sym,$(MODULES)))
RUNTIME_LIBS = "$(VOC_RUNTIME)" -lm -ldl

.PHONY: all check check-images check-mount check-devices check-deps clean
.DELETE_ON_ERROR:

all: build/oberon-fuse build/oberon-image

check: all build/FuseProbe build/DiskTimeProbe build/WriteProbe build/ReadCacheProbe build/CacheIOProbe build/FailIO.so
	./build/FuseProbe
	./build/DiskTimeProbe
	./build/ReadCacheProbe
	$(PYTHON) tests/test_images.py
	$(PYTHON) tests/test_repair.py
	$(PYTHON) tests/test_inplace.py
	$(PYTHON) tests/test_writes.py
	$(PYTHON) tests/test_cache.py

check-images: all
	$(PYTHON) tests/test_images.py --real
	$(PYTHON) tests/test_repair.py
	$(PYTHON) tests/test_inplace.py

check-mount: all
	$(PYTHON) tests/test_mount.py
	$(PYTHON) tests/test_write_mount.py
	$(PYTHON) tests/test_cache_mount.py

check-devices: all
	$(PYTHON) tests/test_devices.py

check-deps:
	@command -v "$(VOC)" >/dev/null || { echo "VOC not found; set VOC to its executable path." >&2; exit 1; }
	@command -v $(CC) >/dev/null || { echo "C compiler not found; set CC." >&2; exit 1; }
	@command -v "$(PKG_CONFIG)" >/dev/null || { echo "pkg-config not found." >&2; exit 1; }
	@$(PKG_CONFIG) --exists fuse3 || { echo "libfuse 3 development files not found." >&2; exit 1; }
	@test -f "$(VOC_HOME)/C/include/SYSTEM.h" -a -f "$(VOC_HOME)/C/sym/Out.sym" || { echo "VOC OC headers/symbols not found; set VOC_HOME." >&2; exit 1; }
	@test -f "$(VOC_RUNTIME)" || { echo "VOC OC runtime archive not found; set VOC_RUNTIME to libvoc-OC.a." >&2; exit 1; }

build:
	mkdir -p $@

$(MODULE_C) $(MODULE_H) $(MODULE_SYM) &: $(addsuffix .Mod,$(MODULES)) Makefile | build check-deps
# Translate in dependency order; compile the resulting C files in parallel.
	cd build && "$(VOC_BIN)" $(VOC_FLAGS) $(addprefix ../,$(addsuffix .Mod,$(MODULES)))
	touch $(MODULE_C) $(MODULE_H) $(MODULE_SYM)

build/%.o: build/%.c $(MODULE_H) Makefile | check-deps
# alloca and these warnings come from VOC/runtime macros, not handwritten C.
	$(CC) $(CPPFLAGS) $(PROJECT_CPPFLAGS) $(FUSE_CFLAGS) $(CFLAGS) $(PROJECT_CFLAGS) -include alloca.h -Wno-unused-parameter -Wno-unused-but-set-variable -Wno-unused-label -Wno-stringop-overflow -c $< -o $@

build/Fuse.c: Fuse.Mod $(MODULE_SYM) Makefile | build check-deps
	cd build && "$(VOC_BIN)" -OC -rmS ../Fuse.Mod

build/ImageTool.c: ImageTool.Mod $(MODULE_SYM) Makefile | build check-deps
	cd build && "$(VOC_BIN)" -OC -rmS ../ImageTool.Mod

build/FuseProbe.c: tests/FuseProbe.Mod Makefile | build check-deps
	cd build && "$(VOC_BIN)" -OC -rmS ../tests/FuseProbe.Mod

build/DiskTimeProbe.c: tests/DiskTimeProbe.Mod $(MODULE_SYM) Makefile | build check-deps
	cd build && "$(VOC_BIN)" -OC -rmS ../tests/DiskTimeProbe.Mod

build/WriteProbe.c: tests/WriteProbe.Mod $(MODULE_SYM) Makefile | build check-deps
	cd build && "$(VOC_BIN)" -OC -rmS ../tests/WriteProbe.Mod

build/ReadCacheProbe.c: tests/ReadCacheProbe.Mod $(MODULE_SYM) Makefile | build check-deps
	cd build && "$(VOC_BIN)" -OC -rmS ../tests/ReadCacheProbe.Mod

build/CacheIOProbe.c: tests/CacheIOProbe.Mod $(MODULE_SYM) Makefile | build check-deps
	cd build && "$(VOC_BIN)" -OC -rmS ../tests/CacheIOProbe.Mod

build/FailIO.so: tests/FailIO.c Makefile | build
	$(CC) $(CPPFLAGS) $(CFLAGS) $(PROJECT_CFLAGS) -fPIC -shared $< -ldl -o $@

build/DiskTimeProbe: build/DiskTimeProbe.o $(CORE_OBJECTS) Makefile
	$(CC) $(LDFLAGS) $(filter %.o,$^) $(RUNTIME_LIBS) $(LDLIBS) -o $@

build/WriteProbe: build/WriteProbe.o $(CORE_OBJECTS) Makefile
	$(CC) $(LDFLAGS) $(filter %.o,$^) $(RUNTIME_LIBS) $(LDLIBS) -o $@

build/ReadCacheProbe: build/ReadCacheProbe.o $(CORE_OBJECTS) Makefile
	$(CC) $(LDFLAGS) $(filter %.o,$^) $(RUNTIME_LIBS) $(LDLIBS) -o $@

build/CacheIOProbe: build/CacheIOProbe.o $(CORE_OBJECTS) Makefile
	$(CC) $(LDFLAGS) $(filter %.o,$^) $(RUNTIME_LIBS) $(LDLIBS) -o $@

build/FuseProbe.o: tests/FuseProbeBridge.h

build/FuseProbeBridge.o: tests/FuseProbeBridge.c tests/FuseProbeBridge.h Makefile | build check-deps
	$(CC) $(CPPFLAGS) $(PROJECT_CPPFLAGS) $(FUSE_CFLAGS) $(CFLAGS) $(PROJECT_CFLAGS) -c $< -o $@

build/FuseProbe: build/FuseProbe.o build/FuseProbeBridge.o Makefile | check-deps
	$(CC) $(LDFLAGS) build/FuseProbe.o build/FuseProbeBridge.o $(RUNTIME_LIBS) $(FUSE_LIBS) $(LDLIBS) -o $@

build/oberon-fuse: build/Fuse.o build/FuseABI.o $(CORE_OBJECTS) Makefile
	$(CC) $(LDFLAGS) $(filter %.o,$^) $(RUNTIME_LIBS) $(FUSE_LIBS) $(LDLIBS) -o $@

build/oberon-image: build/ImageTool.o $(CORE_OBJECTS) Makefile
	$(CC) $(LDFLAGS) $(filter %.o,$^) $(RUNTIME_LIBS) $(LDLIBS) -o $@

clean:
	rm -f $(MODULE_C) $(MODULE_H) $(MODULE_SYM) $(addprefix build/,$(addsuffix .o,$(MODULES)))
	rm -f build/Fuse.c build/ImageTool.c build/Fuse.o build/ImageTool.o
	rm -f build/oberon-fuse build/oberon-image build/FuseProbe build/FuseProbe.c build/FuseProbe.o build/FuseProbeBridge.o
	rm -f build/DiskTimeProbe build/DiskTimeProbe.c build/DiskTimeProbe.o build/WriteProbe build/WriteProbe.c build/WriteProbe.o build/FailIO.so
	rm -f build/ReadCacheProbe build/ReadCacheProbe.c build/ReadCacheProbe.o build/CacheIOProbe build/CacheIOProbe.c build/CacheIOProbe.o
