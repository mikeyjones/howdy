# Based on c_src.mk from erlang.mk by Loic Hoguin <essen@ninenines.eu>

CURDIR := $(shell pwd)
BASEDIR := $(abspath $(CURDIR)/..)

PROJECT ?= $(notdir $(BASEDIR))
PROJECT := $(strip $(PROJECT))

ARGON2_SRC_DIR = $(BASEDIR)/argon2/src
ARGON2_INCLUDE_DIR = $(BASEDIR)/argon2/include
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval "io:format(\"~ts/erts-~ts/include/\", [code:root_dir(), erlang:system_info(version)])." -s init stop)
ERL_INTERFACE_INCLUDE_DIR ?= $(shell erl -noshell -eval "io:format(\"~ts\", [code:lib_dir(erl_interface, include)])." -s init stop)
ERL_INTERFACE_LIB_DIR ?= $(shell erl -noshell -eval "io:format(\"~ts\", [code:lib_dir(erl_interface, lib)])." -s init stop)

C_SRC_DIR = $(CURDIR)
C_SRC_OUTPUT ?= $(CURDIR)/../priv/$(PROJECT).so

# System type and C compiler/flags.

UNAME_SYS := $(shell uname -s)
ifeq ($(shell uname -o), Msys)
# We hardcode the compiler used on MSYS2. The default CC=cc does
# not produce working code. The "gcc" MSYS2 package also doesn't.
	CC = /mingw64/bin/gcc
	export CC
	C_SRC_OUTPUT := $(addsuffix .dll, $(basename $(C_SRC_OUTPUT)))
	CFLAGS ?= -O3 -std=c99 -finline-functions -Wall -Wmissing-prototypes
	CXXFLAGS ?= -O3 -finline-functions -Wall
	ERTS_INCLUDE_DIR := $(shell cygpath -u $(ERTS_INCLUDE_DIR))
	ERL_INTERFACE_INCLUDE_DIR := $(shell cygpath -u $(ERL_INTERFACE_INCLUDE_DIR))
	ERL_INTERFACE_INCLUDE_LIB_DIR := $(shell cygpath -u $(ERL_INTERFACE_INCLUDE_LIB_DIR))
else ifeq ($(UNAME_SYS), Darwin)
	CC ?= cc
	CFLAGS ?= -O3 -std=c99 -finline-functions -Wall -Wmissing-prototypes
	CXXFLAGS ?= -O3 -finline-functions -Wall
	LDFLAGS ?= -flat_namespace -undefined suppress
else ifeq ($(UNAME_SYS), FreeBSD)
	CC ?= cc
	CFLAGS ?= -O3 -std=c99 -finline-functions -Wall -Wmissing-prototypes
	CXXFLAGS ?= -O3 -finline-functions -Wall
else ifeq ($(UNAME_SYS), Linux)
	CC ?= gcc
	CFLAGS ?= -O3 -std=c99 -finline-functions -Wall -Wmissing-prototypes
	CXXFLAGS ?= -O3 -finline-functions -Wall
endif

ifneq ($(shell uname -o),Msys)
	CFLAGS += -fPIC
	CXXFLAGS += -fPIC
endif

CFLAGS += -I $(ERTS_INCLUDE_DIR) -I $(ERL_INTERFACE_INCLUDE_DIR) -I $(ARGON2_INCLUDE_DIR)
CXXFLAGS += -I $(ERTS_INCLUDE_DIR) -I $(ERL_INTERFACE_INCLUDE_DIR) -I $(ARGON2_INCLUDE_DIR)

LDLIBS += -L $(ERL_INTERFACE_LIB_DIR) -lei
LDFLAGS += -shared

# Verbosity.

c_verbose_0 = @echo " C     " $(?F);
c_verbose = $(c_verbose_$(V))

cpp_verbose_0 = @echo " CPP   " $(?F);
cpp_verbose = $(cpp_verbose_$(V))

link_verbose_0 = @echo " LD    " $(@F);
link_verbose = $(link_verbose_$(V))

# SSE2 is part of the x86-64 baseline; do not use -march=native in releases.
# Other targets keep the portable reference implementation. Cross-compilers
# and packagers may explicitly select ARGON2_IMPL=ref or opt.
ARGON2_IMPL ?= $(if $(filter x86_64 amd64,$(shell uname -m)),opt,ref)
ifeq ($(filter $(ARGON2_IMPL),ref opt),)
$(error ARGON2_IMPL must be ref or opt)
endif

SOURCES := $(shell find $(C_SRC_DIR) -type f \( -name "*.c" -o -name "*.C" -o -name "*.cc" -o -name "*.cpp" \))
SOURCES += $(ARGON2_SRC_DIR)/argon2.c $(ARGON2_SRC_DIR)/core.c $(ARGON2_SRC_DIR)/blake2/blake2b.c \
      $(ARGON2_SRC_DIR)/thread.c $(ARGON2_SRC_DIR)/encoding.c $(ARGON2_SRC_DIR)/$(ARGON2_IMPL).c
OBJECTS = $(addsuffix .o, $(basename $(SOURCES)))

COMPILE_C = $(c_verbose) $(CC) $(CFLAGS) $(CPPFLAGS) -c
COMPILE_CPP = $(cpp_verbose) $(CXX) $(CXXFLAGS) $(CPPFLAGS) -c

# Relink on every invocation so changing ARGON2_IMPL cannot retain an old NIF.
.PHONY: force

$(C_SRC_OUTPUT): $(OBJECTS) force
	@mkdir -p $(BASEDIR)/priv/
	$(link_verbose) $(CC) $(OBJECTS) $(LDFLAGS) $(LDLIBS) -o $(C_SRC_OUTPUT)

%.o: %.c
	$(COMPILE_C) $(OUTPUT_OPTION) $<

%.o: %.cc
	$(COMPILE_CPP) $(OUTPUT_OPTION) $<

%.o: %.C
	$(COMPILE_CPP) $(OUTPUT_OPTION) $<

%.o: %.cpp
	$(COMPILE_CPP) $(OUTPUT_OPTION) $<

clean:
	@rm -f $(C_SRC_OUTPUT) $(OBJECTS) $(ARGON2_SRC_DIR)/ref.o $(ARGON2_SRC_DIR)/opt.o

force:
