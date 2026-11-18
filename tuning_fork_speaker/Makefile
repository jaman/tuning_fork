CFLAGS ?= -fPIC -O2
LDFLAGS ?=

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
	LDFLAGS += -dynamiclib -undefined dynamic_lookup
	LDFLAGS += -framework CoreFoundation -framework CoreAudio -framework AudioToolbox
else
	LDFLAGS += -shared -lpthread -lm -ldl
endif

ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~s/include", [code:root_dir() ++ "/erts-" ++ erlang:system_info(version)])' -s init stop)

PRIV_DIR ?= priv
NIF_SO = $(PRIV_DIR)/tuning_fork_nif.so
NIF_SRC = c_src/tuning_fork_nif.c

all: $(NIF_SO)

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

$(NIF_SO): $(NIF_SRC) c_src/miniaudio.h | $(PRIV_DIR)
	$(CC) $(CFLAGS) -I$(ERTS_INCLUDE_DIR) -Ic_src -o $@ $(NIF_SRC) $(LDFLAGS)

STATIC_DIR ?= priv/static

ifneq ($(filter ios tvos,$(CAULDRON_TARGET)),)
STATIC_LANGUAGE = -x objective-c
STATIC_LDFLAGS = -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework CoreFoundation
else ifeq ($(CAULDRON_TARGET),macos)
STATIC_LANGUAGE =
STATIC_LDFLAGS = -framework AudioToolbox -framework CoreAudio -framework CoreFoundation
else
STATIC_LANGUAGE =
STATIC_LDFLAGS = -ldl -lm
endif

static: $(NIF_SRC) c_src/miniaudio.h | $(STATIC_DIR)
	$(CC) $(STATIC_LANGUAGE) $(CFLAGS) -DSTATIC_ERLANG_NIF_LIBNAME=tuning_fork_nif -I$(ERTS_INCLUDE_DIR) -Ic_src -c -o $(STATIC_DIR)/tuning_fork_nif.o $(NIF_SRC)
	$(AR) rcs $(STATIC_DIR)/tuning_fork_nif.a $(STATIC_DIR)/tuning_fork_nif.o
	echo "$(STATIC_LDFLAGS)" > $(STATIC_DIR)/tuning_fork_nif.ldflags

$(STATIC_DIR):
	mkdir -p $(STATIC_DIR)

clean:
	rm -f $(NIF_SO)

.PHONY: all static clean
