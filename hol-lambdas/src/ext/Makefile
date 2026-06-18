subdir = src/ext
top_builddir = ../..
include $(top_builddir)/src/Makefile.global

ifneq ($(with_llvm), yes)
    $(warning LLVM support disabled; skipping LLVM bitcode install)
endif

CFLAGS := $(CFLAGS) $(LLVM_CFLAGS) -Wno-vla  -Wno-ignored-attributes -Wno-declaration-after-statement -Wno-implicit-function-declaration
CXXFLAGS += $(LLVM_CXXFLAGS) -Wno-ignored-attributes
override CPPFLAGS := $(LLVM_CPPFLAGS) $(CPPFLAGS) -Wno-ignored-attributes
SHLIB_LINK += $(LLVM_LIBS)

override COMPILER = $(CC) $(CFLAGS)

ifeq ($(enable_debug), yes)
  CFLAGS += -g -O0
  DEBUG_FLAGS = -g -O0
endif

EXTENSION_MODULES = \
	lambda_ext \
	kmeans_v2_ext \
	apply_mt_ext \
	apply_timing_ext \
	apply_mt_agg_ext

EXTENSION_SHLIBS = $(addsuffix .so,$(EXTENSION_MODULES))

threadpool.o: threadpool.c threadpool.h
	$(CC) -O2 -fPIC $(CPPFLAGS) $(CFLAGS) -I../include -c threadpool.c -o threadpool.o

all: $(EXTENSION_MODULES)

lambda_ext: lambda_ext.c
	$(CC) -O2 -fPIC $(CPPFLAGS) $(CFLAGS) -I../include -c $< -o lambda_ext.o
	$(CC) -O2 -fPIC $(CPPFLAGS) $(CFLAGS) -I../include -shared -o lambda_ext.so lambda_ext.o






kmeans_v2_ext: kmeans_v2_ext.c
	$(CC) -O2 -fPIC $(CPPFLAGS) $(CFLAGS) -I../include -c $< -o kmeans_v2_ext.o
	$(CC) -O2 -fPIC $(CPPFLAGS) $(CFLAGS) -I../include -shared -o kmeans_v2_ext.so kmeans_v2_ext.o




apply_mt_ext: apply_mt_ext.c threadpool.o threadpool.h
	$(CC) -O2 -fPIC $(CPPFLAGS) $(CFLAGS) -I../include -c $< -o apply_mt_ext.o
	$(CC) -O2 -fPIC $(CPPFLAGS) $(CFLAGS) -I../include -shared -o apply_mt_ext.so apply_mt_ext.o threadpool.o


apply_timing_ext: apply_timing_ext.c threadpool.o threadpool.h
	$(CC) -O2 -fPIC $(CPPFLAGS) $(CFLAGS) -I../include -c $< -o apply_timing_ext.o
	$(CC) -O2 -fPIC $(CPPFLAGS) $(CFLAGS) -I../include -shared -o apply_timing_ext.so apply_timing_ext.o threadpool.o

apply_mt_agg_ext: apply_mt_agg_ext.c threadpool.o threadpool.h
	$(CC) -O2 -fPIC $(CPPFLAGS) $(CFLAGS) -I../include -c $< -o apply_mt_agg_ext.o
	$(CC) -O2 -fPIC $(CPPFLAGS) $(CFLAGS) -I../include -shared -o apply_mt_agg_ext.so apply_mt_agg_ext.o threadpool.o


install-postgres-bitcode:
ifeq ($(with_llvm), yes)
	$(CLANG) $(DEBUG_FLAGS) -O2 -fPIC -flto=thin -emit-llvm $(CPPFLAGS) -I../include -c lambda_ext.c -o lambda_ext.bc
	$(CLANG) $(DEBUG_FLAGS) -O2 -fPIC -flto=thin -emit-llvm $(CPPFLAGS) -I../include -c kmeans_v2_ext.c -o kmeans_v2_ext.bc
	$(CLANG) $(DEBUG_FLAGS) -O2 -fPIC -flto=thin -emit-llvm $(CPPFLAGS) -I../include -c apply_mt_ext.c -o apply_mt_ext.bc
	$(CLANG) $(DEBUG_FLAGS) -O2 -fPIC -flto=thin -emit-llvm $(CPPFLAGS) -I../include -c apply_timing_ext.c -o apply_timing_ext.bc
	$(CLANG) $(DEBUG_FLAGS) -O2 -fPIC -flto=thin -emit-llvm $(CPPFLAGS) -I../include -c apply_mt_agg_ext.c -o apply_mt_agg_ext.bc
	$(call install_llvm_module,ext,lambda_ext.bc)
	$(call install_llvm_module,ext,kmeans_v2_ext.bc)
	$(call install_llvm_module,ext,apply_mt_ext.bc)
	$(call install_llvm_module,ext,apply_timing_ext.bc)
	$(call install_llvm_module,ext,apply_mt_agg_ext.bc)
else
	@echo "[SKIP] LLVM not enabled; skipping bitcode install."
endif

install-postgres-shlibs: all
	$(MKDIR_P) '$(DESTDIR)$(pkglibdir)'
	for shlib in $(EXTENSION_SHLIBS); do \
		$(INSTALL_SHLIB) "$$shlib" '$(DESTDIR)$(pkglibdir)/'$$shlib; \
	done

clean:
	rm -f *.o *.so *.bc
