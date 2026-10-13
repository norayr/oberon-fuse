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
PROJECT_CPPFLAGS = -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE -D_FILE_OFFSET_BITS=64 -I. -Itests -I"$(VOC_HOME)/C/include"
PROJECT_CFLAGS = -std=c11 -Wall -Wextra
VOC_FLAGS = -OC -rsS
MODULES = Host BlockIO DiskBytes DiskTypes DiskTime ProjectFS NatFS CeresFS AosFS Formats BlockSet Diagnostics AllocationMap OberonBTree DetectFS FSCheck FileSystem ReportWriter FSReports BTreeRebuild FSRepair ImageCreate CommandLine FuseABI
CORE_OBJECTS = $(addprefix build/,$(addsuffix .o,$(filter-out FuseABI,$(MODULES))))
MODULE_C = $(addprefix build/,$(addsuffix .c,$(MODULES)))
MODULE_H = $(addprefix build/,$(addsuffix .h,$(MODULES)))
MODULE_SYM = $(addprefix build/,$(addsuffix .sym,$(MODULES)))
RUNTIME_LIBS = "$(VOC_RUNTIME)" -lm -ldl

.PHONY: all check check-images check-mount check-deps clean
.DELETE_ON_ERROR:

all: build/oberon-fuse build/oberon-image

check: all build/FuseProbe
	./build/FuseProbe
	$(PYTHON) tests/test_images.py
	$(PYTHON) tests/test_repair.py
	$(PYTHON) tests/test_inplace.py

check-images: all
	$(PYTHON) tests/test_images.py --real
	$(PYTHON) tests/test_repair.py
	$(PYTHON) tests/test_inplace.py

check-mount: all
	$(PYTHON) tests/test_mount.py

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
	$(CC) $(CPPFLAGS) $(PROJECT_CPPFLAGS) $(CFLAGS) $(PROJECT_CFLAGS) -include alloca.h -Wno-unused-parameter -Wno-unused-but-set-variable -Wno-unused-label -Wno-stringop-overflow -c $< -o $@

build/Fuse.c: Fuse.Mod $(MODULE_SYM) Makefile | build check-deps
	cd build && "$(VOC_BIN)" -OC -rmS ../Fuse.Mod

build/ImageTool.c: ImageTool.Mod $(MODULE_SYM) Makefile | build check-deps
	cd build && "$(VOC_BIN)" -OC -rmS ../ImageTool.Mod

build/FuseProbe.c: tests/FuseProbe.Mod Makefile | build check-deps
	cd build && "$(VOC_BIN)" -OC -rmS ../tests/FuseProbe.Mod

build/Host.o: HostBridge.h
build/FuseABI.o: FuseBridge.h
build/FuseProbe.o: tests/FuseProbeBridge.h

build/HostBridge.o: HostBridge.c HostBridge.h Makefile | build check-deps
	$(CC) $(CPPFLAGS) $(PROJECT_CPPFLAGS) $(CFLAGS) $(PROJECT_CFLAGS) -c $< -o $@

build/FuseBridge.o: FuseBridge.c FuseBridge.h Makefile | build check-deps
	$(CC) $(CPPFLAGS) $(PROJECT_CPPFLAGS) $(FUSE_CFLAGS) $(CFLAGS) $(PROJECT_CFLAGS) -c $< -o $@

build/FuseProbeBridge.o: tests/FuseProbeBridge.c tests/FuseProbeBridge.h Makefile | build check-deps
	$(CC) $(CPPFLAGS) $(PROJECT_CPPFLAGS) $(FUSE_CFLAGS) $(CFLAGS) $(PROJECT_CFLAGS) -c $< -o $@

build/FuseProbe: build/FuseProbe.o build/FuseProbeBridge.o Makefile | check-deps
	$(CC) $(LDFLAGS) build/FuseProbe.o build/FuseProbeBridge.o $(RUNTIME_LIBS) $(FUSE_LIBS) $(LDLIBS) -o $@

build/oberon-fuse: build/Fuse.o build/FuseABI.o $(CORE_OBJECTS) build/HostBridge.o build/FuseBridge.o Makefile
	$(CC) $(LDFLAGS) $(filter %.o,$^) $(RUNTIME_LIBS) $(FUSE_LIBS) $(LDLIBS) -o $@

build/oberon-image: build/ImageTool.o $(CORE_OBJECTS) build/HostBridge.o Makefile
	$(CC) $(LDFLAGS) $(filter %.o,$^) $(RUNTIME_LIBS) $(LDLIBS) -o $@

clean:
	rm -f $(MODULE_C) $(MODULE_H) $(MODULE_SYM) $(addprefix build/,$(addsuffix .o,$(MODULES)))
	rm -f build/Fuse.c build/ImageTool.c build/Fuse.o build/ImageTool.o build/HostBridge.o build/FuseBridge.o
	rm -f build/oberon-fuse build/oberon-image build/FuseProbe build/FuseProbe.c build/FuseProbe.o build/FuseProbeBridge.o
